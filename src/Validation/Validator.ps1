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

    <#
        Detecta ciclos reales en el grafo de alias mediante DFS con pila de
        recursion (blanco / gris / negro).

        La version anterior usaba un unico conjunto "visitado" por raiz, asi que
        un grafo en diamante SIN ciclos (top -> a, b -> base) se reportaba como
        circular: 'base' se alcanzaba dos veces por caminos distintos. Un ciclo
        solo existe cuando se vuelve a un nodo que esta en el camino actual.
    #>
    hidden [void] CheckCircularAliases([Setting[]] $all, [System.Collections.Generic.List[ValidationIssue]] $issues) {
        $aliases = @{}
        foreach ($s in $all) {
            if ($s.Type -eq [SettingType]::Alias) { $aliases[$s.Name.ToLowerInvariant()] = $s }
        }

        # '' = sin visitar, 'open' = en el camino actual, 'closed' = ya resuelto.
        $state  = @{}
        $cycles = [System.Collections.Generic.List[string[]]]::new()

        # Orden estable y ordinal para que el reporte sea determinista: con
        # Sort-Object el orden de los hallazgos dependeria de la cultura.
        foreach ($name in (Sort-OrdinalBy -Items @($aliases.Keys) -KeySelector { param($k) $k })) {
            if ($state.ContainsKey($name)) { continue }
            $this.WalkAliases($name, $aliases, $state, [System.Collections.Generic.List[string]]::new(), $cycles)
        }

        foreach ($cycle in $cycles) {
            $head = $cycle[0]
            $this.Add($issues, [IssueSeverity]::Error, 'CIRCULAR_ALIAS', $aliases[$head],
                "Alias circular detectado: $($cycle -join ' -> ').")
        }
    }

    # Recorre el grafo desde $name acumulando el camino; registra cada ciclo una vez.
    hidden [void] WalkAliases([string] $name, [hashtable] $aliases, [hashtable] $state,
                              [System.Collections.Generic.List[string]] $path,
                              [System.Collections.Generic.List[string[]]] $cycles) {
        $state[$name] = 'open'
        $path.Add($name)

        foreach ($ref in $this.AliasReferences($aliases[$name], $aliases)) {
            if (-not $state.ContainsKey($ref)) {
                $this.WalkAliases($ref, $aliases, $state, $path, $cycles)
            }
            elseif ($state[$ref] -eq 'open') {
                # Cierre de ciclo: recorta el camino desde donde aparece $ref.
                $start = $path.IndexOf($ref)
                $loop  = [System.Collections.Generic.List[string]]::new()
                for ($i = $start; $i -lt $path.Count; $i++) { $loop.Add($path[$i]) }
                $loop.Add($ref)
                $cycles.Add($loop.ToArray())
            }
        }

        $path.RemoveAt($path.Count - 1)
        $state[$name] = 'closed'
    }

    # Alias referenciados en el cuerpo de un alias (ignora comandos normales).
    hidden [string[]] AliasReferences([Setting] $alias, [hashtable] $aliases) {
        $body = if ($alias.Extra.ContainsKey('Body')) { [string]$alias.Extra['Body'] } else { [string]$alias.Value }
        if ([string]::IsNullOrWhiteSpace($body)) { return @() }

        $refs = [System.Collections.Generic.List[string]]::new()
        foreach ($tok in ($body -split '\s*;\s*|\s+')) {
            $t = $tok.Trim().ToLowerInvariant()
            if ($t -and $aliases.ContainsKey($t) -and -not $refs.Contains($t)) { $refs.Add($t) }
        }
        return $refs.ToArray()
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
