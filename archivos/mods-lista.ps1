# Funciones compartidas por los instaladores (servidor y amigos).
# La LISTA de mods ya no esta aqui: esta en mods.json (solo datos, sin codigo).
#
# Quien carga este archivo puede definir ANTES:
#   $actualizarLista = $true   -> intenta bajar la lista publicada en internet (url-lista.txt)
#                                 y, si lo logra, reemplaza la copia local de mods.json.
#   $carpetaLista    = 'ruta'  -> carpeta con mods.json y url-lista.txt (por defecto, la de este archivo).
# Despues de cargarlo quedan definidas: $mc, $modsAmbos, $modsSoloServidor, $modsSoloCliente,
# $shaders y $origenLista (de donde salio la lista, para mostrarlo).

$dirLista     = if ($carpetaLista) { $carpetaLista } else { $PSScriptRoot }
$archivoLista = Join-Path $dirLista 'mods.json'
$origenLista  = 'copia local'

if ($actualizarLista) {
    $archivoUrl = Join-Path $dirLista 'url-lista.txt'
    if (Test-Path $archivoUrl) {
        try {
            # ?t=... evita que se use una copia vieja guardada en cache
            $url = (Get-Content $archivoUrl -Raw).Trim() + '?t=' + [DateTime]::UtcNow.Ticks
            $texto = (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 15 -Headers @{ 'User-Agent' = 'minecraft-setup' }).Content
            $prueba = $texto | ConvertFrom-Json            # si no es JSON valido, salta al catch
            if (-not $prueba.modsAmbos) { throw 'La lista descargada no tiene modsAmbos' }
            [IO.File]::WriteAllText($archivoLista, $texto, (New-Object Text.UTF8Encoding $false))
            $origenLista = 'internet (lista mas reciente)'
        } catch {
            $origenLista = 'copia local (no se pudo descargar la lista nueva)'
        }

        # Configuraciones de Diego: configs.json esta en el mismo Gist que mods.json.
        # Formato: { "carpeta/archivo.json": "contenido del archivo", ... }
        # Si se descarga bien, reemplaza la carpeta local "configs" (la que copian los instaladores).
        $origenConfigs = 'copia local'
        try {
            $urlCfg = (Get-Content $archivoUrl -Raw).Trim() -replace 'mods\.json$', 'configs.json'
            $urlCfg += '?t=' + [DateTime]::UtcNow.Ticks
            $textoCfg = (Invoke-WebRequest $urlCfg -UseBasicParsing -TimeoutSec 15 -Headers @{ 'User-Agent' = 'minecraft-setup' }).Content
            $datosCfg = $textoCfg | ConvertFrom-Json
            $dirCfg = Join-Path $dirLista 'configs'
            $archivosCfg = @($datosCfg.PSObject.Properties)
            foreach ($p in $archivosCfg) {
                if ($p.Name -match '\.\.' -or $p.Name -match '^[\\/]' -or $p.Name -match ':') { throw "Ruta no permitida: $($p.Name)" }
            }
            if (Test-Path -LiteralPath $dirCfg) { Remove-Item -LiteralPath $dirCfg -Recurse -Force }
            foreach ($p in $archivosCfg) {
                $destCfg = Join-Path $dirCfg ($p.Name -replace '/', '\')
                New-Item -ItemType Directory -Force -Path (Split-Path $destCfg) | Out-Null
                [IO.File]::WriteAllText($destCfg, [string]$p.Value, (New-Object Text.UTF8Encoding $false))
            }
            $origenConfigs = 'internet'
        } catch {
            $origenConfigs = 'copia local (no se pudo descargar configs.json)'
        }
    }
}

# modsAmbos viene agrupado por categoria: se juntan todas en una sola lista
function Unir-Grupos($x) {
    $r = @()
    if ($null -eq $x) { return ,$r }
    if ($x -is [System.Array]) { return ,@($x) }
    foreach ($p in $x.PSObject.Properties) { $r += @($p.Value) }
    return ,$r
}

$datosLista       = Get-Content -LiteralPath $archivoLista -Raw -Encoding UTF8 | ConvertFrom-Json
$mc               = $datosLista.mc
$modsAmbos        = Unir-Grupos $datosLista.modsAmbos
$modsSoloServidor = Unir-Grupos $datosLista.modsSoloServidor
$modsSoloCliente  = Unir-Grupos $datosLista.modsSoloCliente
$shaders          = Unir-Grupos $datosLista.shaders

function Get-Json($u) {
    $r = Invoke-RestMethod $u -Headers $headers
    $out = @()
    foreach ($i in $r) { $out += $i }
    return ,$out
}

# Version de NeoForge a instalar. Si mods.json trae "neoforge" (la misma del servidor), se usa
# esa: asi los amigos no quedan con una version distinta cuando sale una nueva (paso con 21.1.266
# mientras el servidor seguia en 21.1.265). Solo si no viene, se busca la estable mas reciente.
function Get-NeoForgeVersion {
    if ($datosLista.neoforge) { return [string]$datosLista.neoforge }
    $r =Invoke-RestMethod 'https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge' -Headers $headers
    $cands = @()
    foreach ($v in $r.versions) { if ($v -like '21.1.*' -and $v -notmatch 'alpha|beta') { $cands += $v } }
    $best = $cands[0]
    foreach ($c in $cands) { try { if ([version]$c -gt [version]$best) { $best = $c } } catch {} }
    return $best
}

# Deja el perfil "NeoForge" del launcher apuntando a la version $nf y borra las carpetas
# versions\neoforge-21.1.* que ya no usa ningun perfil (las que dejo una version distinta).
# Devuelve los nombres de las carpetas borradas. Edita el texto con una expresion regular en vez
# de ConvertTo-Json para no cambiar el resto del archivo del launcher.
function Fijar-PerfilNeoForge($mcDir, $nf) {
    $borradas = @()
    $archivoPerfiles = Join-Path $mcDir 'launcher_profiles.json'
    if (-not (Test-Path -LiteralPath $archivoPerfiles)) { return ,$borradas }
    $texto = [IO.File]::ReadAllText($archivoPerfiles)
    $patron = '("NeoForge"\s*:\s*\{[^{}]*?"lastVersionId"\s*:\s*")neoforge-[^"]+(")'
    $nuevo = [regex]::Replace($texto, $patron, ('${1}neoforge-' + $nf + '${2}'))
    if ($nuevo -ne $texto) { [IO.File]::WriteAllText($archivoPerfiles, $nuevo, (New-Object Text.UTF8Encoding $false)) }

    $usadas = @{}
    foreach ($m in [regex]::Matches($nuevo, '"lastVersionId"\s*:\s*"([^"]+)"')) { $usadas[$m.Groups[1].Value] = $true }
    $dirVersiones = Join-Path $mcDir 'versions'
    foreach ($d in @(Get-ChildItem -LiteralPath $dirVersiones -Directory -Filter 'neoforge-21.1.*' -ErrorAction SilentlyContinue)) {
        if ($d.Name -eq "neoforge-$nf" -or $usadas.ContainsKey($d.Name)) { continue }
        try { Remove-Item -LiteralPath $d.FullName -Recurse -Force; $borradas += $d.Name } catch {}
    }
    return ,$borradas
}

# --- Sincronizacion de mods ---
# Install-Mod descarga un mod (y sus dependencias obligatorias) solo si el archivo no existe.
# Sync-Mods instala la lista completa y luego mueve a una carpeta de respaldo los .jar
# que ya no corresponden (mods quitados de la lista o versiones antiguas).
$script:hechos    = @{}   # slugs / ids ya procesados
$script:esperados = @{}   # nombres de archivo que deben quedar en la carpeta
$script:fallos    = 0     # consultas a Modrinth que fallaron

function Install-Mod($slug, $destino) {
    if ($script:hechos.ContainsKey($slug)) { return }
    $script:hechos[$slug] = $true
    try {
        $url = "https://api.modrinth.com/v2/project/$slug/version?game_versions=%5B%22$mc%22%5D&loaders=%5B%22neoforge%22%5D"
        $vers = Get-Json $url
    } catch { $script:fallos++; Write-Host "  [error] $slug (no se pudo consultar Modrinth)" -ForegroundColor Red; return }
    if ($vers.Count -eq 0) { Write-Host "  [omitido] $slug no tiene version NeoForge para $mc" -ForegroundColor Yellow; return }
    $v = $vers[0]
    foreach ($c in $vers) { if ($c.version_type -eq 'release') { $v = $c; break } }
    $f = $v.files[0]
    foreach ($c in $v.files) { if ($c.primary -eq $true) { $f = $c; break } }
    $script:esperados[$f.filename] = $true
    $archivo = Join-Path $destino $f.filename
    if (Test-Path -LiteralPath $archivo) {
        Write-Host "  [ya esta] $slug -> $($f.filename)" -ForegroundColor DarkGray
    } else {
        Write-Host "  [nuevo] $slug -> $($f.filename)" -ForegroundColor Green
        try { Invoke-WebRequest $f.url -OutFile $archivo -Headers $headers }
        catch {
            $script:fallos++
            Remove-Item -LiteralPath $archivo -Force -ErrorAction SilentlyContinue
            Write-Host "  [error] no se pudo descargar $($f.filename)" -ForegroundColor Red
        }
    }
    foreach ($d in $v.dependencies) {
        if ($d.dependency_type -eq 'required' -and $d.project_id) { Install-Mod $d.project_id $destino }
    }
}

function Sync-Mods($slugs, $destino, $respaldo) {
    $script:hechos = @{}; $script:esperados = @{}; $script:fallos = 0
    foreach ($s in $slugs) { Install-Mod $s $destino }

    if ($script:fallos -gt 0) {
        Write-Host ''
        Write-Host "Hubo $($script:fallos) error(es) con Modrinth. No se quita ningun mod para no borrar algo por error." -ForegroundColor Yellow
        Write-Host 'Revisa tu conexion y vuelve a ejecutar.' -ForegroundColor Yellow
        return
    }

    $sobrantes = Get-ChildItem -LiteralPath $destino -Filter *.jar -ErrorAction SilentlyContinue |
                 Where-Object { -not $script:esperados.ContainsKey($_.Name) }
    if ($sobrantes) {
        New-Item -ItemType Directory -Force -Path $respaldo | Out-Null
        foreach ($j in $sobrantes) {
            Move-Item -LiteralPath $j.FullName -Destination $respaldo -Force
            Write-Host "  [quitado] $($j.Name)" -ForegroundColor Yellow
        }
        Write-Host "Mods quitados movidos a: $respaldo" -ForegroundColor Yellow
    }
    $nuevos = $script:esperados.Count
    Write-Host "Mods sincronizados: $nuevos en total." -ForegroundColor Cyan
}

function Install-Shader($slug, $destino) {
    try {
        $vers = Get-Json "https://api.modrinth.com/v2/project/$slug/version?game_versions=%5B%22$mc%22%5D&loaders=%5B%22iris%22%5D"
        if ($vers.Count -eq 0) { $vers = Get-Json "https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22iris%22%5D" }
    } catch { Write-Host "  [error] shader $slug (no se pudo consultar)" -ForegroundColor Red; return }
    if ($vers.Count -eq 0) { Write-Host "  [omitido] shader $slug no tiene version para Iris" -ForegroundColor Yellow; return }
    $v = $vers[0]
    foreach ($c in $vers) { if ($c.version_type -eq 'release') { $v = $c; break } }
    $f = $v.files[0]
    foreach ($c in $v.files) { if ($c.primary -eq $true) { $f = $c; break } }
    $archivo = Join-Path $destino $f.filename
    if (Test-Path -LiteralPath $archivo) { Write-Host "  [ya esta] shader $slug -> $($f.filename)" -ForegroundColor DarkGray; return }
    Write-Host "  [nuevo] shader $slug -> $($f.filename)" -ForegroundColor Green
    Invoke-WebRequest $f.url -OutFile $archivo -Headers $headers
}
