<#
.SYNOPSIS
    Genera todos los reportes del snapshot.
.DESCRIPTION
    Produce:
      - Manifest.json          (metadatos del snapshot + archivos)
      - Inventory.json         (inventario completo de ajustes)
      - Hashes.json            (hash por archivo y por setting)
      - BackupStatistics.json  (conteos y estadisticas)
      - BackupReport.json      (resumen + validacion)
      - BackupReport.md        (resumen legible)
      - ConfigDiff.json        (diferencias frente al snapshot anterior)
    Cada reporte es independiente.
#>

Set-StrictMode -Version Latest

class ReportGenerator {
    hidden [Logger] $Log
    ReportGenerator([Logger] $log) { $this.Log = $log }

    [void] GenerateAll([GameConfig] $cfg, [Snapshot] $snap, [DiscoveredFile[]] $files,
                       [System.Collections.Generic.List[ValidationIssue]] $issues,
                       [object] $prevState) {
        $dir = $snap.Path
        $this.WriteManifest($cfg, $snap, $files, (Join-Path $dir 'Manifest.json'))
        $this.WriteInventory($cfg, (Join-Path $dir 'Inventory.json'))
        $this.WriteHashes($cfg, $files, (Join-Path $dir 'Hashes.json'))
        $stats = $this.BuildStatistics($cfg, $issues)
        $this.WriteJson($stats, (Join-Path $dir 'BackupStatistics.json'))
        $this.WriteBackupReportJson($cfg, $snap, $stats, $issues, (Join-Path $dir 'BackupReport.json'))
        $this.WriteBackupReportMd($cfg, $snap, $stats, $issues, (Join-Path $dir 'BackupReport.md'))
        $this.WriteDiff($cfg, $snap, $prevState, (Join-Path $dir 'ConfigDiff.json'))
        $this.Log.Info("Reportes generados en $dir")
    }

    hidden [void] WriteJson([object] $obj, [string] $path) {
        ($obj | ConvertTo-Json -Depth 12) | Out-File -LiteralPath $path -Encoding utf8
    }

    hidden [void] WriteManifest([GameConfig] $cfg, [Snapshot] $snap, [DiscoveredFile[]] $files, [string] $path) {
        $manifest = [ordered]@{
            snapshotId = $snap.Id
            timestamp  = $snap.Timestamp.ToString('o')
            hash       = $snap.Hash
            steamId    = $cfg.SteamId
            steamPath  = $cfg.SteamPath
            cs2Path    = $cfg.CS2Path
            cfgPath    = $cfg.CfgPath
            files      = @($files | ForEach-Object {
                [ordered]@{ name = $_.Name; path = $_.Path; kind = $_.Kind; size = $_.Size; hash = $_.Hash }
            })
        }
        $this.WriteJson($manifest, $path)
    }

    hidden [void] WriteInventory([GameConfig] $cfg, [string] $path) {
        $inv = [ordered]@{
            total      = $cfg.TotalSettings()
            categories = @($cfg.Categories | ForEach-Object {
                [ordered]@{
                    code     = $_.Code
                    name     = $_.Name
                    count    = $_.Count()
                    settings = @($_.Settings | ForEach-Object { $_.ToHashtable() })
                }
            })
        }
        $this.WriteJson($inv, $path)
    }

    hidden [void] WriteHashes([GameConfig] $cfg, [DiscoveredFile[]] $files, [string] $path) {
        $hashes = [ordered]@{
            files    = [ordered]@{}
            settings = [ordered]@{}
        }
        foreach ($f in $files) { $hashes.files[$f.Name] = $f.Hash }
        foreach ($cat in $cfg.Categories) {
            foreach ($s in $cat.Settings) { $hashes.settings[$s.Key()] = $s.Metadata.Hash }
        }
        $this.WriteJson($hashes, $path)
    }

    hidden [object] BuildStatistics([GameConfig] $cfg, [System.Collections.Generic.List[ValidationIssue]] $issues) {
        $byCategory = [ordered]@{}
        foreach ($cat in $cfg.Categories) { $byCategory[$cat.Code] = $cat.Count() }

        $byType = [ordered]@{}
        foreach ($t in [enum]::GetNames([SettingType])) {
            $byType[$t] = $cfg.CountByType([SettingType]$t)
        }

        $byState = [ordered]@{}
        foreach ($st in [enum]::GetNames([SettingState])) { $byState[$st] = 0 }
        foreach ($s in $cfg.AllSettings()) { $byState[$s.State.ToString()]++ }

        $issueCounts = [ordered]@{}
        foreach ($sev in [enum]::GetNames([IssueSeverity])) { $issueCounts[$sev] = 0 }
        foreach ($i in $issues) { $issueCounts[$i.Severity.ToString()]++ }

        return [ordered]@{
            total       = $cfg.TotalSettings()
            byCategory  = $byCategory
            byType      = $byType
            byState     = $byState
            issues      = $issueCounts
            sourceFiles = $cfg.SourceFiles.Count
        }
    }

