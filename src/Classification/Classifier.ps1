<#
.SYNOPSIS
    Clasificador granular de settings en categorias P00..P49.
.DESCRIPTION
    Carga reglas regex desde config/classification-rules.json y asigna a cada
    Setting su CategoryCode. Reglas evaluadas en orden; gana la primera.
    Binds/alias se enrutan por su comando objetivo. Lo no clasificable se asigna
    a P48 (Unknown Commands) o P49 (Future Commands) pero NUNCA se descarta.
#>

Set-StrictMode -Version Latest

class ClassificationRule {
    [string] $Category
    [regex]  $Pattern
}

class Classifier {
    hidden [Logger] $Log
    hidden [System.Collections.Generic.List[ClassificationRule]] $Rules

    Classifier([Logger] $log, [string] $rulesPath) {
        $this.Log   = $log
        $this.Rules = [System.Collections.Generic.List[ClassificationRule]]::new()
        $this.LoadRules($rulesPath)
    }

    hidden [void] LoadRules([string] $rulesPath) {
        if (-not (Test-Path -LiteralPath $rulesPath)) {
            $this.Log.Warn("No se encontro $rulesPath; clasificacion limitada.")
            return
        }
        try {
            $json = Get-Content -LiteralPath $rulesPath -Raw -Encoding utf8 | ConvertFrom-Json
            foreach ($r in $json.rules) {
                $rule = [ClassificationRule]::new()
                $rule.Category = $r.category
                $rule.Pattern  = [regex]::new($r.pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                $this.Rules.Add($rule)
            }
            $this.Log.Info("Reglas de clasificacion cargadas: $($this.Rules.Count)")
        } catch {
            $this.Log.Error("Error cargando reglas: $($_.Exception.Message)")
        }
    }

    [void] ClassifyAll([System.Collections.Generic.List[Setting]] $settings) {
        foreach ($s in $settings) {
            $s.CategoryCode = $this.Classify($s)
        }
    }

    hidden [string] Classify([Setting] $s) {
        # Texto sobre el que decidir: para binds usamos el comando objetivo.
        $subject = switch ($s.Type) {
            ([SettingType]::Bind)       { ('{0} {1}' -f $s.Name, $s.Extra['Command']) }
            ([SettingType]::AnalogBind) { ('{0} {1}' -f $s.Name, $s.Extra['Command']) }
            ([SettingType]::Alias)      { ('{0} {1}' -f $s.Name, ($s.Extra['Body'])) }
            default                     { $s.Name }
        }

        foreach ($rule in $this.Rules) {
            if ($rule.Pattern.IsMatch($subject)) { return $rule.Category }
        }

        # Sin coincidencia: distinguir "desconocido actual" vs "posible futuro".
        if ($s.Name -match '^[a-z0-9_]+$') { return 'P49' }  # parece convar valida -> futuro
        return 'P48'
    }
}
