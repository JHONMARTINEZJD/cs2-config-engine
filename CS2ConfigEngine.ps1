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
.EXAMPLE
    pwsh ./CS2ConfigEngine.ps1
.EXAMPLE
    pwsh ./CS2ConfigEngine.ps1 -SteamPath 'D:\Steam' -Formats autoexec,json -LogLevel Debug
#>
[CmdletBinding()]
param(
    [string]   $SteamPath = '',
    [string]   $SteamId   = '',
    [string]   $OutputPath = (Join-Path $PSScriptRoot 'output'),
    [int]      $MaxHistory = 10,
    [string[]] $Formats = @('autoexec', 'json', 'markdown', 'yaml', 'csv'),
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]   $LogLevel = 'Info'
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
        $fallbacks  = [FallbackCatalog]::new($fbPath, $log)
        $sync       = [SyncEngine]::new($log, $fallbacks, $classifier)
        $config     = $sync.Build($parsed, $cs2, $steam, $files)

        # 4. Validacion (no destructiva)
        $issues = [Validator]::new($log).Validate($config)

        # 5. Snapshot + historial
        $snapMgr = [SnapshotManager]::new($log, (Join-Path $OutputPath 'backups'), $MaxHistory)
        $prev    = $snapMgr.GetPreviousConfigState('')
        $snap    = $snapMgr.Create($config, $files)

        # 6. Exportacion (cada exportador es independiente)
        Export-Configurations -Config $config -Snapshot $snap -Formats $Formats -OutputPath $OutputPath -Log $log

        # 7. Reportes
        [ReportGenerator]::new($log).GenerateAll($config, $snap, $files, $issues, $prev)

        $log.Info("Backup completado. Salida: $($snap.Path)")
        return $snap
    }
    catch {
        $log.Error("Fallo critico: $($_.Exception.Message)")
        $log.Debug($_.ScriptStackTrace)
        throw
    }
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
    Invoke-CS2ConfigEngine -SteamPath $SteamPath -SteamId $SteamId -OutputPath $OutputPath `
        -MaxHistory $MaxHistory -Formats $Formats -LogLevel $LogLevel | Out-Null
}