    hidden [void] WriteBackupReportJson([GameConfig] $cfg, [Snapshot] $snap, [object] $stats,
                                        [System.Collections.Generic.List[ValidationIssue]] $issues, [string] $path) {
        $report = [ordered]@{
            snapshotId = $snap.Id
            timestamp  = $snap.Timestamp.ToString('o')
            hash       = $snap.Hash
            statistics = $stats
            validation = @($issues | ForEach-Object {
                [ordered]@{
                    severity = $_.Severity.ToString()
                    code     = $_.Code
                    target   = $_.Target
                    message  = $_.Message
                    file     = $_.SourceFile
                    line     = $_.SourceLine
                }
            })
        }
        $this.WriteJson($report, $path)
    }

    hidden [void] WriteBackupReportMd([GameConfig] $cfg, [Snapshot] $snap, [object] $stats,
                                      [System.Collections.Generic.List[ValidationIssue]] $issues, [string] $path) {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('# Backup Report')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("- **Snapshot:** $($snap.Id)")
        [void]$sb.AppendLine("- **Fecha:** $($snap.Timestamp.ToString('u'))")
        [void]$sb.AppendLine("- **Hash:** ``$($snap.Hash)``")
        [void]$sb.AppendLine("- **SteamID:** $($cfg.SteamId)")
        [void]$sb.AppendLine("- **Tamano total origen:** $($snap.TotalSize) bytes")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('## Estadisticas')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("- Total de ajustes: **$($stats.total)**")
        [void]$sb.AppendLine("- Binds: **$($snap.BindCount)**")
        [void]$sb.AppendLine("- Convars: **$($snap.ConvarCount)**")
        [void]$sb.AppendLine("- Aliases: **$($snap.AliasCount)**")
        [void]$sb.AppendLine("- Archivos origen: **$($stats.sourceFiles)**")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('### Ajustes por categoria')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| Categoria | Ajustes |')
        [void]$sb.AppendLine('| --- | --- |')
        foreach ($cat in $cfg.Categories) {
            if ($cat.Count() -gt 0) { [void]$sb.AppendLine("| $($cat.Code) - $($cat.Name) | $($cat.Count()) |") }
        }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('## Validacion')
        [void]$sb.AppendLine('')
        if ($issues.Count -eq 0) {
            [void]$sb.AppendLine('Sin hallazgos. La configuracion esta limpia.')
        } else {
            [void]$sb.AppendLine('| Severidad | Codigo | Objetivo | Mensaje |')
            [void]$sb.AppendLine('| --- | --- | --- | --- |')
            foreach ($i in $issues) {
                [void]$sb.AppendLine("| $($i.Severity) | $($i.Code) | $($i.Target) | $($i.Message) |")
            }
        }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('> Nota: nunca se elimina informacion automaticamente. Todo hallazgo es informativo.')
        [System.IO.File]::WriteAllText($path, ($sb.ToString() -replace "`r`n","`n"), [System.Text.UTF8Encoding]::new($false))
    }

    hidden [void] WriteDiff([GameConfig] $cfg, [Snapshot] $snap, [object] $prevState, [string] $path) {
        $diff = [ordered]@{
            previousSnapshot = if ($prevState) { $prevState.id } else { $null }
            currentSnapshot  = $snap.Id
            changed          = ($null -ne $prevState -and $prevState.hash -ne $snap.Hash)
            previousHash     = if ($prevState) { $prevState.hash } else { $null }
            currentHash      = $snap.Hash
            deltas           = [ordered]@{
                bindCount   = if ($prevState) { $snap.BindCount   - [int]$prevState.bindCount }   else { $snap.BindCount }
                convarCount = if ($prevState) { $snap.ConvarCount - [int]$prevState.convarCount } else { $snap.ConvarCount }
                aliasCount  = if ($prevState) { $snap.AliasCount  - [int]$prevState.aliasCount }  else { $snap.AliasCount }
            }
        }
        $this.WriteJson($diff, $path)
    }
}
