<#
.SYNOPSIS
    Localiza la instalacion de CS2 (appid 730), el SteamID activo y el arbol cfg.
.DESCRIPTION
    - CS2: busca "Counter-Strike Global Offensive" en cada biblioteca Steam.
    - SteamID: detecta el perfil mas recientemente usado dentro de userdata,
      o el indicado por el usuario; soporta multiples cuentas.
    - cfg: resuelve userdata\<SteamID>\730\local\cfg sin asumir la ruta exacta,
      buscando dentro del arbol si Valve la cambia en el futuro.
#>

Set-StrictMode -Version Latest

class CS2Location {
    [string]   $GameRoot          # ...\steamapps\common\Counter-Strike Global Offensive
    [string]   $SteamId           # SteamID3 (carpeta numerica de userdata)
    [string]   $UserDataRoot      # ...\userdata\<SteamId>
    [string]   $LocalCfgPath      # carpeta cfg activa (730\local\cfg)
    [string[]] $CfgSearchRoots    # raices donde buscar archivos de config
}

class CS2Discovery {
    hidden [Logger] $Log
    static [string] $AppId = '730'
    static [string] $GameDirName = 'Counter-Strike Global Offensive'

    CS2Discovery([Logger] $log) { $this.Log = $log }

    [CS2Location] Discover([SteamLocation] $steam, [string] $steamIdHint) {
        $loc = [CS2Location]::new()
        $loc.GameRoot     = $this.FindGameRoot($steam.LibraryFolders)
        $loc.SteamId      = $this.ResolveSteamId($steam.SteamRoot, $steamIdHint)
        $loc.UserDataRoot = Join-Path $steam.SteamRoot ('userdata\{0}' -f $loc.SteamId)

        if (-not (Test-Path -LiteralPath $loc.UserDataRoot)) {
            throw "No se encontro userdata para el SteamID '$($loc.SteamId)'."
        }

        $loc.LocalCfgPath   = $this.FindLocalCfg($loc.UserDataRoot)
        $loc.CfgSearchRoots = $this.BuildSearchRoots($loc, $steam)

        $this.Log.Info("CS2 game root: $($loc.GameRoot)")
        $this.Log.Info("SteamID activo: $($loc.SteamId)")
        $this.Log.Info("cfg local: $($loc.LocalCfgPath)")
        return $loc
    }

    hidden [string] FindGameRoot([string[]] $libraries) {
        foreach ($lib in $libraries) {
            $candidate = Join-Path $lib ('steamapps\common\{0}' -f [CS2Discovery]::GameDirName)
            if (Test-Path -LiteralPath $candidate) { return $candidate }
            # Confirmacion adicional via manifest appid 730.
            $manifest = Join-Path $lib ('steamapps\appmanifest_{0}.acf' -f [CS2Discovery]::AppId)
            if (Test-Path -LiteralPath $manifest) {
                $installDir = $this.ReadAcfInstallDir($manifest)
                if ($installDir) {
                    $p = Join-Path $lib ('steamapps\common\{0}' -f $installDir)
                    if (Test-Path -LiteralPath $p) { return $p }
                }
            }
        }
        $this.Log.Warn("No se localizo el directorio de juego de CS2 (appid 730).")
        return ''
    }

    hidden [string] ReadAcfInstallDir([string] $manifestPath) {
        try {
            $text = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8
            $m = [regex]::Match($text, '"installdir"\s*"([^"]+)"')
            if ($m.Success) { return $m.Groups[1].Value }
        } catch { }
        return ''
    }

    hidden [string] ResolveSteamId([string] $steamRoot, [string] $hint) {
        $userdata = Join-Path $steamRoot 'userdata'
        if (-not (Test-Path -LiteralPath $userdata)) {
            throw "No existe el directorio userdata en $steamRoot."
        }

        $profiles = Get-ChildItem -LiteralPath $userdata -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+$' -and $_.Name -ne '0' }

        if (-not $profiles) {
            throw "No se encontraron perfiles de usuario en userdata."
        }

        if ($hint) {
            $match = $profiles | Where-Object { $_.Name -eq $hint }
            if ($match) { return $hint }
            $this.Log.Warn("El SteamID indicado '$hint' no existe; se autodetectara.")
        }

        # Preferir perfiles que realmente tengan datos de CS2 (730).
        $targetAppId = [CS2Discovery]::AppId
        $withCs2 = $profiles | Where-Object {
            Test-Path -LiteralPath (Join-Path $_.FullName $targetAppId)
        }
        $pool = if ($withCs2) { $withCs2 } else { $profiles }

        # El mas recientemente modificado = cuenta activa.
        $active = $pool | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        return $active.Name
    }

    # Busca la carpeta cfg de CS2 sin asumir la ruta literal exacta.
    hidden [string] FindLocalCfg([string] $userDataRoot) {
        $expected = Join-Path $userDataRoot ('{0}\local\cfg' -f [CS2Discovery]::AppId)
        if (Test-Path -LiteralPath $expected) { return $expected }

        # Fallback tolerante: localizar cualquier carpeta 'cfg' bajo 730.
        $appRoot = Join-Path $userDataRoot ([CS2Discovery]::AppId)
        if (Test-Path -LiteralPath $appRoot) {
            $found = Get-ChildItem -LiteralPath $appRoot -Directory -Recurse -Filter 'cfg' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($found) {
                $this.Log.Warn("cfg no estaba en la ruta esperada; usando $($found.FullName)")
                return $found.FullName
            }
        }
        # Como ultimo recurso, devolver la ruta esperada (puede crearse luego).
        return $expected
    }

    # Raices donde el descubridor de archivos buscara configuracion.
    hidden [string[]] BuildSearchRoots([CS2Location] $loc, [SteamLocation] $steam) {
        $roots = [System.Collections.Generic.List[string]]::new()
        if ($loc.LocalCfgPath)      { $roots.Add($loc.LocalCfgPath) }
        # carpeta 730\local completa (a veces hay subcarpetas adicionales)
        $appLocal = Join-Path $loc.UserDataRoot ('{0}\local' -f [CS2Discovery]::AppId)
        if (Test-Path -LiteralPath $appLocal) { $roots.Add($appLocal) }
        # cfg del juego (game\csgo\cfg) por si hay autoexec/practice configs
        if ($loc.GameRoot) {
            $gameCfg = Join-Path $loc.GameRoot 'game\csgo\cfg'
            if (Test-Path -LiteralPath $gameCfg) { $roots.Add($gameCfg) }
        }
        return ($roots | Select-Object -Unique)
    }
}
