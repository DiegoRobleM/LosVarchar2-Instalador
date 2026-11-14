param([switch]$YaActualizado)   # ya no se usa; se acepta para que los instaladores antiguos no fallen al reabrirse
$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{ 'User-Agent' = 'minecraft-client-setup/2.0' }
$mcDir = Join-Path $env:APPDATA '.minecraft'
$mods = Join-Path $mcDir 'mods'
$tmp = Join-Path $env:TEMP 'neoforge-client-setup'
New-Item -ItemType Directory -Force -Path $mods, $tmp | Out-Null
$actualizarLista = $true   # bajar la lista de mods mas reciente desde internet
. (Join-Path $PSScriptRoot 'mods-lista.ps1')
Write-Host "Lista de mods: $origenLista" -ForegroundColor Cyan
if ($origenConfigs) { Write-Host "Configuraciones: $origenConfigs" -ForegroundColor Cyan }

if (-not (Test-Path (Join-Path $mcDir 'launcher_profiles.json'))) {
    Write-Host 'No encontre el launcher de Minecraft configurado. Abrelo una vez, inicia sesion, cierralo y vuelve a ejecutar esto.' -ForegroundColor Red
    exit 1
}
if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    Write-Host 'No se encontro Java. Instala Java 21 o superior desde https://adoptium.net y vuelve a ejecutar.' -ForegroundColor Red
    exit 1
}

# 0) Preguntas: minimapa y carpetas de respaldo de mods
function Preguntar($texto) {
    $r = Read-Host "$texto (s/n)"
    return $r -match '^\s*s'
}
$mapa = @(foreach ($b in 'xaero\minimap', 'xaero\world-map', 'XaeroWaypoints', 'XaeroWorldMap') {
    $ruta = Join-Path $mcDir $b
    if (Test-Path -LiteralPath $ruta) { Get-ChildItem -LiteralPath $ruta -Directory -Filter 'Multiplayer_*' }
})
# Solo se ofrece borrar el minimapa si cambio la seed del mundo del servidor (Diego lo
# reinicio). La seed viene del Gist (mundo.json); la ultima vista se guarda en
# config\.seed-servidor-diego.txt. Si no se pudo saber la seed, no se pregunta.
$archivoSeed = Join-Path $mcDir 'config\.seed-servidor-diego.txt'
$seed = $null
try {
    $urlSeed = ((Get-Content (Join-Path $PSScriptRoot 'url-lista.txt') -Raw).Trim() -replace 'mods\.json$', 'mundo.json') + '?t=' + [DateTime]::UtcNow.Ticks
    $seed = ((Invoke-WebRequest $urlSeed -UseBasicParsing -TimeoutSec 8 -Headers @{ 'User-Agent' = 'minecraft-setup' }).Content | ConvertFrom-Json).seed
    if ($seed) { $seed = [string]$seed }
} catch { $seed = $null }
$seedAnterior = if (Test-Path -LiteralPath $archivoSeed) { (Get-Content -LiteralPath $archivoSeed -Raw).Trim() } else { '' }
$guardarSeed = [bool]$seed
if ($seed -and $mapa.Count -gt 0 -and $seed -ne $seedAnterior) {
    Write-Host 'Diego reinicio el mundo del servidor.' -ForegroundColor Cyan
    Write-Host 'Datos del minimapa (Xaero) encontrados para estos servidores:'
    $mapa | ForEach-Object { $_.Name -replace '^Multiplayer_', '' } | Sort-Object -Unique | ForEach-Object { Write-Host "   - $_" }
    if (Preguntar 'Borrar el mapa explorado y los waypoints? (si no, te seguira saliendo el mapa del mundo anterior)') {
        $abierto = @(Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" -ErrorAction SilentlyContinue |
                     Where-Object { $_.CommandLine -match 'minecraft' }).Count -gt 0
        if ($abierto) {
            Write-Host 'Minecraft esta abierto: no se borra el minimapa. Cierra el juego y vuelve a ejecutar.' -ForegroundColor Yellow
            $guardarSeed = $false   # que vuelva a preguntar la proxima vez
        } else {
            foreach ($d in $mapa) {
                Remove-Item -LiteralPath $d.FullName -Recurse -Force
                Write-Host "  [borrado] minimapa: $($d.Name)" -ForegroundColor Yellow
            }
        }
    }
}
if ($guardarSeed) {
    New-Item -ItemType Directory -Force -Path (Split-Path $archivoSeed) | Out-Null
    Set-Content -LiteralPath $archivoSeed -Value $seed -Encoding ASCII
}
$borrarRespaldo = $false
$respViejos = @(Get-ChildItem -LiteralPath $mcDir -Directory -Filter 'mods-respaldo-*' -ErrorAction SilentlyContinue)
if ($respViejos.Count -gt 0) {
    Write-Host "Hay $($respViejos.Count) carpeta(s) mods-respaldo en .minecraft (mods viejos o que no son del servidor)."
    $borrarRespaldo = Preguntar 'Borrarlas? (tambien se borraran los mods que se quiten ahora)'
}
Write-Host ''

