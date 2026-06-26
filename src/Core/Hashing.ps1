<#
.SYNOPSIS
    Utilidades de hashing deterministas (SHA-256).
.DESCRIPTION
    Funciones puras usadas para firmar valores, archivos y snapshots completos.
    Determinista: la misma entrada produce siempre el mismo hash.
#>

Set-StrictMode -Version Latest

function Get-StringHash {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash  = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-FileHashSafe {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    } catch {
        return ''
    }
}
