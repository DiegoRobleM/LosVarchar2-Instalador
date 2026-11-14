# =====================================================================
#  Instalador grafico de mods (WPF) - Servidor "Los Varchar2"
# =====================================================================
#  Como esta armado:
#   1) $trabajo  -> script que corre en un HILO APARTE (runspace). Hace todo
#                   lo lento: consultar Modrinth, descargar e instalar.
#   2) $sync     -> tabla compartida entre el hilo y la ventana. El hilo
#                   escribe ahi su estado (fase, paso, bytes descargados, log...).
#   3) Ventana   -> definida en XAML. Un temporizador lee $sync cada 100 ms
#                   y actualiza la pantalla. Asi la ventana nunca se congela.
#  La lista de mods esta en mods.json. Al empezar se intenta bajar la version
#  publicada en internet (url-lista.txt); si falla, se usa la copia local.
#
#  Diseno: cabecera pixel-art (dibujada por codigo), tarjetas oscuras, pasos
#  NeoForge -> Mods -> Shaders y lista de archivos con etiquetas de estado.
#  Los textos "pixelados" (titulo, frase amarilla, boton) se dibujan con una
#  fuente de 5x7 pixeles definida aqui mismo, asi no hay que instalar fuentes.
#
#  -Demo : simula una instalacion (no descarga ni toca nada). Sirve para ver
#          como se ve la ventana mientras instala.
# =====================================================================