# 1) Instalar NeoForge (perfil en el launcher), solo si esa version no esta instalada
$nf = Get-NeoForgeVersion
if (Test-Path (Join-Path $mcDir "versions\neoforge-$nf")) {
    Write-Host "NeoForge $nf ya esta instalado."
} else {
    $jar = Join-Path $tmp "neoforge-$nf-installer.jar"
    Write-Host "Descargando instalador de NeoForge $nf..."
    Invoke-WebRequest "https://maven.neoforged.net/releases/net/neoforged/neoforge/$nf/neoforge-$nf-installer.jar" -OutFile $jar -Headers $headers
    Write-Host "Instalando NeoForge para Minecraft $mc..."
    Push-Location $tmp   # el instalador deja un .log en la carpeta actual
    & java -jar $jar --installClient $mcDir
    Pop-Location
    if ($LASTEXITCODE -ne 0) { Write-Host 'Fallo el instalador de NeoForge.' -ForegroundColor Red; exit 1 }
}

# 2) Sincronizar mods (lista en mods-lista.ps1)
#    Descarga solo los que faltan. Los que no estan en la lista (otros mods tuyos o
#    versiones antiguas) se mueven a .minecraft\mods-respaldo-<fecha>, no se borran.
Write-Host 'Sincronizando mods...'
$resp = Join-Path $mcDir ('mods-respaldo-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
Sync-Mods ($modsAmbos + $modsSoloCliente) $mods $resp
if ($borrarRespaldo) {
    Get-ChildItem -LiteralPath $mcDir -Directory -Filter 'mods-respaldo-*' | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
        Write-Host "  [borrado] $($_.Name)" -ForegroundColor Yellow
    }
}

# 3) Shader packs (se guardan en .minecraft\shaderpacks; activalos en Opciones > Shaders)
$shadersDir = Join-Path $mcDir 'shaderpacks'
New-Item -ItemType Directory -Force -Path $shadersDir | Out-Null
foreach ($s in $shaders) { Install-Shader $s $shadersDir }

# 4) Configuraciones de Diego (archivos\configs -> .minecraft\config)
#    Se copian solo la primera vez; despues se respetan los cambios del jugador.
#    Los ya entregados se anotan en config\.configs-de-diego.txt
$origenCfg = Join-Path $PSScriptRoot 'configs'
if (Test-Path -LiteralPath $origenCfg) {
    $cfgDir = Join-Path $mcDir 'config'
    $marca  = Join-Path $cfgDir '.configs-de-diego.txt'
    $entregados = @()
    if (Test-Path -LiteralPath $marca) { $entregados = @(Get-Content -LiteralPath $marca) }
    foreach ($f in @(Get-ChildItem -LiteralPath $origenCfg -File -Recurse)) {
        $rel = $f.FullName.Substring($origenCfg.Length + 1)
        $dest = Join-Path $cfgDir $rel
        if ((Test-Path -LiteralPath $dest) -and ($entregados -contains $rel)) {
            Write-Host "  [ya esta] config\$rel" -ForegroundColor DarkGray
            continue
        }
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        if (Test-Path -LiteralPath $dest) { Copy-Item -LiteralPath $dest ($dest + '.respaldo') -Force }
        Copy-Item -LiteralPath $f.FullName $dest -Force
        if ($entregados -notcontains $rel) { Add-Content -LiteralPath $marca -Value $rel }
        Write-Host "  [nuevo] config\$rel" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Listo. Abre el launcher de Minecraft, elige el perfil "NeoForge" y juega.' -ForegroundColor Green
