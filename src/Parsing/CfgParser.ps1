<#
.SYNOPSIS
    Parser de archivos .cfg basados en comandos de consola (config.cfg, autoexec.cfg).
.DESCRIPTION
    Usa el Tokenizer para dividir cada linea logica en argumentos respetando
    comillas y comentarios. Reconoce:
      - bind / bind_osx        -> Bind
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
            $raw    = $lines[$i]
            $lineNo = $i + 1
            $tokens = $this.SplitArgs($raw)
            if ($tokens.Length -eq 0) { continue }

            $cmd = $tokens[0].ToLowerInvariant()
            $setting = switch -Regex ($cmd) {
                '^bind(_osx)?$' { $this.NewBind($tokens,  $file, $lineNo, $raw) }
                '^alias$'       { $this.NewAlias($tokens, $file, $lineNo, $raw) }
                default         { $this.NewConvar($tokens, $file, $lineNo, $raw) }
            }

            if ($null -ne $setting) { $settings.Add($setting) }
        }
        $log.Debug("$($file.Name): $($settings.Count) ajustes extraidos")
        return $settings
    }

    # Divide una linea en argumentos usando el tokenizer (respeta comillas/comentarios).
    hidden [string[]] SplitArgs([string] $line) {
        if ([string]::IsNullOrWhiteSpace($line)) { return @() }
        $lexer  = [Tokenizer]::new($line)
        $tokens = $lexer.Tokenize()
        $parts  = [System.Collections.Generic.List[string]]::new()
        foreach ($t in $tokens) {
            if ($t.Kind -eq [TokenKind]::String) { $parts.Add($t.Text) }
            # Se ignoran comentarios y llaves a nivel de linea de comando.
        }
        return $parts.ToArray()
    }

    # Une los argumentos desde $from en adelante en un solo valor.
    hidden [string] JoinFrom([string[]] $tokens, [int] $from) {
        if ($null -eq $tokens -or $from -ge $tokens.Length) { return '' }
        $parts = [System.Collections.Generic.List[string]]::new()
        for ($i = $from; $i -lt $tokens.Length; $i++) { $parts.Add([string]$tokens[$i]) }
        return ($parts -join ' ')
    }

    hidden [Setting] NewBind([string[]] $tokens, [DiscoveredFile] $file, [int] $line, [string] $raw) {
        # "bind" sin tecla no es un bind: se conserva como comando suelto.
        if ($tokens.Length -lt 2) { return $this.NewConvar($tokens, $file, $line, $raw) }

        $key     = [string]$tokens[1]
        $command = $this.JoinFrom($tokens, 2)

        $s = [Setting]::new('bind', $command)
        $s.Type = [SettingType]::Bind
        $s.Extra['Key']     = $key
        $s.Extra['Command'] = $command
        $this.Stamp($s, $file, $line, $raw, ("bind:{0}={1}" -f $key, $command))
        return $s
    }

    hidden [Setting] NewAlias([string[]] $tokens, [DiscoveredFile] $file, [int] $line, [string] $raw) {
        if ($tokens.Length -lt 2) { return $this.NewConvar($tokens, $file, $line, $raw) }

        $name = [string]$tokens[1]
        $body = $this.JoinFrom($tokens, 2)

        $s = [Setting]::new($name, $body)
        $s.Type = [SettingType]::Alias
        $s.Extra['Body'] = $body
        $this.Stamp($s, $file, $line, $raw, ("alias:{0}={1}" -f $name, $body))
        return $s
    }

    hidden [Setting] NewConvar([string[]] $tokens, [DiscoveredFile] $file, [int] $line, [string] $raw) {
        if ($null -eq $tokens -or $tokens.Length -eq 0) { return $null }

        $name  = [string]$tokens[0]
        $value = $this.JoinFrom($tokens, 1)

        $s = [Setting]::new($name, $value)
        $s.Type = $this.InferType($value)
        $this.Stamp($s, $file, $line, $raw, ("{0}={1}" -f $name, $value))
        return $s
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
