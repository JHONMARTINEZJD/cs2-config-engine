<#
.SYNOPSIS
    Validacion no destructiva del GameConfig antes de exportar.
.DESCRIPTION
    Detecta y reporta (NUNCA elimina):
      - comandos duplicados
      - variables invalidas (nombre/valor sospechoso)
      - variables obsoletas
      - binds rotos (sin tecla o sin comando)
      - aliases circulares
      - variables desconocidas (P48/P49)
    Devuelve una lista de ValidationIssue para los reportes.
#>

Set-StrictMode -Version Latest

enum IssueSeverity { Info; Warning; Error }

class ValidationIssue {
    [IssueSeverity] $Severity
    [string]        $Code        # DUPLICATE | INVALID | OBSOLETE | BROKEN_BIND | CIRCULAR_ALIAS | UNKNOWN
    [string]        $Target      # nombre del setting afectado
    [string]        $Message
    [string]        $SourceFile
    [int]           $SourceLine
}

class Validator {
    hidden [Logger] $Log
    Validator([Logger] $log) { $this.Log = $log }

    [System.Collections.Generic.List[ValidationIssue]] Validate([GameConfig] $cfg) {
        $issues = [System.Collections.Generic.List[ValidationIssue]]::new()
        $all = @($cfg.AllSettings())

        $this.CheckDuplicates($all, $issues)
        $this.CheckInvalid($all, $issues)
        $this.CheckObsolete($all, $issues)
        $this.CheckBrokenBinds($all, $issues)
        $this.CheckCircularAliases($all, $issues)
        $this.CheckUnknown($all, $issues)

        $errors   = @($issues | Where-Object { $_.Severity -eq [IssueSeverity]::Error }).Count
        $warnings = @($issues | Where-Object { $_.Severity -eq [IssueSeverity]::Warning }).Count
        $this.Log.Info("Validacion: $($issues.Count) hallazgos ($errors errores, $warnings avisos). No se elimino nada.")
        return $issues
    }

    hidden [void] Add([System.Collections.Generic.List[ValidationIssue]] $list, [IssueSeverity] $sev,
                      [string] $code, [Setting] $s, [string] $msg) {
        $i = [ValidationIssue]::new()
        $i.Severity = $sev
        $i.Code     = $code
        $i.Target   = $s.Name
        $i.Message  = $msg
        $i.SourceFile = $s.Metadata.SourceFile
        $i.SourceLine = $s.Metadata.SourceLine
        $list.Add($i)
    }

    hidden [void] CheckDuplicates([Setting[]] $all, [System.Collections.Generic.List[ValidationIssue]] $issues) {
        foreach ($s in $all) {
            if ($s.State -eq [SettingState]::Duplicated) {
                $this.Add($issues, [IssueSeverity]::Warning, 'DUPLICATE', $s,
                    "Comando duplicado; prevalece el de la configuracion viva de mayor prioridad.")
            }
        }
    }

    hidden [void] CheckInvalid([Setting[]] $all, [System.Collections.Generic.List[ValidationIssue]] $issues) {
        foreach ($s in $all) {
            if ($s.Type -eq [SettingType]::Bind -or $s.Type -eq [SettingType]::AnalogBind -or $s.Type -eq [SettingType]::Alias) { continue }
            if ([string]::IsNullOrWhiteSpace($s.Name)) {
                $this.Add($issues, [IssueSeverity]::Error, 'INVALID', $s, "Nombre de variable vacio.")
                $s.State = [SettingState]::Invalid
            }
            elseif ($s.Name -notmatch '^[A-Za-z_][A-Za-z0-9_\.\+\-]*$') {
                $this.Add($issues, [IssueSeverity]::Warning, 'INVALID', $s,
                    "Nombre de variable con formato inusual: '$($s.Name)'.")
            }
        }
    }

    hidden [void] CheckObsolete([Setting[]] $all, [System.Collections.Generic.List[ValidationIssue]] $issues) {
        foreach ($s in $all) {
            if ($s.State -eq [SettingState]::Obsolete) {
                $this.Add($issues, [IssueSeverity]::Warning, 'OBSOLETE', $s,
                    "Variable marcada como obsoleta/eliminada en versiones recientes; se conserva por seguridad.")
            }
        }
    }

    hidden [void] CheckBrokenBinds([Setting[]] $all, [System.Collections.Generic.List[ValidationIssue]] $issues) {
        foreach ($s in $all) {
            if ($s.Type -ne [SettingType]::Bind -and $s.Type -ne [SettingType]::AnalogBind) { continue }
            $key = if ($s.Extra.ContainsKey('Key')) { $s.Extra['Key'] } else { '' }
            $cmd = if ($s.Extra.ContainsKey('Command')) { $s.Extra['Command'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($cmd)) {
                $this.Add($issues, [IssueSeverity]::Warning, 'BROKEN_BIND', $s,
                    "Bind incompleto (tecla='$key', comando='$cmd').")
            }
        }
    }

    hidden [void] CheckCircularAliases([Setting[]] $all, [System.Collections.Generic.List[ValidationIssue]] $issues) {
        $aliases = @{}
        foreach ($s in $all) {
            if ($s.Type -eq [SettingType]::Alias) { $aliases[$s.Name.ToLowerInvariant()] = $s }
        }
        foreach ($name in $aliases.Keys) {
            $visited = [System.Collections.Generic.HashSet[string]]::new()
            $stack   = [System.Collections.Generic.Stack[string]]::new()
            $stack.Push($name)
            $circular = $false
            while ($stack.Count -gt 0) {
                $cur = $stack.Pop()
                if (-not $visited.Add($cur)) { $circular = $true; break }
                if (-not $aliases.ContainsKey($cur)) { continue }
                $body = [string]$aliases[$cur].Extra['Body']
                foreach ($tok in ($body -split '\s*;\s*|\s+')) {
                    $t = $tok.ToLowerInvariant().Trim()
                    if ($aliases.ContainsKey($t)) { $stack.Push($t) }
                }
            }
            if ($circular) {
                $this.Add($issues, [IssueSeverity]::Error, 'CIRCULAR_ALIAS', $aliases[$name],
                    "Alias circular detectado a partir de '$name'.")
            }
        }
    }

    hidden [void] CheckUnknown([Setting[]] $all, [System.Collections.Generic.List[ValidationIssue]] $issues) {
        foreach ($s in $all) {
            if ($s.CategoryCode -eq 'P48' -or $s.CategoryCode -eq 'P49') {
                $this.Add($issues, [IssueSeverity]::Info, 'UNKNOWN', $s,
                    "Comando no reconocido por el catalogo actual; conservado en $($s.CategoryCode).")
            }
        }
    }
}