param(
    [switch]$YaActualizado,   # ya no se usa; se acepta para que los instaladores antiguos no fallen al reabrirse
    [switch]$Demo
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$carpeta = $PSScriptRoot

# ---------------------------------------------------------------------
# Estado compartido (sincronizado para usarlo desde dos hilos)
# ---------------------------------------------------------------------
$sync = [hashtable]::Synchronized(@{})
function Reiniciar-Estado {
    $sync.Fase = 'Preparando...'; $sync.Actual = ''; $sync.Indeterminado = $true
    $sync.Total = [long]0; $sync.Hecho = [long]0; $sync.Descargando = $false
    $sync.ArchivoTotal = [long]0; $sync.ArchivoHecho = [long]0
    $sync.Paso = 1; $sync.NeoListo = $false               # 1 NeoForge, 2 Mods, 3 Shaders, 4 todo listo
    $sync.ModsTotal = 0; $sync.ModsListos = 0; $sync.ShadersTotal = 0; $sync.ShadersListos = 0
    $sync.Nuevos = 0; $sync.YaEstaban = 0; $sync.Quitados = 0; $sync.Omitidos = 0; $sync.Errores = 0
    $sync.Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $sync.Cancelar = $false; $sync.Terminado = $false; $sync.Error = $null
    $sync.MapaBorrar = @(); $sync.BorrarRespaldo = $false   # lo que el usuario eligio borrar
}

# ---------------------------------------------------------------------
# 1) TRABAJO EN SEGUNDO PLANO
#    Log "texto" tipo [tamano]  -> agrega una fila a la lista de la ventana.
#    Tipos: info, nuevo, ya, respaldo, borrado, omitido, error
# ---------------------------------------------------------------------
$trabajo = {
    $ErrorActionPreference = 'Stop'

    function Log($texto, $tipo = 'info', $tam = $null) {
        $sync.Log.Enqueue([pscustomobject]@{ Texto = $texto; Tipo = $tipo; Tam = $tam })
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{ 'User-Agent' = 'minecraft-client-setup-gui/1.0' }

        # Carga la lista de mods (intentando la version mas nueva de internet)
        # y las funciones Get-Json / Get-NeoForgeVersion
        $sync.Fase = 'Buscando la lista de mods...'
        $carpetaLista = $carpeta
        $actualizarLista = $true
        $codigo = Get-Content -LiteralPath (Join-Path $carpeta 'mods-lista.ps1') -Raw -Encoding UTF8
        . ([scriptblock]::Create($codigo))
        Log "Lista de mods: $origenLista" 'info'
        if ($origenConfigs) { Log "Configuraciones: $origenConfigs" 'info' }

        $mcDir      = Join-Path $env:APPDATA '.minecraft'
        $mods       = Join-Path $mcDir 'mods'
        $shadersDir = Join-Path $mcDir 'shaderpacks'
        $tmp        = Join-Path $env:TEMP 'neoforge-client-setup'

        # Descarga un archivo sumando los bytes a $sync.Hecho para la barra.
        # Escribe primero en ".part" y renombra al final: si se corta, no queda un .jar a medias.
        function Descargar($url, $destino) {
            $parte = "$destino.part"
            try {
                $req = [System.Net.HttpWebRequest]::Create($url)
                $req.UserAgent = $headers['User-Agent']
                $resp = $req.GetResponse()
                $entrada = $resp.GetResponseStream()
                $salida = [System.IO.File]::Create($parte)
                try {
                    $buf = New-Object byte[] 65536
                    while (($n = $entrada.Read($buf, 0, $buf.Length)) -gt 0) {
                        if ($sync.Cancelar) { throw 'CANCELADO' }
                        $salida.Write($buf, 0, $n)
                        $sync.Hecho += $n
                        $sync.ArchivoHecho += $n
                    }
                } finally { $salida.Close(); $entrada.Close(); $resp.Close() }
                if ([System.IO.File]::Exists($destino)) { [System.IO.File]::Delete($destino) }
                [System.IO.File]::Move($parte, $destino)
            } catch {
                if ([System.IO.File]::Exists($parte)) { [System.IO.File]::Delete($parte) }
                throw
            }
        }

        # --- Requisitos ---
        $sync.Fase = 'Comprobando requisitos...'
        if (-not (Test-Path (Join-Path $mcDir 'launcher_profiles.json'))) {
            throw 'No encontré el launcher de Minecraft. Ábrelo una vez, inicia sesión, ciérralo y vuelve a intentar.'
        }
        if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
            throw 'No se encontró Java. Instala Java 21 (Temurin) desde https://adoptium.net, reinicia el PC y vuelve a intentar.'
        }
        New-Item -ItemType Directory -Force -Path $mods, $shadersDir, $tmp | Out-Null
        Get-ChildItem -LiteralPath $mods -Filter *.part -ErrorAction SilentlyContinue | Remove-Item -Force

        # --- Datos del minimapa (solo si el usuario dijo que si) ---
        foreach ($d in $sync.MapaBorrar) {
            try {
                Remove-Item -LiteralPath $d -Recurse -Force
                Log "Minimapa: $(Split-Path $d -Leaf)" 'borrado'
            } catch { Log "No se pudo borrar $(Split-Path $d -Leaf)" 'error' }
        }

        # --- PASO 1: NeoForge (solo si esa version no esta instalada) ---
        $sync.Paso = 1
        $sync.Fase = 'Buscando la versión de NeoForge...'
        $nf = Get-NeoForgeVersion
        if (Test-Path (Join-Path $mcDir "versions\neoforge-$nf")) {
            Log "NeoForge $nf" 'ya'
        } else {
            $sync.Fase = 'Descargando NeoForge...'
            $jar = Join-Path $tmp "neoforge-$nf-installer.jar"
            Descargar "https://maven.neoforged.net/releases/net/neoforged/neoforge/$nf/neoforge-$nf-installer.jar" $jar
            $sync.Fase = 'Instalando NeoForge...'
            $sync.Actual = 'Puede tardar unos minutos'
            $p = Start-Process -FilePath 'java' -ArgumentList @('-jar', "`"$jar`"", '--installClient', "`"$mcDir`"") -WorkingDirectory $tmp -WindowStyle Hidden -Wait -PassThru
            $sync.Actual = ''
            if ($p.ExitCode -ne 0) { throw "Falló el instalador de NeoForge (código $($p.ExitCode))." }
            Log "NeoForge $nf" 'nuevo'
        }
        $sync.NeoListo = $true

        # --- PASO 2: armar el plan: que archivo corresponde a cada mod y sus dependencias ---
        $sync.Paso = 2
        $sync.Fase = 'Revisando la lista en Modrinth...'
        $plan     = New-Object System.Collections.ArrayList
        $vistos   = @{}
        $archivos = @{}
        $estado   = @{ Fallos = 0 }

        # $padre: si es una dependencia, el mod que la pidio (para mostrar un nombre legible)
        function Resolver($slug, $loader, $destino, $padre = '') {
            if ($vistos.ContainsKey($slug)) { return }
            $vistos[$slug] = $true
            if ($sync.Cancelar) { throw 'CANCELADO' }
            # Las dependencias llegan como id de Modrinth (ej. "AANobbMI"), no como nombre legible
            $nombre = if ($padre) { "dependencia de $padre" } else { $slug }
            $sync.Actual = if ($padre) { "Consultando dependencias de $padre" } else { "Consultando: $slug" }
            $base = "https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22$loader%22%5D"
            try {
                $vers = Get-Json "$base&game_versions=%5B%22$mc%22%5D"
                if ($vers.Count -eq 0 -and $loader -eq 'iris') { $vers = Get-Json $base }
            } catch {
                $estado.Fallos++; $sync.Errores++
                Log "$nombre (no se pudo consultar)" 'error'
                return
            }
            if ($vers.Count -eq 0) {
                $sync.Omitidos++
                Log "$nombre (sin versión para $mc)" 'omitido'
                return
            }
            $v = $vers[0]
            foreach ($c in $vers) { if ($c.version_type -eq 'release') { $v = $c; break } }
            $f = $v.files[0]
            foreach ($c in $v.files) { if ($c.primary -eq $true) { $f = $c; break } }
            $clave = "$destino|$($f.filename)"
            if (-not $archivos.ContainsKey($clave)) {
                $archivos[$clave] = $true
                [void]$plan.Add([pscustomobject]@{
                    Archivo = $f.filename; Url = $f.url; Tam = [long]$f.size; Destino = $destino
                    Existe  = (Test-Path -LiteralPath (Join-Path $destino $f.filename))
                })
            }
            if ($loader -eq 'neoforge') {
                foreach ($d in $v.dependencies) {
                    if ($d.dependency_type -eq 'required' -and $d.project_id) { Resolver $d.project_id $loader $destino $(if ($padre) { $padre } else { $slug }) }
                }
            }
        }

        foreach ($s in ($modsAmbos + $modsSoloCliente)) { Resolver $s 'neoforge' $mods }
        foreach ($s in $shaders) { Resolver $s 'iris' $shadersDir }
        $sync.Actual = ''

        $sync.ModsTotal     = @($plan | Where-Object { $_.Destino -eq $mods }).Count
        $sync.ModsListos    = @($plan | Where-Object { $_.Destino -eq $mods -and $_.Existe }).Count
        $sync.ShadersTotal  = @($plan | Where-Object { $_.Destino -eq $shadersDir }).Count
        $sync.ShadersListos = @($plan | Where-Object { $_.Destino -eq $shadersDir -and $_.Existe }).Count

        foreach ($p in $plan) { if ($p.Existe) { $sync.YaEstaban++; Log $p.Archivo 'ya' $p.Tam } }
        $faltan = @($plan | Where-Object { -not $_.Existe })   # primero mods y despues shaders
        $sync.Total = [long](($faltan | Measure-Object -Property Tam -Sum).Sum)

        # --- Descargar lo que falta (mods = paso 2, shaders = paso 3) ---
        $sync.Hecho = [long]0
        $sync.Indeterminado = $false
        $sync.Descargando = $true
        foreach ($p in $faltan) {
            $esShader = ($p.Destino -eq $shadersDir)
            if ($esShader) { $sync.Paso = 3; $sync.Fase = 'Descargando shaders...' }
            else { $sync.Fase = 'Descargando mods...' }
            $sync.Actual = $p.Archivo
            $sync.ArchivoTotal = [long]$p.Tam
            $sync.ArchivoHecho = [long]0
            try {
                Descargar $p.Url (Join-Path $p.Destino $p.Archivo)
                $sync.Nuevos++
                if ($esShader) { $sync.ShadersListos++ } else { $sync.ModsListos++ }
                Log $p.Archivo 'nuevo' $p.Tam
            } catch {
                if ($sync.Cancelar) { throw }
                $estado.Fallos++; $sync.Errores++
                Log $p.Archivo 'error' $p.Tam
            }
        }
        $sync.Descargando = $false
        $sync.Actual = ''
        $sync.Paso = 4

        # --- Quitar mods que ya no estan en la lista (se mueven, no se borran) ---
        if ($estado.Fallos -eq 0) {
            $sync.Fase = 'Respaldando mods que ya no se usan...'
            $validos = @{}
            foreach ($p in $plan) { if ($p.Destino -eq $mods) { $validos[$p.Archivo] = $true } }
            $sobran = @(Get-ChildItem -LiteralPath $mods -Filter *.jar | Where-Object { -not $validos.ContainsKey($_.Name) })
            if ($sobran.Count -gt 0) {
                $resp = Join-Path $mcDir ('mods-respaldo-' + (Get-Date -Format 'yyyy-MM-dd-HHmmss'))
                New-Item -ItemType Directory -Force -Path $resp | Out-Null
                foreach ($j in $sobran) {
                    Move-Item -LiteralPath $j.FullName -Destination $resp -Force
                    $sync.Quitados++
                }
                $que = if ($sobran.Count -eq 1) { '1 mod antiguo' } else { "$($sobran.Count) mods antiguos" }
                Log "$que → $(Split-Path $resp -Leaf)" 'respaldo'
            }
        } else {
            Log 'Hubo errores con Modrinth: no se quitó ningún mod, por seguridad.' 'error'
        }

        # --- Configuraciones de Diego (archivos\configs -> .minecraft\config) ---
        # Se copian solo la primera vez. Despues, si el jugador cambia algo, se respetan
        # sus cambios. Los ya entregados se anotan en config\.configs-de-diego.txt
        $origenCfg = Join-Path $carpeta 'configs'
        if (Test-Path -LiteralPath $origenCfg) {
            $sync.Fase = 'Copiando configuraciones...'
            $cfgDir = Join-Path $mcDir 'config'
            $marca  = Join-Path $cfgDir '.configs-de-diego.txt'
            $entregados = @()
            if (Test-Path -LiteralPath $marca) { $entregados = @(Get-Content -LiteralPath $marca) }
            foreach ($f in @(Get-ChildItem -LiteralPath $origenCfg -File -Recurse)) {
                $rel = $f.FullName.Substring($origenCfg.Length + 1)
                $dest = Join-Path $cfgDir $rel
                if ((Test-Path -LiteralPath $dest) -and ($entregados -contains $rel)) {
                    Log "config\$rel" 'ya'
                    continue
                }
                try {
                    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
                    if (Test-Path -LiteralPath $dest) { Copy-Item -LiteralPath $dest ($dest + '.respaldo') -Force }
                    Copy-Item -LiteralPath $f.FullName $dest -Force
                    if ($entregados -notcontains $rel) { Add-Content -LiteralPath $marca -Value $rel }
                    Log "config\$rel" 'nuevo'
                } catch { Log "config\$rel" 'error' }
            }
        }

        # --- Carpetas de respaldo de mods (solo si el usuario dijo que si) ---
        if ($sync.BorrarRespaldo) {
            $sync.Fase = 'Borrando respaldos antiguos...'
            foreach ($r in @(Get-ChildItem -LiteralPath $mcDir -Directory -Filter 'mods-respaldo-*')) {
                try {
                    Remove-Item -LiteralPath $r.FullName -Recurse -Force
                    Log $r.Name 'borrado'
                } catch { Log "No se pudo borrar $($r.Name)" 'error' }
            }
        }
        $sync.Fase = 'Terminado'
    } catch {
        if ($sync.Cancelar) { $sync.Error = 'Instalación cancelada.' }
        else { $sync.Error = $_.Exception.Message }
    } finally {
        $sync.Descargando = $false
        $sync.Terminado = $true
    }
}

# ---------------------------------------------------------------------
# 1b) TRABAJO DE DEMOSTRACION (-Demo): mismo estado, datos inventados
# ---------------------------------------------------------------------
$trabajoDemo = {
    function Log($texto, $tipo = 'info', $tam = $null) {
        $sync.Log.Enqueue([pscustomobject]@{ Texto = $texto; Tipo = $tipo; Tam = $tam })
    }
    function Esperar($ms) {
        $fin = [DateTime]::Now.AddMilliseconds($ms)
        while ([DateTime]::Now -lt $fin) { if ($sync.Cancelar) { throw 'CANCELADO' }; Start-Sleep -Milliseconds 50 }
    }
    try {
        $rnd = New-Object System.Random
        $sync.Fase = 'Buscando la lista de mods...'; Esperar 900
        Log 'Lista de mods: internet (lista más reciente)' 'info'
        $sync.Fase = 'Instalando NeoForge...'; Esperar 1500
        Log 'NeoForge 21.1.265' 'nuevo'; $sync.NeoListo = $true

        $sync.Paso = 2; $sync.Fase = 'Revisando la lista en Modrinth...'
        foreach ($s in 'create', 'jei', 'sodium', 'iris', 'mekanism', 'ae2') { $sync.Actual = "Consultando: $s"; Esperar 180 }
        $sync.Actual = ''
        $nombres = 'jei-1.21.1.jar', 'sodium-neoforge.jar', 'iris-neoforge.jar', 'mekanism-1.21.1.jar',
            'ae2-19.2.jar', 'ars_nouveau-5.6.jar', 'aether-1.5.jar', 'farmersdelight-1.2.jar', 'waystones-21.1.jar',
            'sophisticatedbackpacks-3.23.jar', 'xaerominimap-25.2.jar', 'xaeroworldmap-1.39.jar', 'jade-15.10.jar',
            'appleskin-3.0.jar', 'create-1.21.1.jar', 'biomesoplenty-21.1.jar', 'terralith-2.5.jar',
            'iceandfire-2.1.jar', 'supplementaries-3.1.jar', 'storagedrawers-13.8.jar', 'cloth-config-15.0.jar',
            'architectury-13.0.jar', 'curios-9.0.jar', 'geckolib-4.7.jar', 'balm-21.0.jar', 'ftb-library-2101.jar',
            'ftb-quests-2101.jar', 'ftb-teams-2101.jar', 'chipped-4.0.jar', 'handcrafted-4.0.jar',
            'macaw-bridges-3.0.jar', 'macaw-roofs-2.3.jar', 'naturescompass-3.0.jar', 'explorerscompass-3.0.jar',
            'yungsapi-5.1.jar', 'betterdungeons-5.1.jar', 'bettermineshafts-5.1.jar', 'betterstrongholds-5.1.jar',
            'cataclysm-3.1.jar', 'bosses-of-mass-destruction.jar', 'immersive-engineering-12.jar',
            'thermal-foundation-11.jar', 'cofh-core-11.jar', 'mousetweaks-2.26.jar', 'inventoryprofilesnext.jar',
            'controlling-19.0.jar', 'searchables-1.0.jar', 'entityculling-1.7.jar'
        $plan = @(foreach ($n in $nombres) { [pscustomobject]@{ Archivo = $n; Tam = [long]($rnd.Next(300, 12000) * 1KB); Shader = $false } })
        $plan += [pscustomobject]@{ Archivo = 'ComplementaryReimagined_r5.zip'; Tam = [long](4MB); Shader = $true }
        $plan += [pscustomobject]@{ Archivo = 'BSL_v10.0.zip'; Tam = [long](2MB); Shader = $true }
        $yaEstaban = @($plan | Where-Object { -not $_.Shader } | Select-Object -First 18)
        foreach ($p in $yaEstaban) { Log $p.Archivo 'ya' $p.Tam; $sync.YaEstaban++ }
        $faltan = @($plan | Where-Object { $yaEstaban -notcontains $_ })
        $sync.ModsTotal = $nombres.Count; $sync.ModsListos = $yaEstaban.Count
        $sync.ShadersTotal = 2; $sync.ShadersListos = 0
        $sync.Total = [long](($faltan | Measure-Object -Property Tam -Sum).Sum)
        $sync.Hecho = [long]0; $sync.Indeterminado = $false; $sync.Descargando = $true
        $i = 0
        foreach ($p in $faltan) {
            $i++
            if ($p.Shader) { $sync.Paso = 3; $sync.Fase = 'Descargando shaders...' } else { $sync.Fase = 'Descargando mods...' }
            $sync.Actual = $p.Archivo; $sync.ArchivoTotal = $p.Tam; $sync.ArchivoHecho = [long]0
            $velocidad = $rnd.Next(6, 11) * 1MB / 20      # bytes cada 50 ms
            while ($sync.ArchivoHecho -lt $p.Tam) {
                if ($sync.Cancelar) { throw 'CANCELADO' }
                $n = [long][math]::Min($velocidad, $p.Tam - $sync.ArchivoHecho)
                $sync.ArchivoHecho += $n; $sync.Hecho += $n
                Start-Sleep -Milliseconds 50
            }
            $sync.Nuevos++
            if ($p.Shader) { $sync.ShadersListos++ } else { $sync.ModsListos++ }
            Log $p.Archivo 'nuevo' $p.Tam
            if ($i -eq 4) { Log "3 mods antiguos → mods-respaldo-$(Get-Date -Format 'yyyy-MM-dd')" 'respaldo'; $sync.Quitados = 3 }
        }
        $sync.Descargando = $false; $sync.Actual = ''; $sync.Paso = 4
        $sync.Fase = 'Copiando configuraciones...'; Esperar 700
        Log 'config\inventoryprofilesnext\inventoryprofiles.json' 'ya'
        $sync.Fase = 'Terminado'
    } catch {
        if ($sync.Cancelar) { $sync.Error = 'Instalación cancelada.' } else { $sync.Error = $_.Exception.Message }
    } finally {
        $sync.Descargando = $false
        $sync.Terminado = $true
    }
}

# ---------------------------------------------------------------------
# 2) VENTANA (XAML)
# ---------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Instalador · Los Varchar2"
        Width="760" Height="730" MinWidth="700" MinHeight="680"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize"
        Background="#16191F" Foreground="#E6E9EE" FontFamily="Segoe UI"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display">
  <!-- Ventana sin el marco de Windows: la barra de titulo la dibujamos nosotros -->
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="36" ResizeBorderThickness="6" GlassFrameThickness="0"
                  CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>

  <Window.Resources>
    <!-- Botones de la barra de titulo (minimizar / maximizar) -->
    <Style x:Key="BotonVentana" TargetType="Button">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Foreground" Value="#E6FFFFFF"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="fondo" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="fondo" Property="Background" Value="#26FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BotonVentanaCerrar" TargetType="Button" BasedOn="{StaticResource BotonVentana}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="fondo" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="fondo" Property="Background" Value="#E81123"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Boton verde principal (con brillo que late mientras instala) -->
    <Style x:Key="BotonPrimario" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="brillo" CornerRadius="14" Background="#6FD157" Opacity="0.35" Margin="-3">
                <Border.Effect><BlurEffect Radius="22"/></Border.Effect>
              </Border>
              <Border CornerRadius="12" Background="#3B8A2A"/>
              <Border CornerRadius="12" Margin="0,0,0,3" BorderBrush="#B4F39A" BorderThickness="0,1,0,0">
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                    <GradientStop Color="#8AE266" Offset="0"/>
                    <GradientStop Color="#62BD44" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
              </Border>
              <Border x:Name="luz" CornerRadius="12" Margin="0,0,0,3" Background="White" Opacity="0"/>
              <ContentPresenter Margin="0,0,0,3" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="luz" Property="Opacity" Value="0.14"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="luz" Property="Background" Value="Black"/>
                <Setter TargetName="luz" Property="Opacity" Value="0.12"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Trigger.EnterActions>
                  <BeginStoryboard x:Name="latido">
                    <Storyboard RepeatBehavior="Forever" AutoReverse="True">
                      <DoubleAnimation Storyboard.TargetName="brillo" Storyboard.TargetProperty="Opacity"
                                       From="0.25" To="0.65" Duration="0:0:0.9"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions><StopStoryboard BeginStoryboardName="latido"/></Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Boton secundario (Cancelar / Cerrar) -->
    <Style x:Key="BotonSecundario" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#E6E9EE"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="fondo" CornerRadius="12" Background="#171A20" BorderBrush="#3A404B" BorderThickness="1.5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="fondo" Property="Background" Value="#22262E"/>
                <Setter TargetName="fondo" Property="BorderBrush" Value="#4B5260"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="fondo" Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Chip" TargetType="Border">
      <Setter Property="CornerRadius" Value="15"/>
      <Setter Property="Background" Value="#C2121419"/>
      <Setter Property="BorderBrush" Value="#3DFFFFFF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="13,5,13,6"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
    </Style>
    <Style x:Key="Tarjeta" TargetType="Border">
      <Setter Property="CornerRadius" Value="16"/>
      <Setter Property="Background" Value="#1D2129"/>
      <Setter Property="BorderBrush" Value="#272C35"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style x:Key="TituloPaso" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="SubPaso" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Foreground" Value="#8B93A1"/>
    </Style>
  </Window.Resources>

  <Grid x:Name="raiz">
    <Grid.RowDefinitions>
      <RowDefinition Height="240"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- ===== Cabecera pixel-art ===== -->
    <Grid x:Name="cabecera" Grid.Row="0" ClipToBounds="True" Background="#16191F">
      <Image x:Name="imgCabecera" Stretch="UniformToFill" VerticalAlignment="Bottom"
             RenderOptions.BitmapScalingMode="NearestNeighbor"/>
      <Rectangle IsHitTestVisible="False">
        <Rectangle.Fill>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#0016191F" Offset="0.70"/>
            <GradientStop Color="#9916191F" Offset="0.86"/>
            <GradientStop Color="#FF16191F" Offset="1"/>
          </LinearGradientBrush>
        </Rectangle.Fill>
      </Rectangle>

      <TextBlock Text="Instalador · Los Varchar2" Margin="14,9,0,0" FontSize="13"
                 Foreground="#E6FFFFFF" HorizontalAlignment="Left" VerticalAlignment="Top"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
        <Button x:Name="btnMin" Style="{StaticResource BotonVentana}" ToolTip="Minimizar">
          <Path Data="M0,0.5 H10" Stroke="White" StrokeThickness="1"/>
        </Button>
        <Button x:Name="btnMax" Style="{StaticResource BotonVentana}" ToolTip="Maximizar">
          <Rectangle Width="10" Height="10" Stroke="White" StrokeThickness="1"/>
        </Button>
        <Button x:Name="btnX" Style="{StaticResource BotonVentanaCerrar}" ToolTip="Cerrar">
          <Path Data="M0,0 L10,10 M10,0 L0,10" Stroke="White" StrokeThickness="1"/>
        </Button>
      </StackPanel>

      <!-- Titulo pixelado (se dibuja por codigo) -->
      <ContentControl x:Name="ccTitulo" HorizontalAlignment="Left" VerticalAlignment="Top"
                      Margin="40,130,0,0" IsHitTestVisible="False"/>

      <!-- Frase amarilla que late, como en la pantalla de titulo del juego -->
      <ContentControl x:Name="ccSplash" HorizontalAlignment="Left" VerticalAlignment="Top"
                      Margin="488,50,0,0" Cursor="Hand" ToolTip="Haz clic para otra frase"
                      RenderTransformOrigin="0.5,0.5" Background="Transparent">
        <ContentControl.LayoutTransform><RotateTransform Angle="-12"/></ContentControl.LayoutTransform>
        <ContentControl.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></ContentControl.RenderTransform>
        <ContentControl.Triggers>
          <EventTrigger RoutedEvent="FrameworkElement.Loaded">
            <BeginStoryboard>
              <Storyboard RepeatBehavior="Forever" AutoReverse="True">
                <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" From="1" To="1.08" Duration="0:0:0.45"/>
                <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" From="1" To="1.08" Duration="0:0:0.45"/>
              </Storyboard>
            </BeginStoryboard>
          </EventTrigger>
        </ContentControl.Triggers>
      </ContentControl>

      <!-- Chips con las versiones -->
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="36,188,0,0">
        <Border Style="{StaticResource Chip}">
          <TextBlock FontSize="14" FontWeight="SemiBold" Foreground="White">
            <Run Text="Minecraft "/><Run x:Name="runMc" Text="1.21.1" Foreground="#7FDB5C"/>
          </TextBlock>
        </Border>
        <Border Style="{StaticResource Chip}">
          <TextBlock FontSize="14" FontWeight="SemiBold" Foreground="White">
            <Run Text="NeoForge "/><Run x:Name="runNeo" Text="21.1" Foreground="#7FDB5C"/>
          </TextBlock>
        </Border>
        <Border Style="{StaticResource Chip}">
          <TextBlock FontSize="14" FontWeight="SemiBold" Foreground="White">
            <Run x:Name="runCantMods" Text="0" Foreground="#7FDB5C"/><Run x:Name="runModsTxt" Text=" mods · "/><Run x:Name="runCantShaders" Text="0" Foreground="#7FDB5C"/><Run x:Name="runShadersTxt" Text=" shaders"/>
          </TextBlock>
        </Border>
      </StackPanel>
    </Grid>

    <!-- ===== Tarjeta de progreso ===== -->
    <Border Grid.Row="1" Style="{StaticResource Tarjeta}" Margin="36,8,36,0" Padding="22,18,22,18">
      <StackPanel>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel VerticalAlignment="Center">
            <TextBlock x:Name="lblEstado" FontSize="12.5" FontWeight="SemiBold" Foreground="#8B93A1"/>
            <TextBlock x:Name="txtFase" FontSize="22" FontWeight="SemiBold" Foreground="White"
                       Margin="0,3,0,0" TextWrapping="Wrap"/>
          </StackPanel>
          <TextBlock Grid.Column="1" VerticalAlignment="Center" Foreground="#74D45A" Margin="16,0,0,0">
            <Run x:Name="runPct" Text="0" FontSize="44" FontWeight="Bold"/><Run x:Name="runPctSigno" Text="%" FontSize="24" FontWeight="Bold"/>
          </TextBlock>
        </Grid>

        <ProgressBar x:Name="barra" Height="22" Minimum="0" Maximum="100" Value="0" Margin="0,14,0,0">
          <ProgressBar.Template>
            <ControlTemplate TargetType="ProgressBar">
              <Border CornerRadius="11" Background="#0F1115" BorderBrush="#232831" BorderThickness="1">
                <Grid Margin="1">
                  <Border x:Name="PART_Track"/>
                  <Border x:Name="PART_Indicator" HorizontalAlignment="Left" CornerRadius="10">
                    <Border.Background>
                      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                        <GradientStop Color="#8FE56C" Offset="0"/>
                        <GradientStop Color="#5DBA40" Offset="1"/>
                      </LinearGradientBrush>
                    </Border.Background>
                    <!-- Segmentos tipo bloque -->
                    <Border CornerRadius="10">
                      <Border.Background>
                        <DrawingBrush TileMode="Tile" Viewport="0,0,24,20" ViewportUnits="Absolute"
                                      Viewbox="0,0,24,20" ViewboxUnits="Absolute" Stretch="Fill">
                          <DrawingBrush.Drawing>
                            <DrawingGroup>
                              <GeometryDrawing Brush="#00000000">
                                <GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,24,20"/></GeometryDrawing.Geometry>
                              </GeometryDrawing>
                              <GeometryDrawing Brush="#40205010">
                                <GeometryDrawing.Geometry><RectangleGeometry Rect="22,0,2,20"/></GeometryDrawing.Geometry>
                              </GeometryDrawing>
                              <GeometryDrawing Brush="#30FFFFFF">
                                <GeometryDrawing.Geometry><RectangleGeometry Rect="0,2,22,3"/></GeometryDrawing.Geometry>
                              </GeometryDrawing>
                            </DrawingGroup>
                          </DrawingBrush.Drawing>
                        </DrawingBrush>
                      </Border.Background>
                    </Border>
                  </Border>
                </Grid>
              </Border>
            </ControlTemplate>
          </ProgressBar.Template>
        </ProgressBar>

        <Grid Margin="0,12,0,0">
          <StackPanel Orientation="Horizontal">
            <TextBlock FontSize="15.5">
              <Run x:Name="runHecho" Text="—" Foreground="#F3F4F6" FontWeight="SemiBold"/><Run x:Name="runTotal" Text="" Foreground="#8B93A1"/>
            </TextBlock>
            <TextBlock FontSize="15.5" Margin="30,0,0,0">
              <Run x:Name="runVel" Text="" Foreground="#F3F4F6" FontWeight="SemiBold"/><Run x:Name="runVelUnidad" Text="" Foreground="#8B93A1"/>
            </TextBlock>
          </StackPanel>
          <TextBlock FontSize="15.5" HorizontalAlignment="Right">
            <Run x:Name="runRestEtiqueta" Text="" Foreground="#8B93A1"/><Run x:Name="runRestante" Text="" Foreground="#F3F4F6" FontWeight="SemiBold"/>
          </TextBlock>
        </Grid>

        <Border Height="1" Background="#2A2F38" Margin="0,16,0,14"/>

        <!-- Pasos: NeoForge -> Mods -> Shaders -->
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>

          <StackPanel Grid.Column="0" Orientation="Horizontal">
            <Border x:Name="anillo1" Width="44" Height="44" CornerRadius="12">
              <Border x:Name="paso1" Width="36" Height="36" CornerRadius="9">
                <Grid>
                  <TextBlock x:Name="num1" Text="1" FontSize="17" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <Path x:Name="chk1" Data="M11,18.5 L16,23.5 L25.5,13" Stroke="#7CD957" StrokeThickness="2.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                </Grid>
              </Border>
            </Border>
            <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
              <TextBlock x:Name="tit1" Text="NeoForge" Style="{StaticResource TituloPaso}"/>
              <TextBlock x:Name="sub1" Style="{StaticResource SubPaso}"/>
            </StackPanel>
          </StackPanel>
          <Border x:Name="linea1" Grid.Column="1" Height="2" CornerRadius="1" Margin="18,0" VerticalAlignment="Center"/>

          <StackPanel Grid.Column="2" Orientation="Horizontal">
            <Border x:Name="anillo2" Width="44" Height="44" CornerRadius="12">
              <Border x:Name="paso2" Width="36" Height="36" CornerRadius="9">
                <Grid>
                  <TextBlock x:Name="num2" Text="2" FontSize="17" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <Path x:Name="chk2" Data="M11,18.5 L16,23.5 L25.5,13" Stroke="#7CD957" StrokeThickness="2.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                </Grid>
              </Border>
            </Border>
            <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
              <TextBlock x:Name="tit2" Text="Mods" Style="{StaticResource TituloPaso}"/>
              <TextBlock x:Name="sub2" Style="{StaticResource SubPaso}"/>
            </StackPanel>
          </StackPanel>
          <Border x:Name="linea2" Grid.Column="3" Height="2" CornerRadius="1" Margin="18,0" VerticalAlignment="Center"/>

          <StackPanel Grid.Column="4" Orientation="Horizontal">
            <Border x:Name="anillo3" Width="44" Height="44" CornerRadius="12">
              <Border x:Name="paso3" Width="36" Height="36" CornerRadius="9">
                <Grid>
                  <TextBlock x:Name="num3" Text="3" FontSize="17" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <Path x:Name="chk3" Data="M11,18.5 L16,23.5 L25.5,13" Stroke="#7CD957" StrokeThickness="2.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                </Grid>
              </Border>
            </Border>
            <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
              <TextBlock x:Name="tit3" Text="Shaders" Style="{StaticResource TituloPaso}"/>
              <TextBlock x:Name="sub3" Style="{StaticResource SubPaso}"/>
            </StackPanel>
          </StackPanel>
        </Grid>
      </StackPanel>
    </Border>

    <!-- ===== Tarjeta con la lista de archivos ===== -->
    <Border Grid.Row="2" Style="{StaticResource Tarjeta}" Margin="36,12,36,0" Padding="14,12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <!-- Archivo que se esta descargando ahora -->
        <Border x:Name="filaActual" Visibility="Collapsed" CornerRadius="9" Background="#262B34"
                Padding="10,7" Margin="0,0,0,3">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="40"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <ContentControl x:Name="ccIconoActual" VerticalAlignment="Center"/>
            <TextBlock x:Name="txtActual" Grid.Column="1" FontSize="15" FontWeight="SemiBold" Foreground="#F3F4F6"
                       VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            <Grid Grid.Column="2" Width="140" Height="6" Margin="14,0,16,0" VerticalAlignment="Center">
              <Border CornerRadius="3" Background="#0F1115"/>
              <Border x:Name="rellenoArchivo" CornerRadius="3" Background="#7FB2F0" HorizontalAlignment="Left" Width="0"/>
            </Grid>
            <TextBlock x:Name="txtTamActual" Grid.Column="3" FontSize="14.5" Foreground="#8B93A1"
                       VerticalAlignment="Center" Margin="0,0,14,0"/>
            <Border Grid.Column="4" CornerRadius="11" Background="#1E3350" Padding="11,3,11,4" VerticalAlignment="Center">
              <TextBlock Text="Bajando" FontSize="13.5" FontWeight="SemiBold" Foreground="#8CBEF5"/>
            </Border>
          </Grid>
        </Border>
        <!-- Resto de la lista (lo mas nuevo arriba). Rueda del mouse para ver todo. -->
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="panelFilas"/>
        </ScrollViewer>
      </Grid>
    </Border>

    <!-- ===== Pie: nota + botones ===== -->
    <Grid Grid.Row="3" Margin="36,16,36,22">
      <TextBlock x:Name="txtPie" FontSize="13.5" Foreground="#7C8491" VerticalAlignment="Center"
                 TextWrapping="Wrap" Margin="0,0,330,0"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="btnCerrar" Content="Cerrar" Style="{StaticResource BotonSecundario}" Width="118" Height="48"/>
        <Button x:Name="btnInstalar" Style="{StaticResource BotonPrimario}" Width="190" Height="50" Margin="14,0,0,0"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@

# ---------------------------------------------------------------------
# 3) DIBUJO: colores, fuente pixelada y cabecera
# ---------------------------------------------------------------------
$conv = New-Object System.Windows.Media.BrushConverter
function Color($hex) { $conv.ConvertFromString($hex) }

# Fuente de 5x7 pixeles ('#' = pixel encendido, filas separadas por '|')
$fuentePixel = @{
    'A' = '.###.|#...#|#...#|#####|#...#|#...#|#...#'; 'B' = '####.|#...#|#...#|####.|#...#|#...#|####.'
    'C' = '.###.|#...#|#....|#....|#....|#...#|.###.'; 'D' = '####.|#...#|#...#|#...#|#...#|#...#|####.'
    'E' = '#####|#....|#....|####.|#....|#....|#####'; 'F' = '#####|#....|#....|####.|#....|#....|#....'
    'G' = '.###.|#...#|#....|#.###|#...#|#...#|.####'; 'H' = '#...#|#...#|#...#|#####|#...#|#...#|#...#'
    'I' = '###|.#.|.#.|.#.|.#.|.#.|###';             'J' = '..###|....#|....#|....#|#...#|#...#|.###.'
    'K' = '#...#|#..#.|#.#..|##...|#.#..|#..#.|#...#'; 'L' = '#....|#....|#....|#....|#....|#....|#####'
    'M' = '#...#|##.##|#.#.#|#.#.#|#...#|#...#|#...#'; 'N' = '#...#|##..#|#.#.#|#..##|#...#|#...#|#...#'
    'O' = '.###.|#...#|#...#|#...#|#...#|#...#|.###.'; 'P' = '####.|#...#|#...#|####.|#....|#....|#....'
    'Q' = '.###.|#...#|#...#|#...#|#.#.#|#..#.|.##.#'; 'R' = '####.|#...#|#...#|####.|#.#..|#..#.|#...#'
    'S' = '.####|#....|#....|.###.|....#|....#|####.'; 'T' = '#####|..#..|..#..|..#..|..#..|..#..|..#..'
    'U' = '#...#|#...#|#...#|#...#|#...#|#...#|.###.'; 'V' = '#...#|#...#|#...#|#...#|#...#|.#.#.|..#..'
    'W' = '#...#|#...#|#...#|#.#.#|#.#.#|##.##|#...#'; 'X' = '#...#|#...#|.#.#.|..#..|.#.#.|#...#|#...#'
    'Y' = '#...#|#...#|.#.#.|..#..|..#..|..#..|..#..'; 'Z' = '#####|....#|...#.|..#..|.#...|#....|#####'
    '0' = '.###.|#...#|#..##|#.#.#|##..#|#...#|.###.'; '1' = '..#..|.##..|..#..|..#..|..#..|..#..|.###.'
    '2' = '.###.|#...#|....#|...#.|..#..|.#...|#####'; '3' = '####.|....#|....#|.###.|....#|....#|####.'
    '4' = '...#.|..##.|.#.#.|#..#.|#####|...#.|...#.'; '5' = '#####|#....|####.|....#|....#|#...#|.###.'
    '6' = '.###.|#....|#....|####.|#...#|#...#|.###.'; '7' = '#####|....#|...#.|..#..|..#..|..#..|..#..'
    '8' = '.###.|#...#|#...#|.###.|#...#|#...#|.###.'; '9' = '.###.|#...#|#...#|.####|....#|....#|.###.'
    ' ' = '...|...|...|...|...|...|...';               '!' = '#|#|#|#|#|.|#'
    '¡' = '#|.|#|#|#|#|#';                             '.' = '.|.|.|.|.|.|#'
    ',' = '.|.|.|.|.|#|#';                             ':' = '.|#|.|.|.|#|.'
    "'" = '#|#|.|.|.|.|.';                             '-' = '...|...|...|###|...|...|...'
    '(' = '.#|#.|#.|#.|#.|#.|.#';                      ')' = '#.|.#|.#|.#|.#|.#|#.'
    '*' = '.....|#.#.#|.###.|#####|.###.|#.#.#|.....'; '%' = '##..#|##..#|...#.|..#..|.#...|#..##|#..##'
    '?' = '.###.|#...#|....#|...#.|..#..|.....|..#..'; '¿' = '..#..|.....|..#..|.#...|#....|#...#|.###.'
}
$acentosPixel = @{ 'Á' = 'A'; 'É' = 'E'; 'Í' = 'I'; 'Ó' = 'O'; 'Ú' = 'U'; 'Ñ' = 'N' }

# Convierte un texto en una figura hecha de cuadraditos (cada pixel mide $px)
function New-PixelGeometry([string]$texto, [int]$px, [int]$espacio = 1) {
    $texto = $texto.ToUpperInvariant()
    $lineas = $texto -split "`n"
    $arriba = if ($texto -match '[ÁÉÍÓÚÑ]') { 3 } else { 0 }   # espacio para tildes
    $sb = New-Object System.Text.StringBuilder
    for ($l = 0; $l -lt $lineas.Count; $l++) {
        $oy = $l * (7 + $arriba + 3)
        $ox = 0
        foreach ($ch in $lineas[$l].ToCharArray()) {
            $s = [string]$ch
            $extra = @('', '', '')
            if ($acentosPixel.ContainsKey($s)) {
                $extra = if ($s -eq 'Ñ') { @('.##.#', '#.##.', '') } elseif ($s -eq 'Í') { @('..#', '.#.', '') } else { @('...#.', '..#..', '') }
                $s = $acentosPixel[$s]
            }
            $g = $fuentePixel[$s]
            if (-not $g) { $g = $fuentePixel[' '] }
            $filas = @($g.Split('|'))
            $todas = if ($arriba) { $extra + $filas } else { $filas }
            for ($r = 0; $r -lt $todas.Count; $r++) {
                $fila = $todas[$r]
                $col = 0
                while ($col -lt $fila.Length) {
                    if ($fila[$col] -eq '#') {
                        $ini = $col
                        while ($col -lt $fila.Length -and $fila[$col] -eq '#') { $col++ }
                        $x = ($ox + $ini) * $px; $y = ($oy + $r) * $px; $w = ($col - $ini) * $px
                        [void]$sb.Append("M$x,$($y)h$($w)v$($px)h-$($w)z")
                    } else { $col++ }
                }
            }
            $ox += $filas[0].Length + $espacio
        }
    }
    if ($sb.Length -eq 0) { return [System.Windows.Media.Geometry]::Empty }
    return [System.Windows.Media.Geometry]::Parse($sb.ToString())
}

# Texto pixelado listo para poner en la ventana (con sombra opcional)
function New-PixelText([string]$texto, [int]$px, [string]$relleno, [string]$sombra = '', [int]$espacio = 1) {
    $geo = New-PixelGeometry $texto $px $espacio
    $g = New-Object System.Windows.Controls.Grid
    if ($sombra) {
        $ps = New-Object System.Windows.Shapes.Path
        $ps.Data = $geo; $ps.Fill = Color $sombra
        $ps.Margin = New-Object System.Windows.Thickness($px, $px, 0, 0)
        [void]$g.Children.Add($ps)
    }
    $p = New-Object System.Windows.Shapes.Path
    $p.Data = $geo; $p.Fill = Color $relleno
    [void]$g.Children.Add($p)
    return $g
}

# Parte una frase en lineas de hasta $max letras
function Partir([string]$frase, [int]$max) {
    $lineas = @(); $actual = ''
    foreach ($p in $frase.Split(' ')) {
        if ($actual.Length -eq 0) { $actual = $p }
        elseif (($actual.Length + 1 + $p.Length) -le $max) { $actual += " $p" }
        else { $lineas += $actual; $actual = $p }
    }
    if ($actual) { $lineas += $actual }
    return ($lineas -join "`n")
}

# Pinta un rectangulo en el bitmap de la cabecera ($a = opacidad 0..1)
function Pintar($pix, $anchoImg, $altoImg, $x, $y, $w, $h, $hex, $a = 1.0) {
    $r = [Convert]::ToInt32($hex.Substring(1, 2), 16)
    $gg = [Convert]::ToInt32($hex.Substring(3, 2), 16)
    $b = [Convert]::ToInt32($hex.Substring(5, 2), 16)
    for ($yy = [math]::Max(0, $y); $yy -lt [math]::Min($altoImg, $y + $h); $yy++) {
        for ($xx = [math]::Max(0, $x); $xx -lt [math]::Min($anchoImg, $x + $w); $xx++) {
            $i = ($yy * $anchoImg + $xx) * 4
            $pix[$i]     = [byte]($pix[$i] * (1 - $a) + $b * $a)
            $pix[$i + 1] = [byte]($pix[$i + 1] * (1 - $a) + $gg * $a)
            $pix[$i + 2] = [byte]($pix[$i + 2] * (1 - $a) + $r * $a)
            $pix[$i + 3] = 255
        }
    }
}

# Atardecer pixel-art: cielo, nubes, sol, colinas, pasto, tierra y arboles.
# Se dibuja a 190x60 pixeles y la ventana lo agranda x4 sin suavizar.
function Escena-Cabecera {
    $anchoImg = 190; $altoImg = 60
    $pix = New-Object byte[] ($anchoImg * $altoImg * 4)
    $rnd = New-Object System.Random 11      # semilla fija: siempre el mismo paisaje

    # Cielo en franjas (degradado azul -> violeta -> rosado -> naranjo)
    $paradas = @(@(0.0, 0x2B, 0x37, 0x68), @(0.35, 0x4B, 0x47, 0x88), @(0.62, 0x8F, 0x5C, 0x8C), @(0.82, 0xCF, 0x74, 0x7E), @(1.0, 0xEC, 0x9B, 0x7A))
    for ($y = 0; $y -lt $altoImg; $y++) {
        $t = [math]::Min(1.0, ([math]::Floor($y / 3) * 3) / 44.0)
        for ($k = 0; $k -lt $paradas.Count - 1; $k++) {
            $p0 = $paradas[$k]; $p1 = $paradas[$k + 1]
            if ($t -le $p1[0]) {
                $f = ($t - $p0[0]) / ($p1[0] - $p0[0])
                $hex = '#{0:X2}{1:X2}{2:X2}' -f [int]($p0[1] + ($p1[1] - $p0[1]) * $f), [int]($p0[2] + ($p1[2] - $p0[2]) * $f), [int]($p0[3] + ($p1[3] - $p0[3]) * $f)
                Pintar $pix $anchoImg $altoImg 0 $y $anchoImg 1 $hex
                break
            }
        }
    }
    # Sol cuadrado con resplandor
    Pintar $pix $anchoImg $altoImg 134 17 22 21 '#F7C08C' 0.25
    Pintar $pix $anchoImg $altoImg 137 20 16 15 '#F7C08C' 0.35
    Pintar $pix $anchoImg $altoImg 140 22 10 10 '#FFE9A6'
    # Nubes
    foreach ($n in @(@(60, 7, 22), @(20, 12, 16), @(105, 15, 14), @(165, 9, 18))) {
        Pintar $pix $anchoImg $altoImg $n[0] $n[1] $n[2] 3 '#B9A6C6' 0.92
        Pintar $pix $anchoImg $altoImg ($n[0] + 4) ($n[1] - 2) ($n[2] - 9) 2 '#CEBFD8' 0.92
    }
    # Colinas lejanas y cercanas (escalonadas, como bloques)
    $x = 0
    while ($x -lt $anchoImg) { $w = $rnd.Next(4, 9); $h = $rnd.Next(29, 36); Pintar $pix $anchoImg $altoImg $x $h $w ($altoImg - $h) '#5E4B80'; $x += $w }
    $x = 0
    while ($x -lt $anchoImg) { $w = $rnd.Next(4, 9); $h = $rnd.Next(35, 40); Pintar $pix $anchoImg $altoImg $x $h $w ($altoImg - $h) '#4A3C68'; $x += $w }
    # Pasto y tierra
    $sup = New-Object int[] $anchoImg
    $x = 0
    while ($x -lt $anchoImg) {
        $w = $rnd.Next(8, 17); $s = 42 + $rnd.Next(0, 3)
        Pintar $pix $anchoImg $altoImg $x $s $w 1 '#76C04F'
        Pintar $pix $anchoImg $altoImg $x ($s + 1) $w 1 '#529C38'
        Pintar $pix $anchoImg $altoImg $x ($s + 2) $w ($altoImg - $s - 2) '#5A3E2D'
        for ($k = $x; $k -lt [math]::Min($anchoImg, $x + $w); $k++) { $sup[$k] = $s }
        $x += $w
    }
    for ($k = 0; $k -lt 160; $k++) {
        $xx = $rnd.Next(0, $anchoImg); $yy = $rnd.Next(46, $altoImg)
        if ($yy -gt $sup[$xx] + 2) { Pintar $pix $anchoImg $altoImg $xx $yy 1 1 $(if ($rnd.Next(2)) { '#46301F' } else { '#6E4C37' }) }
    }
    # Arboles
    foreach ($ax in 118, 173) {
        $s = $sup[$ax]
        Pintar $pix $anchoImg $altoImg $ax ($s - 9) 2 9 '#5B3B22'
        Pintar $pix $anchoImg $altoImg ($ax - 3) ($s - 15) 8 7 '#3C8A37'
        Pintar $pix $anchoImg $altoImg ($ax - 3) ($s - 15) 8 1 '#55AC4B'
        Pintar $pix $anchoImg $altoImg ($ax - 3) ($s - 9) 8 1 '#2E6E2B'
    }

    $bmp = [System.Windows.Media.Imaging.WriteableBitmap]::new($anchoImg, $altoImg, 96.0, 96.0, [System.Windows.Media.PixelFormats]::Bgra32, $null)
    $bmp.WritePixels([System.Windows.Int32Rect]::new(0, 0, $anchoImg, $altoImg), $pix, $anchoImg * 4, 0)
    return $bmp
}

# Icono cuadrado tipo bloque para cada fila (el color sale del nombre del archivo)
$paletaIconos = @(
    @('#3D7BD9', '#7FB2F0'), @('#3E9A3A', '#8BD86A'), @('#8A4FD0', '#C38BF0'),
    @('#2A9D9A', '#6FD6CF'), @('#D9822B', '#F5B567'), @('#C94C8A', '#F08DBE')
)
function Nuevo-Icono([string]$nombre, [string]$tipo) {
    $par = switch ($tipo) {
        'respaldo' { @('#C8901E', '#F5CF5A') }
        'borrado'  { @('#C8901E', '#F5CF5A') }
        'error'    { @('#B83B3B', '#F28B82') }
        'info'     { @('#454C59', '#6B7383') }
        default {
            $suma = 0; foreach ($ch in $nombre.ToCharArray()) { $suma += [int]$ch }
            $paletaIconos[$suma % $paletaIconos.Count]
        }
    }
    $borde = New-Object System.Windows.Controls.Border
    $borde.Width = 26; $borde.Height = 26
    $borde.CornerRadius = New-Object System.Windows.CornerRadius(5)
    $borde.Background = Color $par[1]
    $borde.BorderBrush = Color $par[0]
    $borde.BorderThickness = New-Object System.Windows.Thickness(2)
    $borde.HorizontalAlignment = 'Left'
    $lienzo = New-Object System.Windows.Controls.Canvas
    $r1 = New-Object System.Windows.Shapes.Rectangle
    $r1.Width = 9; $r1.Height = 10; $r1.Fill = Color $par[0]
    [System.Windows.Controls.Canvas]::SetLeft($r1, 2); [System.Windows.Controls.Canvas]::SetTop($r1, 2)
    $r2 = New-Object System.Windows.Shapes.Rectangle
    $r2.Width = 4; $r2.Height = 4; $r2.Fill = Color '#E6FFFFFF'
    [System.Windows.Controls.Canvas]::SetLeft($r2, 3); [System.Windows.Controls.Canvas]::SetTop($r2, 3)
    [void]$lienzo.Children.Add($r1); [void]$lienzo.Children.Add($r2)
    $borde.Child = $lienzo
    return $borde
}

# Etiqueta de estado de cada fila: texto, color de letra, color de fondo
$etiquetas = @{
    nuevo    = @('Listo', '#7CD957', '#1E3A1B')
    ya       = @('Ya estaba', '#9AA3AF', '#262B33')
    respaldo = @('Respaldo', '#F2C14E', '#3A3018')
    borrado  = @('Borrado', '#F2C14E', '#3A3018')
    omitido  = @('Omitido', '#F59E42', '#3A2716')
    error    = @('Error', '#F87171', '#3A1C1C')
}

# ---------------------------------------------------------------------
# 4) LOGICA DE LA VENTANA
# ---------------------------------------------------------------------
function Formato([double]$b) {
    if ($b -ge 1GB) { '{0:0.00} GB' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { '{0:0.0} MB' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { '{0:0} KB' -f ($b / 1KB) }
    else { '{0:0} B' -f $b }
}
# "184 / 297 MB": ambos numeros en la unidad del total
function Par-Bytes([double]$hecho, [double]$total) {
    $u = 'B'; $d = 1.0
    if ($total -ge 1GB) { $u = 'GB'; $d = 1GB } elseif ($total -ge 1MB) { $u = 'MB'; $d = 1MB } elseif ($total -ge 1KB) { $u = 'KB'; $d = 1KB }
    $fmt = { param($v) if ($v -ge 100 -or $u -eq 'B' -or $u -eq 'KB') { '{0:0}' -f $v } else { '{0:0.0}' -f $v } }
    return @((& $fmt ($hecho / $d)), " / $(& $fmt ($total / $d)) $u")
}
function Tiempo([double]$s) {
    if ($s -lt 5) { 'unos segundos' }
    elseif ($s -lt 60) { '~{0:0} s' -f $s }
    elseif ($s -lt 3600) { '~{0} min {1:00} s' -f [math]::Floor($s / 60), [math]::Floor($s % 60) }
    else { '~{0} h {1:00} min' -f [math]::Floor($s / 3600), [math]::Floor(($s % 3600) / 60) }
}
function Espaciado([string]$s) { return ($s.ToCharArray() -join [char]0x200A) }   # letras separadas

# Estado propio de la ventana (hashtable para poder modificarlo desde los eventos)
$app = @{ Pulso = 0; PS = $null; Final = $true; Listo = $false; VelActiva = $false; VelBytes = [long]0
          VelHora = [DateTime]::Now; Vel = 0.0; UltimoArchivo = ''; ClavePasos = '' }

function Set-Boton([string]$texto) { $c.btnInstalar.Content = New-PixelText $texto 2 '#12260C' }

function Agregar-Fila($texto, $tipo, $tam) {
    $fila = New-Object System.Windows.Controls.Border
    $fila.CornerRadius = New-Object System.Windows.CornerRadius(9)
    $fila.Padding = New-Object System.Windows.Thickness(10, 6, 10, 6)
    $g = New-Object System.Windows.Controls.Grid
    foreach ($ancho in 40, -1, 0, 0) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        if ($ancho -gt 0) { $cd.Width = New-Object System.Windows.GridLength($ancho) }
        elseif ($ancho -lt 0) { $cd.Width = New-Object System.Windows.GridLength(1, 'Star') }
        else { $cd.Width = [System.Windows.GridLength]::Auto }
        [void]$g.ColumnDefinitions.Add($cd)
    }
    $ico = Nuevo-Icono $texto $tipo
    $ico.VerticalAlignment = 'Center'
    [void]$g.Children.Add($ico)

    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $texto; $t.FontSize = 15; $t.VerticalAlignment = 'Center'
    if ($tipo -eq 'info') { $t.Foreground = Color '#9AA3AF'; $t.FontSize = 13.5; $t.TextWrapping = 'Wrap' }
    else { $t.Foreground = Color '#E6E9EE'; $t.FontWeight = 'SemiBold'; $t.TextTrimming = 'CharacterEllipsis' }
    [System.Windows.Controls.Grid]::SetColumn($t, 1)
    [void]$g.Children.Add($t)

    if ($tam) {
        $tt = New-Object System.Windows.Controls.TextBlock
        $tt.Text = Formato $tam; $tt.FontSize = 14.5; $tt.Foreground = Color '#8B93A1'
        $tt.VerticalAlignment = 'Center'; $tt.Margin = New-Object System.Windows.Thickness(12, 0, 14, 0)
        [System.Windows.Controls.Grid]::SetColumn($tt, 2)
        [void]$g.Children.Add($tt)
    }
    if ($etiquetas.ContainsKey($tipo)) {
        $e = $etiquetas[$tipo]
        $b = New-Object System.Windows.Controls.Border
        $b.CornerRadius = New-Object System.Windows.CornerRadius(11)
        $b.Background = Color $e[2]
        $b.Padding = New-Object System.Windows.Thickness(11, 3, 11, 4)
        $b.VerticalAlignment = 'Center'
        if (-not $tam) { $b.Margin = New-Object System.Windows.Thickness(12, 0, 0, 0) }
        $bt = New-Object System.Windows.Controls.TextBlock
        $bt.Text = $e[0]; $bt.FontSize = 13.5; $bt.FontWeight = 'SemiBold'; $bt.Foreground = Color $e[1]
        $b.Child = $bt
        [System.Windows.Controls.Grid]::SetColumn($b, 3)
        [void]$g.Children.Add($b)
    }
    $fila.Child = $g
    $c.panelFilas.Children.Insert(0, $fila)                         # lo mas nuevo arriba
    if ($c.panelFilas.Children.Count -gt 400) { $c.panelFilas.Children.RemoveAt(400) }
}

# Dibuja un paso: 'ok' (check verde), 'activo' (verde con anillo) o 'espera' (gris)
function Pintar-Paso([int]$n, [string]$estado, [string]$sub) {
    $anillo = $c["anillo$n"]; $caja = $c["paso$n"]; $num = $c["num$n"]; $chk = $c["chk$n"]
    switch ($estado) {
        'ok' {
            $anillo.Background = [System.Windows.Media.Brushes]::Transparent
            $caja.Background = Color '#22401F'
            $num.Visibility = 'Collapsed'; $chk.Visibility = 'Visible'
            $c["tit$n"].Foreground = Color '#F3F4F6'
        }
        'activo' {
            $anillo.Background = Color '#2A4526'
            $caja.Background = Color '#7FE05F'
            $num.Foreground = Color '#10220B'; $num.Visibility = 'Visible'; $chk.Visibility = 'Collapsed'
            $c["tit$n"].Foreground = Color '#FFFFFF'
        }
        default {
            $anillo.Background = [System.Windows.Media.Brushes]::Transparent
            $caja.Background = Color '#23272F'
            $num.Foreground = Color '#6B7280'; $num.Visibility = 'Visible'; $chk.Visibility = 'Collapsed'
            $c["tit$n"].Foreground = Color '#C3C8D0'
        }
    }
    $c["sub$n"].Text = $sub
}

function Actualizar-Pasos {
    $p = [int]$sync.Paso
    $e1 = if ($sync.NeoListo) { 'ok' } else { 'activo' }
    $s1 = if ($sync.NeoListo) { 'Instalado' } else { 'En curso...' }
    $e2 = if ($p -ge 3) { 'ok' } elseif ($p -eq 2) { 'activo' } else { 'espera' }
    $s2 = if ($sync.ModsTotal -gt 0) { "$($sync.ModsListos) de $($sync.ModsTotal)" } elseif ($p -eq 2) { 'Revisando...' } else { 'En espera' }
    $e3 = if ($p -ge 4) { 'ok' } elseif ($p -eq 3) { 'activo' } else { 'espera' }
    $s3 = if ($sync.ShadersTotal -gt 0) { "$($sync.ShadersListos) de $($sync.ShadersTotal)" } elseif ($p -ge 4) { 'Sin shaders' } else { 'En espera' }
    $clave = "$e1|$s1|$e2|$s2|$e3|$s3"
    if ($clave -eq $app.ClavePasos) { return }      # nada cambio
    $app.ClavePasos = $clave
    Pintar-Paso 1 $e1 $s1
    Pintar-Paso 2 $e2 $s2
    Pintar-Paso 3 $e3 $s3
    $c.linea1.Background = Color $(if ($e1 -eq 'ok') { '#6CCB52' } else { '#2A2F38' })
    $c.linea2.Background = Color $(if ($e2 -eq 'ok') { '#6CCB52' } else { '#2A2F38' })
}

function Actualizar {
    $c.txtFase.Text = $sync.Fase

    # Filas nuevas de la lista
    $item = $null
    while ($sync.Log.TryDequeue([ref]$item)) { Agregar-Fila $item.Texto $item.Tipo $item.Tam }

    # Barra de progreso general
    $total = [long]$sync.Total; $hecho = [long]$sync.Hecho
    if ($sync.Indeterminado) {
        # Sin total conocido: la barra se llena y vacia en bucle para mostrar que esta trabajando
        $app.Pulso = ($app.Pulso + 3) % 110
        $c.barra.Value = [math]::Min(100, $app.Pulso)
        $c.runPct.Text = ''; $c.runPctSigno.Text = ''
    } else {
        $pct = if ($total -gt 0) { [math]::Min(100.0, $hecho * 100.0 / $total) } else { 100 }
        $c.barra.Value = $pct
        $c.runPct.Text = '{0:0}' -f [math]::Floor($pct); $c.runPctSigno.Text = '%'
    }

    # Velocidad (promedio suavizado) y tiempo restante
    if ($sync.Descargando) {
        $ahora = [DateTime]::Now
        if (-not $app.VelActiva) { $app.VelActiva = $true; $app.VelBytes = $hecho; $app.VelHora = $ahora; $app.Vel = 0.0 }
        $dt = ($ahora - $app.VelHora).TotalSeconds
        if ($dt -ge 0.5) {
            $inst = ($hecho - $app.VelBytes) / $dt
            $app.Vel = if ($app.Vel -le 0) { $inst } else { 0.25 * $inst + 0.75 * $app.Vel }
            $app.VelBytes = $hecho; $app.VelHora = $ahora
        }
        $par = Par-Bytes $hecho $total
        $c.runHecho.Text = $par[0]; $c.runTotal.Text = $par[1]
        if ($app.Vel -gt 0) {
            $v = (Formato $app.Vel).Split(' ')
            $c.runVel.Text = $v[0]; $c.runVelUnidad.Text = " $($v[1])/s"
        } else { $c.runVel.Text = ''; $c.runVelUnidad.Text = 'calculando...' }
        $c.runRestEtiqueta.Text = 'Quedan '
        $c.runRestante.Text = if ($app.Vel -gt 1KB) { Tiempo (($total - $hecho) / $app.Vel) } else { '...' }
    } elseif ($sync.Indeterminado -and -not $app.Final) {
        # Antes de descargar: mostrar que se esta consultando (ej. "Consultando: create")
        $c.runHecho.Text = ''; $c.runTotal.Text = $sync.Actual
    }

    # Archivo que se esta bajando ahora
    if ($sync.Descargando -and $sync.Actual) {
        if ($app.UltimoArchivo -ne $sync.Actual) {
            $app.UltimoArchivo = $sync.Actual
            $c.txtActual.Text = $sync.Actual
            $c.ccIconoActual.Content = Nuevo-Icono $sync.Actual 'nuevo'
        }
        $at = [double]$sync.ArchivoTotal; $ah = [double]$sync.ArchivoHecho
        $c.rellenoArchivo.Width = if ($at -gt 0) { 140.0 * [math]::Min(1.0, $ah / $at) } else { 0 }
        $par = Par-Bytes $ah $at
        $c.txtTamActual.Text = $par[0] + $par[1]
        $c.filaActual.Visibility = 'Visible'
    } else {
        $c.filaActual.Visibility = 'Collapsed'
        $app.UltimoArchivo = ''
    }

    Actualizar-Pasos
    if ($sync.ModsTotal -gt 0 -or $sync.ShadersTotal -gt 0) { Poner-Cantidades $sync.ModsTotal $sync.ShadersTotal }

    if ($sync.Terminado -and -not $app.Final) { Finalizar }
}

function Finalizar {
    $app.Final = $true
    $timer.Stop()
    Actualizar      # vaciar lo que quede en la lista
    $c.filaActual.Visibility = 'Collapsed'
    $c.runRestEtiqueta.Text = ''; $c.runRestante.Text = ''
    $c.runVel.Text = ''; $c.runVelUnidad.Text = ''
    if ([long]$sync.Total -eq 0) {
        # No se descargo nada: limpiar el texto que quedo de "Consultando..."
        $c.runHecho.Text = ''
        $c.runTotal.Text = if ($sync.Error) { '' } else { 'Todo estaba al día, no hubo nada que descargar.' }
    }
    $resumen = "Nuevos: $($sync.Nuevos) · Ya estaban: $($sync.YaEstaban) · Respaldados: $($sync.Quitados)`nOmitidos: $($sync.Omitidos) · Errores: $($sync.Errores)"
    if ($sync.Error) {
        $c.lblEstado.Text = Espaciado 'ERROR'; $c.lblEstado.Foreground = Color '#F87171'
        $c.txtFase.Text = $sync.Error; $c.txtFase.FontSize = 16; $c.txtFase.Foreground = Color '#FCA5A5'
        $c.runPct.Text = ''; $c.runPctSigno.Text = ''
        Set-Boton 'REINTENTAR'; $c.btnInstalar.IsEnabled = $true
        $c.txtPie.Text = $resumen
    } elseif ($sync.Errores -gt 0) {
        $c.lblEstado.Text = Espaciado 'TERMINADO CON ERRORES'; $c.lblEstado.Foreground = Color '#F59E42'
        $c.txtFase.Text = 'Algunos archivos fallaron. Vuelve a intentar.'; $c.txtFase.FontSize = 18
        Set-Boton 'REINTENTAR'; $c.btnInstalar.IsEnabled = $true
        $c.txtPie.Text = $resumen
    } else {
        $sync.Paso = 4; $sync.NeoListo = $true; Actualizar-Pasos
        $c.lblEstado.Text = Espaciado 'TERMINADO'; $c.lblEstado.Foreground = Color '#7CD957'
        $c.txtFase.Text = '¡Listo! Abre el launcher y elige el perfil "NeoForge".'; $c.txtFase.FontSize = 18
        $c.barra.Value = 100; $c.runPct.Text = '100'; $c.runPctSigno.Text = '%'
        Set-Boton '¡A JUGAR!'; $c.btnInstalar.IsEnabled = $true
        $c.btnInstalar.ToolTip = 'Cierra el instalador'
        $c.btnCerrar.Visibility = 'Collapsed'
        $app.Listo = $true
        $c.txtPie.Text = $resumen
    }
    $c.btnCerrar.Content = 'Cerrar'; $c.btnCerrar.IsEnabled = $true
    if ($app.PS) { $app.PS.Runspace.Close(); $app.PS.Dispose(); $app.PS = $null }
}

# ---------------------------------------------------------------------
# Preguntas antes de instalar (se hacen en la ventana, no en el hilo)
# ---------------------------------------------------------------------
$mcDirUI = Join-Path $env:APPDATA '.minecraft'

# Carpetas donde Xaero's Minimap / World Map guardan el mapa de cada servidor
function Carpetas-Mapa {
    $bases = 'xaero\minimap', 'xaero\world-map', 'XaeroWaypoints', 'XaeroWorldMap'
    @(foreach ($b in $bases) {
        $ruta = Join-Path $mcDirUI $b
        if (Test-Path -LiteralPath $ruta) { Get-ChildItem -LiteralPath $ruta -Directory -Filter 'Multiplayer_*' }
    })
}

# Si Minecraft esta abierto, Xaero vuelve a guardar el mapa al cerrarlo
function Minecraft-Abierto {
    try {
        $p = @(Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" |
               Where-Object { $_.CommandLine -match 'minecraft' })
        return $p.Count -gt 0
    } catch { return $false }
}

# Seed del mundo del servidor: Diego la publica en el Gist (mundo.json). El instalador
# guarda la ultima que vio; si cambia, Diego reinicio el mundo y el minimapa viejo ya no sirve.
$archivoSeedUI = Join-Path $mcDirUI 'config\.seed-servidor-diego.txt'
function Leer-SeedServidor {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $archivoUrl = Join-Path $carpeta 'url-lista.txt'
        if (-not (Test-Path -LiteralPath $archivoUrl)) { return $null }
        $url = ((Get-Content -LiteralPath $archivoUrl -Raw).Trim() -replace 'mods\.json$', 'mundo.json') + '?t=' + [DateTime]::UtcNow.Ticks
        $r = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 8 -Headers @{ 'User-Agent' = 'minecraft-setup' }
        $s = ($r.Content | ConvertFrom-Json).seed
        if ($s) { return [string]$s }
    } catch { }
    return $null
}
function Seed-Anterior {
    if (Test-Path -LiteralPath $archivoSeedUI) { return (Get-Content -LiteralPath $archivoSeedUI -Raw).Trim() }
    return ''
}
function Guardar-Seed($s) {
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $archivoSeedUI) | Out-Null
        Set-Content -LiteralPath $archivoSeedUI -Value $s -Encoding ASCII
    } catch { }
}

