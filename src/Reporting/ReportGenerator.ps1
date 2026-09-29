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

    El diff por setting lo calcula ConfigDiffEngine (Reporting/ConfigDiff.ps1);
    aqui solo se serializa. ConfigDiff.json conserva intacto el nodo de hashes y
    conteos que ya publicaba y anade `settingDiff` al lado, de modo que cualquier
    consumidor existente del archivo sigue funcionando.
#>

Set-StrictMode -Version Latest

class ReportGenerator {
    hidden [Logger] $Log

    <#
        Tope de filas por tabla de diff en BackupReport.md. El reporte legible no
        es la fuente de la verdad: la lista completa siempre esta en
        ConfigDiff.json, asi que se corta para que un cambio masivo (por ejemplo
        una actualizacion del catalogo de fallbacks) no haga ilegible el informe.
        Al estar las entradas ya ordenadas, el corte es determinista.
    #>
    static [int] $DiffRowLimit = 50

    ReportGenerator([Logger] $log) { $this.Log = $log }

    [void] GenerateAll([GameConfig] $cfg, [Snapshot] $snap, [DiscoveredFile[]] $files,
                       [System.Collections.Generic.List[ValidationIssue]] $issues,
                       [object] $prevState, [string] $prevInventoryPath) {
        $dir = $snap.Path
        $this.WriteManifest($cfg, $snap, $files, (Join-Path $dir 'Manifest.json'))
        $this.WriteInventory($cfg, (Join-Path $dir 'Inventory.json'))
        $this.WriteHashes($cfg, $files, (Join-Path $dir 'Hashes.json'))
        $stats = $this.BuildStatistics($cfg, $issues)
        $this.WriteJson($stats, (Join-Path $dir 'BackupStatistics.json'))

        # Un solo calculo del diff alimenta el JSON y el Markdown, para que no
        # puedan contradecirse.
        $prevId = if ($prevState) { [string]$this.PrevProp($prevState, 'id') } else { '' }
        $diff   = [ConfigDiffEngine]::new($this.Log).Compare($cfg, $snap.Id, $prevId, $prevInventoryPath)

        $this.WriteBackupReportJson($cfg, $snap, $stats, $issues, (Join-Path $dir 'BackupReport.json'))
        $this.WriteBackupReportMd($cfg, $snap, $stats, $issues, $diff, (Join-Path $dir 'BackupReport.md'))
        $this.WriteDiff($snap, $prevState, $diff, (Join-Path $dir 'ConfigDiff.json'))
        $this.Log.Info("Reportes generados en $dir")
    }

