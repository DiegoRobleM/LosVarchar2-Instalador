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
$archivoFijos = Join-Path $dirLista 'mods-fijos.json'   # version exacta de cada mod (ver mas abajo)
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

        # Versiones fijas (mods-fijos.json), en el mismo Gist. Si no se puede bajar, queda la copia local.
        try {
            $urlFijos = (Get-Content $archivoUrl -Raw).Trim() -replace 'mods\.json$', 'mods-fijos.json'
            $urlFijos += '?t=' + [DateTime]::UtcNow.Ticks
            $textoFijos = (Invoke-WebRequest $urlFijos -UseBasicParsing -TimeoutSec 15 -Headers @{ 'User-Agent' = 'minecraft-setup' }).Content
            $pruebaFijos = $textoFijos | ConvertFrom-Json
            if (-not $pruebaFijos.mods) { throw 'mods-fijos.json no tiene mods' }
            [IO.File]::WriteAllText($archivoFijos, $textoFijos, (New-Object Text.UTF8Encoding $false))
        } catch { }

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
# Devuelve los nombres de las carpetas borradas (uno por uno: usar foreach directo). Edita el texto con una expresion regular en vez
# de ConvertTo-Json para no cambiar el resto del archivo del launcher.
function Fijar-PerfilNeoForge($mcDir, $nf) {
    $borradas = @()
    $archivoPerfiles = Join-Path $mcDir 'launcher_profiles.json'
    if (-not (Test-Path -LiteralPath $archivoPerfiles)) { return }
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
    return $borradas
}

# --- Versiones fijas (mods-fijos.json) ---
# mods.json dice QUE mods van; mods-fijos.json dice la VERSION EXACTA de cada uno (y de sus
# dependencias). Asi el servidor y todos los amigos tienen los mismos archivos, y un mod solo
# se actualiza cuando Diego lo decide (panel, tarjeta "Mods: actualizar y probar").
# Antes cada uno bajaba la ultima version de Modrinth en el momento en que instalaba: si un
# mod se actualizaba entremedio, el servidor y los amigos quedaban con versiones distintas.
#
# Formato: { "fecha": "...", "mods": { "<slug>": [ archivo, archivo, ... ] }, "shaders": { ... } }
# Cada slug lleva primero su propio archivo y despues sus dependencias obligatorias.
# Cada archivo: { archivo, url, sha1, tam, proyecto, version }.
$script:cacheModrinth = @{}   # "<loader>|<slug>" -> archivos (no consultar dos veces lo mismo)
$script:fallosFijos   = 0     # consultas a Modrinth o descargas que fallaron

function Loader-DeTipo($tipo) { if ($tipo -eq 'shaders') { return 'iris' } else { return 'neoforge' } }

# Todos los slugs de mods.json de un tipo (mods = ambos + solo servidor + solo cliente)
function Slugs-DeTipo($tipo) {
    if ($tipo -eq 'shaders') { return $shaders }
    return ($modsAmbos + $modsSoloServidor + $modsSoloCliente)
}

# Ultima version (release si hay) de un proyecto en Modrinth, mas sus dependencias obligatorias.
# Devuelve la lista de archivos (el del proyecto primero); vacia si no hay version para $mc.
# Si Modrinth no responde, lanza un error.
function Resolver-Ultima($slug, $loader = 'neoforge', $vistos = $null) {
    if ($null -eq $vistos) { $vistos = @{} }
    $clave = "$loader|$slug"
    if ($script:cacheModrinth.ContainsKey($clave)) { return $script:cacheModrinth[$clave] }
    $vistos[$slug] = $true
    $base = "https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22$loader%22%5D"
    $vers = Get-Json "$base&game_versions=%5B%22$mc%22%5D"
    if ($vers.Count -eq 0 -and $loader -eq 'iris') { $vers = Get-Json $base }   # shaders sin version marcada
    $lista = @()
    if ($vers.Count -gt 0) {
        $v = $vers[0]
        foreach ($c in $vers) { if ($c.version_type -eq 'release') { $v = $c; break } }
        $f = $v.files[0]
        foreach ($c in $v.files) { if ($c.primary -eq $true) { $f = $c; break } }
        $lista += [pscustomobject][ordered]@{
            archivo = [string]$f.filename; url = [string]$f.url; sha1 = [string]$f.hashes.sha1
            tam = [long]$f.size; proyecto = [string]$v.project_id; version = [string]$v.version_number
        }
        $vistos[[string]$v.project_id] = $true
        if ($loader -eq 'neoforge') {
            foreach ($d in $v.dependencies) {
                if ($d.dependency_type -ne 'required' -or -not $d.project_id -or $vistos.ContainsKey($d.project_id)) { continue }
                foreach ($x in @(Resolver-Ultima $d.project_id $loader $vistos)) {
                    if (-not ($lista | Where-Object { $_.archivo -eq $x.archivo })) { $lista += $x }
                }
            }
        }
    }
    $script:cacheModrinth[$clave] = $lista
    return $lista
}

