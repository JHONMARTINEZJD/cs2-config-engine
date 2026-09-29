#Requires -Version 7.0
<#
.SYNOPSIS
    CS2 Configuration Snapshot Engine - backup completo, reproducible y
    sincronizado de la configuracion viva de Counter-Strike 2.
.DESCRIPTION
    Orquesta el flujo completo:
        descubrimiento -> parseo -> clasificacion -> sincronizacion ->
        validacion -> snapshot -> exportacion -> reportes.

    Fuente de la verdad: SIEMPRE la configuracion viva del usuario.
    Los fallbacks solo se aplican a variables ausentes. Nada se descarta.
.PARAMETER SteamPath
    Ruta a la instalacion de Steam (opcional; autodetectada si se omite).
.PARAMETER SteamId
    SteamID concreto a respaldar (opcional; autodetecta el perfil activo).
.PARAMETER OutputPath
    Carpeta de salida. Por defecto ./output junto al script.
.PARAMETER MaxHistory
    Numero de snapshots a conservar. Por defecto 10.
.PARAMETER Formats
    Formatos de exportacion. Por defecto: autoexec, json, markdown, yaml, csv.
.PARAMETER LogLevel
    Debug | Info | Warn | Error. Por defecto Info.
.PARAMETER Restore
    Id de snapshot a restaurar (o 'latest'). Presente => el motor NO hace backup:
    entra en modo restore. Por defecto SOLO MUESTRA lo que cambiaria.
.PARAMETER Apply
    Escribe de verdad. Sin este parametro, -Restore es solo-mostrar.
.PARAMETER RestoreTarget
    Output (por defecto) escribe en <OutputPath>/restore/<id>/files y no toca
    nada del jugador. LiveFiles sobreescribe sus .vcfg/.cfg y exige ademas
    -AllowLiveFileWrites.
.PARAMETER AllowLiveFileWrites
    Permiso explicito para sobreescribir los archivos vivos del jugador. Son dos
    parametros distintos a proposito: equivocarse en uno no puede llegar a
    escribir sobre la configuracion real.
.PARAMETER ImportCvarList
    Ruta a un volcado de `cvarlist` de la consola de CS2. Presente => el motor NO
    hace backup ni restore: regenera config/convars.json y termina. No toca Steam
    ni la configuracion del jugador. En la consola del juego:
        con_logfile cvars.txt
        cvarlist
        con_logfile ""
.PARAMETER CatalogLabel
    De donde salio el volcado (build del juego o fecha). Se guarda en el catalogo
    para poder auditarlo. Sin ella se firma solo con el sha256 del volcado.
.PARAMETER CatalogPath
    Destino del catalogo generado. Por defecto ./config/convars.json, que es
    donde lo busca el motor.
.EXAMPLE
    pwsh ./CS2ConfigEngine.ps1
.EXAMPLE
    pwsh ./CS2ConfigEngine.ps1 -SteamPath 'D:\Steam' -Formats autoexec,json -LogLevel Debug
.EXAMPLE
    # Preview: que pasaria si vuelvo al ultimo snapshot (no escribe nada)
    pwsh ./CS2ConfigEngine.ps1 -Restore latest
.EXAMPLE
    # Restaurar a la carpeta de salida, sin tocar la config del jugador
    pwsh ./CS2ConfigEngine.ps1 -Restore 20260129-101500 -Apply
.EXAMPLE
    # Restaurar encima de los archivos vivos (backup previo + rollback automatico)
    pwsh ./CS2ConfigEngine.ps1 -Restore latest -Apply -RestoreTarget LiveFiles -AllowLiveFileWrites
.EXAMPLE
    # Regenerar el catalogo de convars desde un volcado de cvarlist
    pwsh ./CS2ConfigEngine.ps1 -ImportCvarList 'C:\Steam\steamapps\common\Counter-Strike Global Offensive\game\csgo\cvars.txt' -CatalogLabel 'build 14025'
