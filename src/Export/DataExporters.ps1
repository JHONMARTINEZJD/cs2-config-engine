<#
.SYNOPSIS
    Exportadores de datos independientes: JSON, Markdown, YAML, CSV.
.DESCRIPTION
    Cada exportador es una clase autonoma (responsabilidad unica) con la misma
    interfaz informal: Name() y Export([GameConfig], [string] $outPath, [Logger]).
    Agregar un nuevo formato no afecta a los demas.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
class JsonExporter {
    [string] Name() { return 'json' }

    [void] Export([GameConfig] $cfg, [string] $outPath, [Logger] $log) {
        $model = [ordered]@{
            steamId    = $cfg.SteamId
            steamPath  = $cfg.SteamPath
            cs2Path    = $cfg.CS2Path
            cfgPath    = $cfg.CfgPath
            capturedAt = $cfg.CapturedAt.ToString('o')
            total      = $cfg.TotalSettings()
            categories = @()
        }
        foreach ($cat in $cfg.Categories) {
            $model.categories += [ordered]@{
                code     = $cat.Code
                name     = $cat.Name
                count    = $cat.Count()
                settings = @($cat.Settings | ForEach-Object { $_.ToHashtable() })
            }
        }
        $json = $model | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($outPath, $json, [System.Text.UTF8Encoding]::new($false))
        $log.Info("Exportado JSON: $outPath")
    }
}

# ---------------------------------------------------------------------------
class MarkdownExporter {
    [string] Name() { return 'markdown' }

    [void] Export([GameConfig] $cfg, [string] $outPath, [Logger] $log) {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('# CS2 Configuration Snapshot')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("- **SteamID:** $($cfg.SteamId)")
        [void]$sb.AppendLine("- **Capturado:** $($cfg.CapturedAt.ToString('u'))")
        [void]$sb.AppendLine("- **Total de ajustes:** $($cfg.TotalSettings())")
        [void]$sb.AppendLine('')

        foreach ($cat in $cfg.Categories) {
            if ($cat.Count() -eq 0) { continue }
            [void]$sb.AppendLine("## $($cat.Code) - $($cat.Name)")
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('| Variable | Valor | Tipo | Estado | Origen |')
            [void]$sb.AppendLine('| --- | --- | --- | --- | --- |')
            foreach ($s in $cat.Settings) {
                $name   = $this.Escape($s.Name)
                $value  = $this.Escape($s.Value)
                $origin = if ($s.Metadata.SourceFile) { Split-Path -Leaf $s.Metadata.SourceFile } else { '' }
                [void]$sb.AppendLine("| $name | $value | $($s.Type) | $($s.State) | $origin |")
            }
            [void]$sb.AppendLine('')
        }
        [System.IO.File]::WriteAllText($outPath, ($sb.ToString() -replace "`r`n","`n"), [System.Text.UTF8Encoding]::new($false))
        $log.Info("Exportado Markdown: $outPath")
    }

    hidden [string] Escape([string] $t) {
        if ($null -eq $t) { return '' }
        return ($t -replace '\|', '\|')
    }
}

# ---------------------------------------------------------------------------
class YamlExporter {
    [string] Name() { return 'yaml' }

    [void] Export([GameConfig] $cfg, [string] $outPath, [Logger] $log) {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("steamId: `"$($cfg.SteamId)`"")
        [void]$sb.AppendLine("capturedAt: `"$($cfg.CapturedAt.ToString('o'))`"")
        [void]$sb.AppendLine("total: $($cfg.TotalSettings())")
        [void]$sb.AppendLine('categories:')
        foreach ($cat in $cfg.Categories) {
            [void]$sb.AppendLine("  - code: `"$($cat.Code)`"")
            [void]$sb.AppendLine("    name: `"$($cat.Name)`"")
            [void]$sb.AppendLine("    count: $($cat.Count())")
            [void]$sb.AppendLine('    settings:')
            foreach ($s in $cat.Settings) {
                [void]$sb.AppendLine("      - name: `"$($this.Y($s.Name))`"")
                [void]$sb.AppendLine("        value: `"$($this.Y($s.Value))`"")
                [void]$sb.AppendLine("        type: `"$($s.Type)`"")
                [void]$sb.AppendLine("        state: `"$($s.State)`"")
                [void]$sb.AppendLine("        category: `"$($s.CategoryCode)`"")
            }
        }
        [System.IO.File]::WriteAllText($outPath, ($sb.ToString() -replace "`r`n","`n"), [System.Text.UTF8Encoding]::new($false))
        $log.Info("Exportado YAML: $outPath")
    }

    hidden [string] Y([string] $t) {
        if ($null -eq $t) { return '' }
        return ($t -replace '"', '\"')
    }
}

# ---------------------------------------------------------------------------
class CsvExporter {
    [string] Name() { return 'csv' }

    [void] Export([GameConfig] $cfg, [string] $outPath, [Logger] $log) {
        $rows = foreach ($cat in $cfg.Categories) {
            foreach ($s in $cat.Settings) {
                [pscustomobject]@{
                    Category    = $cat.Code
                    CategoryName= $cat.Name
                    Name        = $s.Name
                    Value       = $s.Value
                    Type        = $s.Type
                    Priority    = $s.Priority
                    State       = $s.State
                    Key         = if ($s.Extra.ContainsKey('Key')) { $s.Extra['Key'] } else { '' }
                    SourceFile  = $s.Metadata.SourceFile
                    SourceLine  = $s.Metadata.SourceLine
                    Hash        = $s.Metadata.Hash
                }
            }
        }
        $rows | Export-Csv -LiteralPath $outPath -NoTypeInformation -Encoding utf8
        $log.Info("Exportado CSV: $outPath")
    }
}