function Preguntar($texto) {
    $r = [System.Windows.MessageBox]::Show($ventana, $texto, 'Instalador', 'YesNo', 'Question')
    return $r -eq 'Yes'
}

function Hacer-Preguntas {
    # 1) Minimapa: solo se ofrece borrarlo si cambio la seed del servidor.
    #    Si no se pudo saber la seed (sin internet o Gist sin mundo.json), no se pregunta.
    $seed = Leer-SeedServidor
    $guardarSeed = [bool]$seed
    $mapa = Carpetas-Mapa
    if ($seed -and $mapa.Count -gt 0 -and $seed -ne (Seed-Anterior)) {
        $nombres = @($mapa | ForEach-Object { $_.Name -replace '^Multiplayer_', '' } | Sort-Object -Unique)
        $lista = ($nombres | Select-Object -First 6 | ForEach-Object { "   - $_" }) -join "`n"
        if ($nombres.Count -gt 6) { $lista += "`n   ... y $($nombres.Count - 6) más" }
        $si = Preguntar ("Diego reinició el mundo del servidor.`n`n" +
            "¿Quieres borrar los datos del minimapa?`n`n" +
            "Se borra el mapa explorado y los waypoints de estos servidores:`n$lista`n`n" +
            'Si no lo borras, te seguirá saliendo el mapa del mundo anterior.')
        if ($si) {
            if (Minecraft-Abierto) {
                [System.Windows.MessageBox]::Show($ventana,
                    "Minecraft está abierto, así que no se borrará el minimapa.`n`nCierra el juego y vuelve a abrir el instalador.",
                    'Instalador', 'OK', 'Warning') | Out-Null
                $guardarSeed = $false   # que vuelva a preguntar la proxima vez
            } else {
                $sync.MapaBorrar = @($mapa | ForEach-Object { $_.FullName })
            }
        }
    }
    if ($guardarSeed) { Guardar-Seed $seed }

    # 2) Carpetas de respaldo de mods
    $resp = @(Get-ChildItem -LiteralPath $mcDirUI -Directory -Filter 'mods-respaldo-*' -ErrorAction SilentlyContinue)
    if ($resp.Count -gt 0) {
        $bytes = (Get-ChildItem -LiteralPath $resp.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $sync.BorrarRespaldo = Preguntar ("¿Quieres borrar las carpetas de respaldo de mods?`n`n" +
            "Hay $($resp.Count) carpeta(s) mods-respaldo en .minecraft ($(Formato $bytes)).`n" +
            'Ahí quedan los mods viejos o que no son del servidor. Si dices que sí, ' +
            'también se borrarán los que se quiten en esta instalación.')
    }
}

function Iniciar {
    Reiniciar-Estado
    if (-not $Demo) { Hacer-Preguntas }
    $c.panelFilas.Children.Clear()
    $c.lblEstado.Text = Espaciado 'INSTALANDO'; $c.lblEstado.Foreground = Color '#8B93A1'
    $c.txtFase.Foreground = Color '#FFFFFF'; $c.txtFase.FontSize = 22
    $c.runHecho.Text = '—'; $c.runTotal.Text = ''; $c.runVel.Text = ''; $c.runVelUnidad.Text = ''
    $c.runRestEtiqueta.Text = ''; $c.runRestante.Text = ''
    $c.barra.Value = 0
    $c.txtPie.Text = "Solo se descarga lo que falta.`nTus mods anteriores quedan respaldados."
    Set-Boton 'INSTALANDO...'
    $c.btnInstalar.IsEnabled = $false
    $c.btnCerrar.Content = 'Cancelar'; $c.btnCerrar.Visibility = 'Visible'
    $app.Final = $false; $app.VelActiva = $false; $app.ClavePasos = ''; $app.UltimoArchivo = ''

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('carpeta', $carpeta)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $codigo = if ($Demo) { $trabajoDemo } else { $trabajo }
    [void]$ps.AddScript($codigo.ToString())
    [void]$ps.BeginInvoke()
    $app.PS = $ps
    $timer.Start()
}

# Chip "48 mods · 2 shaders" (en singular si es 1)
function Poner-Cantidades([int]$m, [int]$s) {
    $c.runCantMods.Text = [string]$m
    $c.runModsTxt.Text = if ($m -eq 1) { ' mod · ' } else { ' mods · ' }
    $c.runCantShaders.Text = [string]$s
    $c.runShadersTxt.Text = if ($s -eq 1) { ' shader' } else { ' shaders' }
}

function Trabajando { return (-not $app.Final) }

# Datos para los chips antes de instalar (de la copia local de mods.json, sin internet)
function Resumen-Lista {
    $r = @{ Mc = '1.21.1'; Mods = 0; Shaders = 0 }
    try {
        $d = Get-Content -LiteralPath (Join-Path $carpeta 'mods.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $contar = {
            param($x)
            if ($null -eq $x) { return 0 }
            if ($x -is [System.Array]) { return $x.Count }
            $n = 0; foreach ($p in $x.PSObject.Properties) { $n += @($p.Value).Count }; return $n
        }
        if ($d.mc) { $r.Mc = [string]$d.mc }
        $r.Mods = (& $contar $d.modsAmbos) + (& $contar $d.modsSoloCliente)
        $r.Shaders = & $contar $d.shaders
    } catch { }
    return $r
}

# ---------------------------------------------------------------------
# Arranque
# ---------------------------------------------------------------------
try {
    $ventana = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $ico = Join-Path $carpeta 'icono.ico'
    if (Test-Path $ico) { $ventana.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($ico)) }
    $c = @{}
    foreach ($n in 'raiz', 'cabecera', 'imgCabecera', 'btnMin', 'btnMax', 'btnX', 'ccTitulo', 'ccSplash',
                   'runMc', 'runNeo', 'runCantMods', 'runCantShaders', 'runModsTxt', 'runShadersTxt', 'lblEstado', 'txtFase', 'runPct', 'runPctSigno',
                   'barra', 'runHecho', 'runTotal', 'runVel', 'runVelUnidad', 'runRestEtiqueta', 'runRestante',
                   'anillo1', 'paso1', 'num1', 'chk1', 'tit1', 'sub1', 'linea1',
                   'anillo2', 'paso2', 'num2', 'chk2', 'tit2', 'sub2', 'linea2',
                   'anillo3', 'paso3', 'num3', 'chk3', 'tit3', 'sub3',
                   'filaActual', 'ccIconoActual', 'txtActual', 'rellenoArchivo', 'txtTamActual',
                   'panelFilas', 'txtPie', 'btnCerrar', 'btnInstalar') {
        $c[$n] = $ventana.FindName($n)
    }

    # Cabecera y titulo pixelados
    $c.imgCabecera.Source = Escena-Cabecera
    $c.ccTitulo.Content = New-PixelText 'LOS VARCHAR2' 5 '#FFFFFF' '#2A2436' 2

    # Frase amarilla al azar (como en la pantalla de titulo); clic para cambiarla
    $frases = @(
        '¡Sin lag (mentira)!', '¡100% libre de Herobrine!', '¡No caves hacia abajo!',
        '¡Ssssss... BOOM!', '¡Cuidado con la lava!', '¡Trae tu propio pico!',
        '¡Los aldeanos cobran caro!', '¡Más mods que sentido común!', '¡Ahora con más creepers!',
        '¡No mires al Enderman!', '¡Huele a pepino!', '¡Mods a la chilena!',
        '¡SELECT * FROM diversión!', '¡ORA-01403: no data found!', '¡Hecho con COMMIT!'
    )
    $rnd = New-Object System.Random
    $splash = @{ Texto = $frases[$rnd.Next($frases.Count)] }
    $ponerSplash = { $c.ccSplash.Content = New-PixelText (Partir $splash.Texto 13) 2 '#FFE24A' '#3F3A10' }
    & $ponerSplash
    $c.ccSplash.Add_MouseLeftButtonUp({
        $nueva = $splash.Texto
        while ($nueva -eq $splash.Texto) { $nueva = $frases[$rnd.Next($frases.Count)] }
        $splash.Texto = $nueva
        & $ponerSplash
    })

    # Chips
    $res = Resumen-Lista
    $c.runMc.Text = $res.Mc
    $c.runNeo.Text = $res.Mc -replace '^1\.', ''        # Minecraft 1.21.1 -> NeoForge 21.1
    Poner-Cantidades $res.Mods $res.Shaders

    # Estado inicial
    $c.lblEstado.Text = Espaciado 'LISTO PARA INSTALAR'
    $c.txtFase.Text = 'Presiona Instalar para empezar'
    $c.runPct.Text = '0'
    $c.runHecho.Text = '—'
    Pintar-Paso 1 'espera' 'Pendiente'
    Pintar-Paso 2 'espera' "$($res.Mods) en la lista"
    Pintar-Paso 3 'espera' "$($res.Shaders) en la lista"
    $c.linea1.Background = Color '#2A2F38'; $c.linea2.Background = Color '#2A2F38'
    $c.txtPie.Text = "Solo se descarga lo que falta.`nTus mods anteriores quedan respaldados."
    Set-Boton 'INSTALAR'
    if ($Demo) { $ventana.Title += ' (demo)' }

    Agregar-Fila 'Si Diego reinició el mundo, te preguntará si quieres borrar el minimapa.' 'info'
    Agregar-Fila 'Si tienes otros mods, se mueven a .minecraft\mods-respaldo-fecha.' 'info'
    Agregar-Fila 'Presiona INSTALAR para instalar NeoForge, los mods y los shaders.' 'info'

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $timer.Add_Tick({ Actualizar })

    # Barra de titulo propia
    $c.btnMin.Add_Click({ $ventana.WindowState = 'Minimized' })
    $c.btnMax.Add_Click({ $ventana.WindowState = if ($ventana.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
    $c.btnX.Add_Click({ $ventana.Close() })
    # Maximizada, Windows corre la ventana unos pixeles fuera de la pantalla: se compensa
    $ventana.Add_StateChanged({
        $m = if ($ventana.WindowState -eq 'Maximized') { 7 } else { 0 }
        $c.raiz.Margin = New-Object System.Windows.Thickness($m)
    })
    # Arrastrar la ventana desde cualquier parte de la cabecera
    $c.cabecera.Add_MouseLeftButtonDown({
        if (-not $c.ccSplash.IsMouseOver) { try { $ventana.DragMove() } catch { } }
    })

    $c.btnInstalar.Add_Click({ if ($app.Listo) { $ventana.Close() } else { Iniciar } })
    $c.btnCerrar.Add_Click({
        if (Trabajando) {
            $sync.Cancelar = $true
            $sync.Fase = 'Cancelando...'
            $c.btnCerrar.IsEnabled = $false
        } else {
            $ventana.Close()
        }
    })
    $ventana.Add_Closing({ if (Trabajando) { $sync.Cancelar = $true } })

    [void]$ventana.ShowDialog()
} catch {
    [System.Windows.MessageBox]::Show(
        "No se pudo abrir el instalador:`n`n$($_.Exception.Message)`n`nUsa archivos\instalar-modo-texto.bat.",
        'Instalador', 'OK', 'Error') | Out-Null
}
