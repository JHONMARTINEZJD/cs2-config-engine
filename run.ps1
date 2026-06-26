#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $SteamPath = '',
    [string] $SteamId = '',
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output'),
    [int] $MaxHistory = 10,
    [string[]] $Formats = @('autoexec', 'json', 'markdown', 'yaml', 'csv'),
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string] $LogLevel = 'Info',
    [switch] $RunTests,
    [switch] $SkipDependencyInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Dependencies {
    [CmdletBinding()]
    param([switch] $AllowInstall)

    $requiredVersion = [version]'5.0.0'
    $pester = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1

    if ($pester -and $pester.Version -ge $requiredVersion) {
        Import-Module Pester -MinimumVersion $requiredVersion -ErrorAction Stop | Out-Null
        return $true
    }

    if (-not $AllowInstall) {
        Write-Warning 'Pester 5+ no está disponible; las pruebas no se ejecutarán hasta instalarlo.'
        return $false
    }

    Write-Host 'Pester 5+ no detectado. Intentando instalarlo automáticamente...' -ForegroundColor Yellow
    try {
        if (-not (Get-Module -ListAvailable -Name PowerShellGet)) {
            Install-Module -Name PowerShellGet -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
        }

        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Name PSGallery -SourceLocation 'https://www.powershellgallery.com/api/v2' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue

        Install-Module -Name Pester -Force -Scope CurrentUser -MinimumVersion $requiredVersion -Repository PSGallery -SkipPublisherCheck -AllowClobber -ErrorAction Stop

        $pester = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
        if ($pester -and $pester.Version -ge $requiredVersion) {
            Import-Module Pester -MinimumVersion $requiredVersion -ErrorAction Stop | Out-Null
            Write-Host "Pester $($pester.Version) instalado correctamente." -ForegroundColor Green
            return $true
        }
    }
    catch {
        Write-Warning "No se pudo instalar Pester automáticamente: $($_.Exception.Message)"
        Write-Warning 'Puedes instalarlo manualmente con: Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0.0'
    }

    return $false
}

if ($PSBoundParameters.ContainsKey('Formats')) {
    $normalizedFormats = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Formats) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        foreach ($part in ($entry -split ',')) {
            $value = $part.Trim()
            if ($value) { $normalizedFormats.Add($value.ToLowerInvariant()) }
        }
    }
    $Formats = @($normalizedFormats | Select-Object -Unique)
}

$engineScript = Join-Path $PSScriptRoot 'CS2ConfigEngine.ps1'
if (-not (Test-Path -LiteralPath $engineScript)) {
    throw "No se encontro el script principal: $engineScript"
}

if (-not $SkipDependencyInstall) {
    Ensure-Dependencies -AllowInstall $true | Out-Null
}

if ($RunTests) {
    $testsPath = Join-Path $PSScriptRoot 'tests'
    if (Test-Path -LiteralPath $testsPath) {
        Write-Host 'Ejecutando pruebas Pester...' -ForegroundColor Cyan
        Invoke-Pester -Script $testsPath -OutputFile (Join-Path $PSScriptRoot 'output/pester-results.xml') -OutputFormat NUnitXml
    }
    else {
        Write-Warning 'No existe la carpeta de pruebas en este proyecto.'
    }
}

Write-Host 'Ejecutando CS2ConfigEngine...' -ForegroundColor Cyan
& $engineScript -SteamPath $SteamPath -SteamId $SteamId -OutputPath $OutputPath -MaxHistory $MaxHistory -Formats $Formats -LogLevel $LogLevel
