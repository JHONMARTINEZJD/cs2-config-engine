<#
.SYNOPSIS
    Parser de archivos .cfg basados en comandos de consola (config.cfg, autoexec.cfg).
.DESCRIPTION
    Usa el Tokenizer para dividir cada linea logica en argumentos respetando
    comillas y comentarios. Reconoce:
      - bind / bind_osx        -> Bind
      - +/-analog / bind con eje-> AnalogBind (heuristica)
      - alias                  -> Alias
      - cualquier otro "cmd arg" -> Convar
    Tolerante: comandos desconocidos se conservan como Convar/Unknown.
#>

Set-StrictMode -Version Latest

class CfgParser {
    [string] Name() { return 'CfgParser' }

    [bool] CanParse([DiscoveredFile] $file) {
        return $file.Kind -eq 'cfg' -or ($file.Kind -eq 'unknown' -and $file.Name -like '*.cfg')
    }

    [System.Collections.Generic.List[Setting]] Parse([DiscoveredFile] $file, [Logger] $log) {
        $settings = [System.Collections.Generic.List[Setting]]::new()
        $lines = @()
        try {
            $lines = @(Get-Content -LiteralPath $file.Path -Encoding utf8)
        } catch {
            $log.Warn("No se pudo leer $($file.Name): $($_.Exception.Message)")
            return $settings
        }

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $raw = $lines[$i]
            $lineNo = $i + 1
            $args = $this.SplitArgs($raw)
            if ($args.Count -eq 0) { continue }

            $cmd = $args[0]
            $cmdLower = $cmd.ToLowerInvariant()

            $setting = $null
            if ($cmdLower -match '^bind(_osx)?$') {
                if ($args.Length -ge 2) {
                    $key = [string]$args[1]
                    $parts = [System.Collections.Generic.List[string]]::new()
                    for ($j = 2; $j -lt $args.Length; $j++) { $parts.Add([string]$args[$j]) }
                    $command = if ($parts.Count -gt 0) { $parts -join ' ' } else { '' }
                    $setting = [Setting]::new('bind', $command)
                    $setting.Type = [SettingType]::Bind
                    $setting.Extra['Key'] = $key
                    $setting.Extra['Command'] = $command
                }
            } elseif ($cmdLower -match '^alias$') {
                if ($args.Length -ge 2) {
                    $name = [string]$args[1]
                    $parts = [System.Collections.Generic.List[string]]::new()
                    for ($j = 2; $j -lt $args.Length; $j++) { $parts.Add([string]$args[$j]) }
                    $body = if ($parts.Count -gt 0) { $parts -join ' ' } else { '' }
                    $setting = [Setting]::new($name, $body)
                    $setting.Type = [SettingType]::Alias
                    $setting.Extra['Body'] = $body
                }
            } else {
                $name = [string]$args[0]
                $parts = [System.Collections.Generic.List[string]]::new()
                for ($j = 1; $j -lt $args.Length; $j++) { $parts.Add([string]$args[$j]) }
                $value = if ($parts.Count -gt 0) { $parts -join ' ' } else { '' }
                $setting = [Setting]::new($name, $value)
                $setting.Type = $this.InferType($value)
            }

            if ($null -ne $setting) {
                $setting.Metadata.SourceFile = $file.Path
                $setting.Metadata.SourceLine = $lineNo
                $setting.Metadata.RawLine = $raw.Trim()
                $setting.Metadata.Hash = Get-StringHash -Text ("{0}={1}" -f $setting.Name, $setting.Value)
                $settings.Add($setting)
            }
        }
        $log.Debug("$($file.Name): $($settings.Count) ajustes extraidos")
        return $settings
    }

    # Divide una linea en argumentos usando el tokenizer (respeta comillas/comentarios).
    hidden [string[]] SplitArgs([string] $line) {
        if ([string]::IsNullOrWhiteSpace($line)) { return @() }
        $lexer  = [Tokenizer]::new($line)
        $tokens = $lexer.Tokenize()
        $args   = [System.Collections.Generic.List[string]]::new()
        foreach ($t in $tokens) {
            if ($t.Kind -eq [TokenKind]::String) { $args.Add($t.Text) }
            # Se ignoran comentarios y llaves a nivel de linea de comando.
        }
        return $args.ToArray()
    }

    hidden [Setting] NewBind([string[]] $args, [DiscoveredFile] $file, [int] $line, [string] $raw) {
        if ($null -eq $args -or $args.Length -lt 2) { return $this.NewConvar($args, $file, $line, $raw) }

        $key = [string]$args[1]
        $parts = [System.Collections.Generic.List[string]]::new()
        for ($i = 2; $i -lt $args.Length; $i++) { $parts.Add([string]$args[$i]) }
        $command = if ($parts.Count -gt 0) { $parts -join ' ' } else { '' }

        $s = [Setting]::new('bind', $command)
        $s.Type = [SettingType]::Bind
        $s.Extra['Key']     = $key
        $s.Extra['Command'] = $command
        $this.Stamp($s, $file, $line, $raw, ("bind:{0}={1}" -f $key, $command))
        return [Setting]$s
    }

    hidden [Setting] NewAlias([string[]] $args, [DiscoveredFile] $file, [int] $line, [string] $raw) {
        if ($null -eq $args -or $args.Length -lt 2) { return $this.NewConvar($args, $file, $line, $raw) }

        $name = [string]$args[1]
        $parts = [System.Collections.Generic.List[string]]::new()
        for ($i = 2; $i -lt $args.Length; $i++) { $parts.Add([string]$args[$i]) }
        $body = if ($parts.Count -gt 0) { $parts -join ' ' } else { '' }

        $s = [Setting]::new($name, $body)
        $s.Type = [SettingType]::Alias
        $s.Extra['Body'] = $body
        $this.Stamp($s, $file, $line, $raw, ("alias:{0}={1}" -f $name, $body))
        return [Setting]$s
    }

    hidden [Setting] NewConvar([string[]] $args, [DiscoveredFile] $file, [int] $line, [string] $raw) {
        if ($null -eq $args -or $args.Length -eq 0) { return $null }

        $name = [string]$args[0]
        $parts = [System.Collections.Generic.List[string]]::new()
        for ($i = 1; $i -lt $args.Length; $i++) { $parts.Add([string]$args[$i]) }
        $value = if ($parts.Count -gt 0) { $parts -join ' ' } else { '' }

        $s = [Setting]::new($name, $value)
        $s.Type = $this.InferType($value)
        $this.Stamp($s, $file, $line, $raw, ("{0}={1}" -f $name, $value))
        return [Setting]$s
    }

    hidden [void] Stamp([Setting] $s, [DiscoveredFile] $file, [int] $line, [string] $raw, [string] $hashSeed) {
        $s.Metadata.SourceFile = $file.Path
        $s.Metadata.SourceLine = $line
        $s.Metadata.RawLine    = $raw.Trim()
        $s.Metadata.Hash       = Get-StringHash -Text $hashSeed
    }

    hidden [SettingType] InferType([string] $value) {
        if ([string]::IsNullOrEmpty($value)) { return [SettingType]::String }
        $v = $value.Trim()
        if ($v -eq '0' -or $v -eq '1') { return [SettingType]::Bool }
        if ($v -match '^-?\d+$')        { return [SettingType]::Integer }
        if ($v -match '^-?\d*\.\d+$')   { return [SettingType]::Float }
        return [SettingType]::String
    }
}
