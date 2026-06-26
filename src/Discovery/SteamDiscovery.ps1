<#
.SYNOPSIS
    Descubrimiento automatico de la instalacion de Steam y sus bibliotecas.
.DESCRIPTION
    No asume rutas fijas. Estrategia en capas:
      1. Registro de Windows (HKCU/HKLM, 32/64 bit).
      2. Variables de entorno.
      3. Rutas candidatas comunes (multiples discos).
      4. Modo portable (junto al script o ruta indicada).
    A partir del Steam root resuelve TODAS las bibliotecas leyendo
    libraryfolders.vdf (formato VDF anidado actual de Steam).
#>

Set-StrictMode -Version Latest

class SteamLocation {
    [string]   $SteamRoot
    [string[]] $LibraryFolders
}

class SteamDiscovery {
    hidden [Logger] $Log

    SteamDiscovery([Logger] $log) { $this.Log = $log }

    [SteamLocation] Discover([string] $portableHint) {
        $root = $this.ResolveSteamRoot($portableHint)
        if (-not $root) {
            throw "No se pudo localizar la instalacion de Steam. Indique -SteamPath manualmente."
        }
        $this.Log.Info("Steam localizado en: $root")

        $loc = [SteamLocation]::new()
        $loc.SteamRoot      = $root
        $loc.LibraryFolders = $this.ResolveLibraryFolders($root)
        $this.Log.Info("Bibliotecas Steam detectadas: $($loc.LibraryFolders.Count)")
        return $loc
    }

    hidden [string] ResolveSteamRoot([string] $portableHint) {
        # 1. Pista explicita / portable
        if ($portableHint) {
            $p = $this.NormalizeSteamDir($portableHint)
            if ($p) { return $p }
        }

        # 2. Registro (solo en Windows)
        if ($env:OS -eq 'Windows_NT') {
            foreach ($key in @(
                'HKCU:\Software\Valve\Steam',
                'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
                'HKLM:\SOFTWARE\Valve\Steam'
            )) {
                try {
                    $val = (Get-ItemProperty -Path $key -ErrorAction Stop)
                    foreach ($prop in 'SteamPath', 'InstallPath') {
                        if ($val.PSObject.Properties.Name -contains $prop -and $val.$prop) {
                            $p = $this.NormalizeSteamDir($val.$prop)
                            if ($p) { return $p }
                        }
                    }
                } catch { }
            }
        }

        # 3. Variables de entorno
        foreach ($envVar in @($env:STEAM_PATH, $env:STEAMPATH)) {
            if ($envVar) {
                $p = $this.NormalizeSteamDir($envVar)
                if ($p) { return $p }
            }
        }

        # 4. Candidatas comunes en todas las unidades
        $candidates = [System.Collections.Generic.List[string]]::new()
        foreach ($base in @('Program Files (x86)', 'Program Files')) {
            $candidates.Add((Join-Path $env:SystemDrive (Join-Path $base 'Steam')))
        }
        try {
            foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
                if (-not $drive.IsReady) { continue }
                foreach ($sub in @('Steam', 'SteamLibrary', 'Games\Steam')) {
                    $candidates.Add((Join-Path $drive.RootDirectory.FullName $sub))
                }
            }
        } catch { }

        foreach ($c in $candidates) {
            $p = $this.NormalizeSteamDir($c)
            if ($p) { return $p }
        }
        return $null
    }

    # Devuelve la ruta si parece una instalacion valida de Steam, si no $null.
    hidden [string] NormalizeSteamDir([string] $path) {
        if (-not $path) { return $null }
        try {
            $full = [System.IO.Path]::GetFullPath($path)
        } catch { return $null }
        if (-not (Test-Path -LiteralPath $full)) { return $null }

        # Senales de una raiz de Steam.
        foreach ($marker in @('steam.exe', 'config\config.vdf', 'steamapps', 'userdata')) {
            if (Test-Path -LiteralPath (Join-Path $full $marker)) { return $full }
        }
        return $null
    }

    # Lee libraryfolders.vdf y devuelve todas las rutas de biblioteca.
    hidden [string[]] ResolveLibraryFolders([string] $steamRoot) {
        $result = [System.Collections.Generic.List[string]]::new()
        $result.Add($steamRoot)

        $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            try {
                $text = Get-Content -LiteralPath $vdf -Raw -Encoding utf8
                # Extrae cualquier "path" del VDF sin asumir indentacion concreta.
                foreach ($m in [regex]::Matches($text, '"path"\s*"([^"]+)"')) {
                    $p = $m.Groups[1].Value -replace '\\\\', '\'
                    if (Test-Path -LiteralPath $p) { $result.Add($p) }
                }
            } catch {
                $this.Log.Warn("No se pudo leer libraryfolders.vdf: $($_.Exception.Message)")
            }
        }
        return ($result | Select-Object -Unique)
    }
}