# Lee mods-fijos.json (o el archivo indicado). Si no existe, devuelve una lista vacia.
function Leer-Fijos($ruta = $archivoFijos) {
    $f = @{ fecha = ''; mods = [ordered]@{}; shaders = [ordered]@{} }
    if (-not (Test-Path -LiteralPath $ruta)) { return $f }
    $d = Get-Content -LiteralPath $ruta -Raw -Encoding UTF8 | ConvertFrom-Json
    $f.fecha = [string]$d.fecha
    foreach ($tipo in 'mods', 'shaders') {
        if ($d.$tipo) { foreach ($p in $d.$tipo.PSObject.Properties) { $f[$tipo][$p.Name] = @($p.Value | Where-Object { $_ }) } }
    }
    return $f
}

function Guardar-Fijos($f, $ruta = $archivoFijos) {
    $salida = [ordered]@{
        _nota   = 'Version exacta de cada mod: la usan el servidor y los instaladores. No editar a mano: la completa el servidor al iniciar y se actualiza desde el panel (Mods: actualizar y probar).'
        fecha   = $f.fecha
        mods    = [ordered]@{}
        shaders = [ordered]@{}
    }
    foreach ($tipo in 'mods', 'shaders') {
        foreach ($k in @($f[$tipo].Keys | Sort-Object)) { $salida[$tipo][$k] = @($f[$tipo][$k]) }
    }
    [IO.File]::WriteAllText($ruta, ($salida | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
}

# Deja mods-fijos al dia con mods.json SIN actualizar nada: agrega los mods nuevos de la lista
# (con su ultima version) y saca los que ya no estan. Devuelve cuantos cambios hizo.
function Completar-Fijos($f) {
    $cambios = 0
    foreach ($tipo in 'mods', 'shaders') {
        $lista = @(Slugs-DeTipo $tipo)
        foreach ($s in $lista) {
            if ($f[$tipo].Contains($s)) { continue }
            try {
                $f[$tipo][$s] = @(Resolver-Ultima $s (Loader-DeTipo $tipo))
                $cambios++
                if ($f[$tipo][$s].Count -gt 0) { Write-Host "  [fijado] $s -> $($f[$tipo][$s][0].archivo)" -ForegroundColor Green }
                else { Write-Host "  [omitido] $s no tiene version para $mc" -ForegroundColor Yellow }
            } catch { $script:fallosFijos++; Write-Host "  [error] $s (no se pudo consultar Modrinth)" -ForegroundColor Red }
        }
        foreach ($k in @($f[$tipo].Keys)) {
            if ($lista -notcontains $k) { $f[$tipo].Remove($k); $cambios++; Write-Host "  [fuera de la lista] $k" -ForegroundColor Yellow }
        }
    }
    if ($cambios -gt 0 -and -not $f.fecha) { $f.fecha = Get-Date -Format 'yyyy-MM-dd HH:mm' }
    return $cambios
}

# Archivos (sin repetir) que corresponden a esos slugs segun mods-fijos. Si un slug aun no
# esta fijado (mods.json mas nuevo que mods-fijos), se usa su ultima version, sin guardarla.
function Archivos-Fijos($f, $slugs, $tipo = 'mods') {
    $vistos = @{}
    $r = @()
    foreach ($s in $slugs) {
        $lista = @()
        if ($f[$tipo].Contains($s)) { $lista = @($f[$tipo][$s]) }
        else {
            try { $lista = @(Resolver-Ultima $s (Loader-DeTipo $tipo)) }
            catch { $script:fallosFijos++; Write-Host "  [error] $s (no se pudo consultar Modrinth)" -ForegroundColor Red }
        }
        foreach ($a in $lista) {
            if ($a -and -not $vistos.ContainsKey($a.archivo)) { $vistos[$a.archivo] = $true; $r += $a }
        }
    }
    return $r
}

function Sha1-Archivo($ruta) {
    $sha = [Security.Cryptography.SHA1]::Create()
    $fs = [IO.File]::OpenRead($ruta)
    try { return -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) } finally { $fs.Dispose() }
}

# Deja la carpeta $destino con exactamente esos archivos: baja los que faltan (revisando su
# huella sha1) y mueve a $respaldo los .jar que sobran (mods quitados o versiones viejas).
# Con -SinQuitar no mueve nada (shaders: el jugador puede tener otros).
# Si algo falla no se quita nada, por seguridad. Deja el numero de fallos en $script:fallosSync.
function Sync-Fijos($archivos, $destino, $respaldo, [switch]$SinQuitar) {
    New-Item -ItemType Directory -Force -Path $destino | Out-Null
    $fallos = $script:fallosFijos
    $esperados = @{}
    foreach ($a in $archivos) {
        $esperados[$a.archivo] = $true
        $ruta = Join-Path $destino $a.archivo
        if (Test-Path -LiteralPath $ruta) { Write-Host "  [ya esta] $($a.archivo)" -ForegroundColor DarkGray; continue }
        Write-Host "  [nuevo] $($a.archivo)" -ForegroundColor Green
        $parte = "$ruta.part"
        try {
            Invoke-WebRequest $a.url -OutFile $parte -Headers $headers -UseBasicParsing
            if ($a.sha1 -and (Sha1-Archivo $parte) -ne $a.sha1) { throw 'el archivo bajado no coincide con su huella' }
            Move-Item -LiteralPath $parte -Destination $ruta -Force
        } catch {
            $fallos++
            Remove-Item -LiteralPath $parte -Force -ErrorAction SilentlyContinue
            Write-Host "  [error] $($a.archivo): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    $script:fallosSync = $fallos
    if ($fallos -gt 0) {
        Write-Host ''
        Write-Host "Hubo $fallos error(es). No se quita ningun mod para no borrar algo por error." -ForegroundColor Yellow
        Write-Host 'Revisa tu conexion y vuelve a intentar.' -ForegroundColor Yellow
        return
    }
    if (-not $SinQuitar) {
        $sobrantes = @(Get-ChildItem -LiteralPath $destino -Filter *.jar -ErrorAction SilentlyContinue |
                       Where-Object { -not $esperados.ContainsKey($_.Name) })
        if ($sobrantes.Count -gt 0) {
            New-Item -ItemType Directory -Force -Path $respaldo | Out-Null
            foreach ($j in $sobrantes) {
                Move-Item -LiteralPath $j.FullName -Destination $respaldo -Force
                Write-Host "  [quitado] $($j.Name)" -ForegroundColor Yellow
            }
            Write-Host "Mods quitados movidos a: $respaldo" -ForegroundColor Yellow
        }
    }
    Write-Host "Sincronizados: $($esperados.Count) archivo(s)." -ForegroundColor Cyan
}

# "tipo|proyecto" -> archivo, para comparar dos versiones de mods-fijos
function Mapa-Proyectos($f) {
    $m = @{}
    foreach ($tipo in 'mods', 'shaders') {
        foreach ($k in @($f[$tipo].Keys)) { foreach ($a in @($f[$tipo][$k])) { if ($a) { $m["$tipo|$($a.proyecto)"] = $a.archivo } } }
    }
    return $m
}

# Busca la ultima version de TODO en Modrinth y la compara con mods-fijos. No cambia nada:
# devuelve la propuesta (fijos nuevos) y la lista de cambios. Si un mod no se pudo consultar,
# se deja como estaba.
function Buscar-Actualizaciones($f) {
    $script:cacheModrinth = @{}
    $script:fallosFijos = 0
    $nuevo = @{ fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm'); mods = [ordered]@{}; shaders = [ordered]@{} }
    foreach ($tipo in 'mods', 'shaders') {
        foreach ($s in @(Slugs-DeTipo $tipo)) {
            try { $nuevo[$tipo][$s] = @(Resolver-Ultima $s (Loader-DeTipo $tipo)) }
            catch {
                $script:fallosFijos++
                Write-Host "  [error] $s (no se pudo consultar Modrinth)" -ForegroundColor Red
                if ($f[$tipo].Contains($s)) { $nuevo[$tipo][$s] = $f[$tipo][$s] }
            }
        }
    }
    $antes = Mapa-Proyectos $f
    $despues = Mapa-Proyectos $nuevo
    $cambios = @()
    foreach ($p in @($despues.Keys | Sort-Object { $despues[$_] })) {
        if (-not $antes.ContainsKey($p)) { $cambios += [pscustomobject]@{ tipo = 'nuevo'; antes = ''; despues = $despues[$p] } }
        elseif ($antes[$p] -ne $despues[$p]) { $cambios += [pscustomobject]@{ tipo = 'actualizado'; antes = $antes[$p]; despues = $despues[$p] } }
    }
    foreach ($p in @($antes.Keys | Sort-Object { $antes[$_] })) {
        if (-not $despues.ContainsKey($p)) { $cambios += [pscustomobject]@{ tipo = 'quitado'; antes = $antes[$p]; despues = '' } }
    }
    return [pscustomobject]@{ fijos = $nuevo; cambios = $cambios; fallos = $script:fallosFijos }
}
