<#
.SYNOPSIS
    Gestiona snapshots con timestamp, hash, estadisticas e historial.
.DESCRIPTION
    Cada ejecucion crea una carpeta de snapshot:
        backups/<yyyyMMdd-HHmmss>/
    donde se copian los archivos originales y se guardan reportes. Mantiene un
    historial configurable (rota los mas antiguos) y un indice history.json.
#>

Set-StrictMode -Version Latest

class Snapshot {
    [string]   $Id
    [string]   $Path
    [datetime] $Timestamp
    [string]   $Hash
    [long]     $TotalSize
    [int]      $BindCount
    [int]      $ConvarCount
    [int]      $AliasCount
}

class SnapshotManager {
    hidden [Logger] $Log
    hidden [string] $BackupRoot
    hidden [int]    $MaxHistory

    SnapshotManager([Logger] $log, [string] $backupRoot, [int] $maxHistory) {
        $this.Log        = $log
        $this.BackupRoot = $backupRoot
        $this.MaxHistory = [Math]::Max(1, $maxHistory)
        if (-not (Test-Path -LiteralPath $backupRoot)) {
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        }
    }

    [Snapshot] Create([GameConfig] $cfg, [DiscoveredFile[]] $sourceFiles) {
        $id  = [datetime]::Now.ToString('yyyyMMdd-HHmmss')
        $dir = Join-Path $this.BackupRoot $id
        $rawDir = Join-Path $dir 'raw'
        New-Item -ItemType Directory -Path $rawDir -Force | Out-Null

        # Copia fiel de los archivos vivos originales.
        $totalSize = 0
        foreach ($f in $sourceFiles) {
            if (-not (Test-Path -LiteralPath $f.Path)) { continue }
            $dest = Join-Path $rawDir $f.Name
            $dest = $this.UniquePath($dest)
            Copy-Item -LiteralPath $f.Path -Destination $dest -Force
            $totalSize += $f.Size
        }

        $snap = [Snapshot]::new()
        $snap.Id          = $id
        $snap.Path        = $dir
        $snap.Timestamp   = [datetime]::Now
        $snap.TotalSize   = $totalSize
        $snap.BindCount   = $cfg.CountByType([SettingType]::Bind) + $cfg.CountByType([SettingType]::AnalogBind)
        $snap.ConvarCount = $cfg.CountByType([SettingType]::Bool) + $cfg.CountByType([SettingType]::Integer) +
                            $cfg.CountByType([SettingType]::Float) + $cfg.CountByType([SettingType]::String) +
                            $cfg.CountByType([SettingType]::Unknown)
        $snap.AliasCount  = $cfg.CountByType([SettingType]::Alias)
        $snap.Hash        = $this.ComputeConfigHash($cfg)

        $this.Log.Info("Snapshot creado: $id (hash $($snap.Hash.Substring(0,12))...)")
        $this.UpdateHistory($snap)
        $this.Rotate()
        return $snap
    }

    # Hash determinista del estado completo de la config.
    hidden [string] ComputeConfigHash([GameConfig] $cfg) {
        [System.Text.StringBuilder] $sb = [System.Text.StringBuilder]::new()
        foreach ($cat in $cfg.Categories) {
            foreach ($s in $cat.Settings) {
                [void]$sb.AppendLine(('{0}|{1}|{2}' -f $s.CategoryCode, $s.Key(), $s.Value))
            }
        }
        return Get-StringHash -Text $sb.ToString()
    }

    hidden [string] UniquePath([string] $path) {
        if (-not (Test-Path -LiteralPath $path)) { return $path }
        [string] $dir  = Split-Path -Parent $path
        [string] $name = [System.IO.Path]::GetFileNameWithoutExtension($path)
        [string] $ext  = [System.IO.Path]::GetExtension($path)
        [int] $i = 1
        [string] $candidate = ''
        do {
            $candidate = Join-Path $dir ("{0}_{1}{2}" -f $name, $i, $ext)
            $i++
        } while (Test-Path -LiteralPath $candidate)
        return $candidate
    }

    hidden [void] UpdateHistory([Snapshot] $snap) {
        $historyPath = Join-Path $this.BackupRoot 'history.json'
        $history = @()
        if (Test-Path -LiteralPath $historyPath) {
            try { $history = @(Get-Content -LiteralPath $historyPath -Raw -Encoding utf8 | ConvertFrom-Json) } catch { $history = @() }
        }
        $entry = [ordered]@{
            id          = $snap.Id
            timestamp   = $snap.Timestamp.ToString('o')
            hash        = $snap.Hash
            totalSize   = $snap.TotalSize
            bindCount   = $snap.BindCount
            convarCount = $snap.ConvarCount
            aliasCount  = $snap.AliasCount
        }
        $history = @($history) + $entry
        ($history | ConvertTo-Json -Depth 6) |
            Out-File -LiteralPath $historyPath -Encoding utf8
    }

    hidden [void] Rotate() {
        $dirs = @(Get-ChildItem -LiteralPath $this.BackupRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending)
        if ($dirs.Count -le $this.MaxHistory) { return }
        $toRemove = $dirs | Select-Object -Skip $this.MaxHistory
        foreach ($d in $toRemove) {
            $this.Log.Debug("Rotando snapshot antiguo: $($d.Name)")
            Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Carga el snapshot anterior (para diff). $null si no hay.
    [object] GetPreviousConfigState([string] $currentId) {
        $historyPath = Join-Path $this.BackupRoot 'history.json'
        if (-not (Test-Path -LiteralPath $historyPath)) { return $null }
        try {
            $history = @(Get-Content -LiteralPath $historyPath -Raw -Encoding utf8 | ConvertFrom-Json)
            $prev = $history | Where-Object { $_.id -ne $currentId } | Select-Object -Last 1
            return $prev
        } catch { return $null }
    }
}
