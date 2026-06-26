<#
.SYNOPSIS
    Cargador (dot-source) de todas las clases del motor en orden de dependencia.
.DESCRIPTION
    Las clases de PowerShell deben estar definidas en la sesion antes de usarse.
    Este script las carga en el orden topologico correcto. Importar este unico
    archivo deja disponible toda la arquitectura.
.PARAMETER Root
    Carpeta src del proyecto. Por defecto la carpeta de este script.
#>

param([string] $Root = $PSScriptRoot)

Set-StrictMode -Version Latest

$ordered = @(
    'Core/Types.ps1'
    'Core/Logging.ps1'
    'Core/Hashing.ps1'
    'Discovery/SteamDiscovery.ps1'
    'Discovery/CS2Discovery.ps1'
    'Discovery/ConfigFileDiscovery.ps1'
    'Parsing/Tokenizer.ps1'
    'Parsing/VdfParser.ps1'
    'Parsing/VcfgParser.ps1'
    'Parsing/CfgParser.ps1'
    'Parsing/ParserFactory.ps1'
    'Classification/CategoryMap.ps1'
    'Classification/Classifier.ps1'
    'Sync/SyncEngine.ps1'
    'Validation/Validator.ps1'
    'Export/AutoexecExporter.ps1'
    'Export/DataExporters.ps1'
    'Backup/SnapshotManager.ps1'
    'Reporting/ReportGenerator.ps1'
)

foreach ($rel in $ordered) {
    $path = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $path)) {
        throw "No se encontro el modulo requerido: $path"
    }
    . $path
}