#>
[CmdletBinding()]
param(
    [string]   $SteamPath = '',
    [string]   $SteamId   = '',
    [string]   $OutputPath = (Join-Path $PSScriptRoot 'output'),
    [int]      $MaxHistory = 10,
    [string[]] $Formats = @('autoexec', 'json', 'markdown', 'yaml', 'csv'),
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]   $LogLevel = 'Info',
    [string]   $Restore = '',
    [switch]   $Apply,
    [ValidateSet('Output', 'LiveFiles')]
    [string]   $RestoreTarget = 'Output',
    [switch]   $AllowLiveFileWrites,
    [string]   $ImportCvarList = '',
    [string]   $CatalogLabel = '',
    [string]   $CatalogPath = (Join-Path $PSScriptRoot 'config/convars.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Cargar toda la arquitectura.
. (Join-Path $PSScriptRoot 'src/Bootstrap.ps1') -Root (Join-Path $PSScriptRoot 'src')

function Invoke-CS2ConfigEngine {
    [CmdletBinding()]
    param(
        [string] $SteamPath, [string] $SteamId, [string] $OutputPath,
        [int] $MaxHistory, [string[]] $Formats, [string] $LogLevel
    )

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $logFile = Join-Path $OutputPath 'engine.log'
    $log = [Logger]::new([LogLevel]::$LogLevel, $logFile)
    $log.Info('=== CS2 Configuration Snapshot Engine ===')

    $configDir = Join-Path $PSScriptRoot 'config'
    $rulesPath = Join-Path $configDir 'classification-rules.json'
    $fbPath    = Join-Path $configDir 'fallbacks.json'
    # Catalogo generado (A3). Es opcional: si no se ha importado ningun volcado,
    # el motor se comporta igual que antes con la lista curada.
    $catPath   = Join-Path $configDir 'convars.json'

    try {
        # 1. Descubrimiento
        $steam = [SteamDiscovery]::new($log).Discover($SteamPath)
        $cs2   = [CS2Discovery]::new($log).Discover($steam, $SteamId)
        $files = [ConfigFileDiscovery]::new($log).Discover($cs2.CfgSearchRoots)

        if ($files.Count -eq 0) {
            $log.Warn('No se descubrieron archivos de configuracion. Verifique que CS2 se haya ejecutado al menos una vez.')
        }

        # 2. Parseo
        $factory = [ParserFactory]::new($log)
        $parsed  = $factory.ParseAll($files)
        $log.Info("Ajustes parseados (con duplicados): $($parsed.Count)")

        # 3. Clasificacion + sincronizacion
        $classifier = [Classifier]::new($log, $rulesPath)
        $fallbacks  = [FallbackCatalog]::new($fbPath, $catPath, $log)
        $sync       = [SyncEngine]::new($log, $fallbacks, $classifier)
        $config     = $sync.Build($parsed, $cs2, $steam, $files)

        # 4. Validacion (no destructiva)
        $issues = [Validator]::new($log).Validate($config)

        # 5. Snapshot + historial
        $snapMgr = [SnapshotManager]::new($log, (Join-Path $OutputPath 'backups'), $MaxHistory)
        $prev    = $snapMgr.GetPreviousConfigState('')
        $snap    = $snapMgr.Create($config, $files)
        # El diff por setting se calcula contra el Inventory.json del snapshot
        # anterior: history.json solo guarda hashes y conteos.
        $prevInv = if ($prev) { $snapMgr.GetInventoryPath([string]$prev.id) } else { '' }

        # 6. Exportacion (cada exportador es independiente)
        Export-Configurations -Config $config -Snapshot $snap -Formats $Formats -OutputPath $OutputPath -Log $log

        # 7. Reportes
        [ReportGenerator]::new($log).GenerateAll($config, $snap, $files, $issues, $prev, $prevInv)

        $log.Info("Backup completado. Salida: $($snap.Path)")
        return $snap
    }
    catch {
        $log.Error("Fallo critico: $($_.Exception.Message)")
        $log.Debug($_.ScriptStackTrace)
        throw
    }
}

<#
    Modo restore (A2). Comparte con el backup las cuatro primeras fases
    (descubrir, parsear, clasificar, sincronizar) porque el preview necesita la
    configuracion VIVA como base de comparacion; a partir de ahi no crea
    snapshot ni exporta nada: solo planifica y, si se lo piden, escribe.

    Por defecto es solo-mostrar. Se necesita -Apply para escribir, y ademas
    -RestoreTarget LiveFiles junto con -AllowLiveFileWrites para tocar los
    archivos del jugador.
#>
function Invoke-CS2Restore {
    [CmdletBinding()]
    param(
        [string] $SteamPath, [string] $SteamId, [string] $OutputPath, [string] $LogLevel,
        [string] $SnapshotId, [bool] $Apply, [string] $RestoreTarget, [bool] $AllowLiveFileWrites
    )

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $log = [Logger]::new([LogLevel]::$LogLevel, (Join-Path $OutputPath 'engine.log'))
    $log.Info('=== CS2 Configuration Snapshot Engine :: RESTORE ===')

    $configDir = Join-Path $PSScriptRoot 'config'

    try {
        # 1-4. Misma tuberia que el backup: hace falta la config viva.
        $steam = [SteamDiscovery]::new($log).Discover($SteamPath)
        $cs2   = [CS2Discovery]::new($log).Discover($steam, $SteamId)
        $files = [ConfigFileDiscovery]::new($log).Discover($cs2.CfgSearchRoots)
        $parsed = [ParserFactory]::new($log).ParseAll($files)
        $classifier = [Classifier]::new($log, (Join-Path $configDir 'classification-rules.json'))
        $fallbacks  = [FallbackCatalog]::new((Join-Path $configDir 'fallbacks.json'),
                                           (Join-Path $configDir 'convars.json'), $log)
        $live = [SyncEngine]::new($log, $fallbacks, $classifier).Build($parsed, $cs2, $steam, $files)

        # 5. Plan. No escribe nada.
        $engine = [RestoreEngine]::new($log, (Join-Path $OutputPath 'backups'), $OutputPath)
        $plan = $engine.Plan($SnapshotId, $live, [RestoreTarget]$RestoreTarget, $AllowLiveFileWrites)

        if (-not $Apply) {
            Write-Host $plan.Render()
            $log.Info('Restore en modo solo-mostrar: no se escribio nada.')
            return $plan
        }

        # 6. Aplicar, con backup previo y rollback atomico.
        $result = $engine.Apply($plan)
        Write-Host $result.Render()
        return $result
    }
    catch {
        $log.Error("Restore fallido: $($_.Exception.Message)")
        $log.Debug($_.ScriptStackTrace)
        throw
    }
}

<#
    Modo importacion de catalogo (A3). Independiente del resto: no descubre
    Steam, no lee la configuracion del jugador y no escribe nada fuera del
    catalogo, asi que se puede ejecutar en cualquier maquina con el volcado a
    mano. Solo regenera config/convars.json.

    Que se hace con lo que no se sabe leer: NO se descarta. El catalogo publica
    cada linea no reconocida con su numero y su texto, y aqui se resumen por
    consola, porque son la lista de trabajo para ajustar las hipotesis de formato
    contra el volcado real.
#>
function Invoke-CS2CatalogImport {
    [CmdletBinding()]
    param(
        [string] $DumpPath, [string] $CatalogPath, [string] $Label,
        [string] $OutputPath, [string] $LogLevel
    )

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $log = [Logger]::new([LogLevel]::$LogLevel, (Join-Path $OutputPath 'engine.log'))
    $log.Info('=== CS2 Configuration Snapshot Engine :: IMPORTAR CATALOGO ===')

    if (-not (Test-Path -LiteralPath $DumpPath)) {
        throw ("No se encontro el volcado de cvarlist: {0}. Generelo en la consola de CS2 con: " +
               'con_logfile cvars.txt / cvarlist / con_logfile ""') -f $DumpPath
    }

    $parsed = [CvarListParser]::new($log).ParseFile($DumpPath)
    if ($parsed.Entries.Count -eq 0) {
        # Sin entradas NO se sobreescribe el catalogo existente: un volcado vacio
        # o ilegible no debe borrar uno bueno.
        $log.Error('El volcado no produjo ninguna entrada; no se escribe el catalogo.')
        Write-Host 'No se reconocio ninguna entrada en el volcado. El catalogo anterior se deja intacto.'
        Write-Host 'Compruebe que el archivo contiene la salida de cvarlist y no solo el eco de los comandos.'
        return $parsed
    }

    $builder = [ConvarCatalogBuilder]::new($log)
    $builder.Write($parsed, $CatalogPath, $Label,
                   (Split-Path -Leaf $DumpPath), (Get-FileHashSafe -Path $DumpPath))

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('Catalogo de convars regenerado.')
    [void]$sb.AppendLine(("  archivo          : {0}" -f $CatalogPath))
    [void]$sb.AppendLine(("  convars          : {0}" -f $parsed.ConvarCount()))
    [void]$sb.AppendLine(("  concommands      : {0}" -f $parsed.CommandCount()))
    [void]$sb.AppendLine(("  lineas del volcado: {0}" -f $parsed.TotalLines))
    [void]$sb.AppendLine(("  duplicadas       : {0} (se conserva la primera aparicion)" -f $parsed.CountByReason('duplicate')))
    [void]$sb.AppendLine(("  no reconocidas   : {0} (conservadas en la seccion 'unrecognized')" -f $parsed.Unrecognized().Count))
    if ($parsed.DeclaredTotal -ge 0) {
        [void]$sb.AppendLine(("  total declarado por el volcado: {0}" -f $parsed.DeclaredTotal))
    }
    if ($parsed.LooksTruncated()) {
        [void]$sb.AppendLine('  AVISO: se leyeron menos entradas de las que el volcado declara. Parece truncado.')
    }
    [void]$sb.AppendLine('  El formato de cvarlist sigue marcado como NO verificado (source.formatVerified = false).')
    Write-Host $sb.ToString()
    return $parsed
}

function Export-Configurations {
    param(
        [GameConfig] $Config, [Snapshot] $Snapshot,
        [string[]] $Formats, [string] $OutputPath, [Logger] $Log
    )
    $exporters = @{
        autoexec = [AutoexecExporter]::new()
        json     = [JsonExporter]::new()
        markdown = [MarkdownExporter]::new()
        yaml     = [YamlExporter]::new()
        csv      = [CsvExporter]::new()
    }
    $extensions = @{
        autoexec = 'autoexec.cfg'; json = 'config.json'; markdown = 'config.md'
        yaml = 'config.yaml'; csv = 'config.csv'
    }
    $exportDir = Join-Path $Snapshot.Path 'export'
    if (-not (Test-Path -LiteralPath $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }

    foreach ($fmt in $Formats) {
        $key = $fmt.ToLowerInvariant()
        if (-not $exporters.ContainsKey($key)) {
            $Log.Warn("Formato desconocido omitido: $fmt")
            continue
        }
        $outFile = Join-Path $exportDir $extensions[$key]
        $exporters[$key].Export($Config, $outFile, $Log)
    }
    # Copia del autoexec a la raiz de salida para acceso rapido.
    if ($Formats -contains 'autoexec') {
        Copy-Item -LiteralPath (Join-Path $exportDir 'autoexec.cfg') `
                  -Destination (Join-Path $OutputPath 'autoexec.latest.cfg') -Force
    }
}

# Ejecutar solo si se invoca directamente (no al dot-sourcing para pruebas).
if ($MyInvocation.InvocationName -ne '.') {
    if (-not [string]::IsNullOrWhiteSpace($ImportCvarList)) {
        Invoke-CS2CatalogImport -DumpPath $ImportCvarList -CatalogPath $CatalogPath `
            -Label $CatalogLabel -OutputPath $OutputPath -LogLevel $LogLevel | Out-Null
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Restore)) {
        Invoke-CS2Restore -SteamPath $SteamPath -SteamId $SteamId -OutputPath $OutputPath `
            -LogLevel $LogLevel -SnapshotId $Restore -Apply:$Apply.IsPresent `
            -RestoreTarget $RestoreTarget -AllowLiveFileWrites:$AllowLiveFileWrites.IsPresent | Out-Null
    }
    else {
        Invoke-CS2ConfigEngine -SteamPath $SteamPath -SteamId $SteamId -OutputPath $OutputPath `
            -MaxHistory $MaxHistory -Formats $Formats -LogLevel $LogLevel | Out-Null
    }
}
