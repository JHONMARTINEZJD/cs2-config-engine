#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter()]
    [string] $RepoUrl = '',

    [Parameter()]
    [string] $Branch = 'master',

    [Parameter()]
    [string] $OutputPath = '',

    [Parameter()]
    [switch] $RunTests,

    [Parameter()]
    [switch] $SkipDependencyInstall,

    [Parameter()]
    [string] $SourcePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepositoryRoot {
    [CmdletBinding()]
    param(
        [string] $RepoUrl,
        [string] $Branch,
        [string] $SourcePath
    )

    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        $resolvedSource = Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop
        return [pscustomobject]@{
            RootPath = $resolvedSource.Path
            Source = 'local'
        }
    }

    if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
        throw 'Proporciona -RepoUrl o -SourcePath para ejecutar este launcher.'
    }

    $repoUri = [Uri]$RepoUrl
    $segments = $repoUri.AbsolutePath.Trim('/').Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($segments.Count -lt 2) {
        throw "La URL del repositorio no es válida: $RepoUrl"
    }

    $owner = $segments[0]
    $repoName = $segments[1]
    $archiveUrl = "https://codeload.github.com/$owner/$repoName/zip/refs/heads/$Branch"

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cs2-config-engine-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $archivePath = Join-Path $tempRoot 'repo.zip'
    Write-Host "Descargando repositorio desde $archiveUrl" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing

    Expand-Archive -LiteralPath $archivePath -DestinationPath $tempRoot -Force
    $extractedRoot = Get-ChildItem -LiteralPath $tempRoot -Directory | Where-Object { $_.Name -like "$repoName-*" } | Select-Object -First 1

    if (-not $extractedRoot) {
        throw 'No se pudo localizar la carpeta extraída del repositorio.'
    }

    return [pscustomobject]@{
        RootPath = $extractedRoot.FullName
        Source = 'github'
    }
}

$repoInfo = Resolve-RepositoryRoot -RepoUrl $RepoUrl -Branch $Branch -SourcePath $SourcePath
$runScript = Join-Path $repoInfo.RootPath 'run.ps1'
if (-not (Test-Path -LiteralPath $runScript)) {
    throw "No se encontró run.ps1 en $($repoInfo.RootPath)"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $env:USERPROFILE 'Downloads/CS2ConfigEngine'
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Write-Host "Ejecutando CS2 Config Engine desde $($repoInfo.RootPath)" -ForegroundColor Green
Write-Host "La salida se generará en $OutputPath" -ForegroundColor Green

$invokeArgs = @{
    OutputPath = $OutputPath
}
if ($RunTests) {
    $invokeArgs.RunTests = $true
}
if ($SkipDependencyInstall) {
    $invokeArgs.SkipDependencyInstall = $true
}

& $runScript @invokeArgs

$autoexecPath = Join-Path $OutputPath 'autoexec.latest.cfg'
$backupPath = Join-Path $OutputPath 'backups'

Write-Host ''
Write-Host 'Listo. Archivos generados:' -ForegroundColor Green
if (Test-Path -LiteralPath $autoexecPath) {
    Write-Host "- Autoexec: $autoexecPath"
}
else {
    $latestAutoexec = Get-ChildItem -LiteralPath $OutputPath -File -Filter 'autoexec*.cfg' -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestAutoexec) {
        Write-Host "- Autoexec: $($latestAutoexec.FullName)"
    }
}

if (Test-Path -LiteralPath $backupPath) {
    Write-Host "- Backup: $backupPath"
}