    <#
        Lectura tolerante de un campo del historial. history.json puede venir de
        una version anterior del motor o haber quedado a medias, y con
        Set-StrictMode acceder a una propiedad inexistente seria terminante.
    #>
    hidden [object] PrevProp([object] $prevState, [string] $name) {
        if ($null -eq $prevState) { return $null }
        $p = $prevState.PSObject.Properties[$name]
        if ($null -eq $p) { return $null }
        return $p.Value
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
            # rawName hace explicito con que nombre quedo la copia en raw/, que
            # UniquePath pudo haber desambiguado con un sufijo `_N`. Sin el, el
            # restore reconstruye el emparejamiento por orden, que es implicito.
            files      = @($files | ForEach-Object {
                $rawName = if ($snap.RawNames.Contains($_.Path)) { [string]$snap.RawNames[$_.Path] } else { '' }
                [ordered]@{
                    name = $_.Name; path = $_.Path; kind = $_.Kind
                    size = $_.Size; hash = $_.Hash; rawName = $rawName
                }
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
                                      [System.Collections.Generic.List[ValidationIssue]] $issues,
                                      [ConfigDiffResult] $diff, [string] $path) {
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
        $this.AppendDiffSection($sb, $diff)
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

    <#
        Seccion legible del diff. Si no hay base de comparacion lo dice con
        claridad en lugar de mostrar tablas vacias o deltas inventados.
    #>
    hidden [void] AppendDiffSection([System.Text.StringBuilder] $sb, [ConfigDiffResult] $diff) {
        [void]$sb.AppendLine('## Cambios frente al snapshot anterior')
        [void]$sb.AppendLine('')

        if (-not $diff.HasBaseline) {
            if ($diff.PreviousSnapshotId) {
                [void]$sb.AppendLine("**Sin base de comparacion.** Existe un snapshot anterior (``$($diff.PreviousSnapshotId)``) pero su inventario no se pudo usar: $($diff.BaselineWarning)")
                [void]$sb.AppendLine('')
                [void]$sb.AppendLine('No se reportan altas, bajas ni cambios porque no hay con que compararlos. El inventario de este snapshot queda completo y servira de base para el siguiente.')
            } else {
                [void]$sb.AppendLine('**Sin base de comparacion.** Este es el primer snapshot registrado: no hay snapshot anterior contra el que comparar, asi que no hay altas, bajas ni cambios que mostrar.')
            }
            [void]$sb.AppendLine('')
            return
        }

        [void]$sb.AppendLine("- Snapshot anterior: ``$($diff.PreviousSnapshotId)`` ($($diff.PreviousTotal) claves)")
        [void]$sb.AppendLine("- Snapshot actual: ``$($diff.CurrentSnapshotId)`` ($($diff.CurrentTotal) claves)")
        [void]$sb.AppendLine("- Anadidas: **$($diff.Added.Count)** | Eliminadas: **$($diff.Removed.Count)** | Cambiadas: **$($diff.Modified.Count)** | Sin cambios: **$($diff.Unchanged)**")
        [void]$sb.AppendLine('')

        if ($diff.TotalChanges() -eq 0) {
            [void]$sb.AppendLine('La configuracion es identica a la del snapshot anterior.')
            [void]$sb.AppendLine('')
            return
        }

        if ($diff.Modified.Count -gt 0) {
            [void]$sb.AppendLine('### Cambiadas')
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('| Clave | Categoria | Antes | Despues | Campos |')
            [void]$sb.AppendLine('| --- | --- | --- | --- | --- |')
            $this.AppendDiffRows($sb, $diff.Modified, {
                param($e)
                '| `{0}` | {1} - {2} | `{3}` | `{4}` | {5} |' -f $e['key'], $e['category'], $e['categoryName'],
                    $e['previousValue'], $e['currentValue'], (@($e['fields']) -join ', ')
            })
        }

        foreach ($pair in @(@('Anadidas', $diff.Added), @('Eliminadas', $diff.Removed))) {
            $title   = [string]$pair[0]
            $entries = $pair[1]
            if ($entries.Count -eq 0) { continue }
            [void]$sb.AppendLine("### $title")
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('| Clave | Categoria | Tipo | Valor |')
            [void]$sb.AppendLine('| --- | --- | --- | --- |')
            $this.AppendDiffRows($sb, $entries, {
                param($e)
                '| `{0}` | {1} - {2} | {3} | `{4}` |' -f $e['key'], $e['category'], $e['categoryName'],
                    $e['type'], $e['value']
            })
        }
    }

    # Emite las filas de una tabla de diff respetando el tope y avisando del corte.
    hidden [void] AppendDiffRows([System.Text.StringBuilder] $sb,
                                 [System.Collections.Generic.List[object]] $entries,
                                 [scriptblock] $formatter) {
        $limit = [ReportGenerator]::DiffRowLimit
        $n     = [Math]::Min($limit, $entries.Count)
        for ($i = 0; $i -lt $n; $i++) {
            [void]$sb.AppendLine([string](& $formatter $entries[$i]))
        }
        if ($entries.Count -gt $limit) {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine("> Se muestran las primeras $limit de $($entries.Count) entradas. La lista completa esta en ``ConfigDiff.json``.")
        }
        [void]$sb.AppendLine('')
    }

    <#
        ConfigDiff.json. Las claves de la primera version (previousSnapshot,
        currentSnapshot, changed, previousHash, currentHash, deltas) se mantienen
        tal cual para no romper a nadie que ya las lea; `settingDiff` se anade al
        final con el diff real por setting.
    #>
    hidden [void] WriteDiff([Snapshot] $snap, [object] $prevState, [ConfigDiffResult] $diff, [string] $path) {
        $prevHash   = [string]$this.PrevProp($prevState, 'hash')
        $prevBind   = [int]$this.PrevProp($prevState, 'bindCount')
        $prevConvar = [int]$this.PrevProp($prevState, 'convarCount')
        $prevAlias  = [int]$this.PrevProp($prevState, 'aliasCount')

        $out = [ordered]@{
            previousSnapshot = if ($prevState) { [string]$this.PrevProp($prevState, 'id') } else { $null }
            currentSnapshot  = $snap.Id
            changed          = ($null -ne $prevState -and $prevHash -ne $snap.Hash)
            previousHash     = if ($prevState) { $prevHash } else { $null }
            currentHash      = $snap.Hash
            deltas           = [ordered]@{
                bindCount   = if ($prevState) { $snap.BindCount   - $prevBind }   else { $snap.BindCount }
                convarCount = if ($prevState) { $snap.ConvarCount - $prevConvar } else { $snap.ConvarCount }
                aliasCount  = if ($prevState) { $snap.AliasCount  - $prevAlias }  else { $snap.AliasCount }
            }
            settingDiff      = $diff.ToHashtable()
        }
        $this.WriteJson($out, $path)
    }
}
