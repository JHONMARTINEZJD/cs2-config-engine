<#
.SYNOPSIS
    Interpreta el arbol VDF de un archivo .vcfg y produce objetos Setting.
.DESCRIPTION
    Recorre el arbol de forma generica. Heuristicas tolerantes:
      - Un nodo hoja (clave + valor) dentro de un ancestro cuyo nombre contiene
        "bind" se interpreta como BIND (tecla -> comando) o ANALOGBIND.
      - El resto de nodos hoja son CONVARS.
      - Los bloques estructurales (keyboard, mouse, etc.) se conservan como
        contexto y nunca se descartan.
    Cada Setting conserva archivo, linea y texto crudo de origen.
#>

Set-StrictMode -Version Latest

class VcfgParser {
    [string] Name() { return 'VcfgParser' }

    [bool] CanParse([DiscoveredFile] $file) {
        return $file.Kind -eq 'vcfg' -or $file.Kind -eq 'vdf'
    }

    [System.Collections.Generic.List[Setting]] Parse([DiscoveredFile] $file, [Logger] $log) {
        $settings = [System.Collections.Generic.List[Setting]]::new()
        $text = ''
        try {
            $text = Get-Content -LiteralPath $file.Path -Raw -Encoding utf8
        } catch {
            $log.Warn("No se pudo leer $($file.Name): $($_.Exception.Message)")
            return $settings
        }

        $parser = [VdfParser]::new()
        $root   = $parser.Parse($text)
        $this.Walk($root, @(), $file, $log, $settings)
        $log.Debug("$($file.Name): $($settings.Count) ajustes extraidos")
        return $settings
    }

    hidden [void] Walk([VdfNode] $node, [string[]] $path, [DiscoveredFile] $file,
                       [Logger] $log, [System.Collections.Generic.List[Setting]] $acc) {
        foreach ($child in $node.Children) {
            if ($child.IsBlock) {
                $newPath = $path + $child.Key
                $this.Walk($child, $newPath, $file, $log, $acc)
                continue
            }

            # Nodo hoja con valor -> Setting
            if ([string]::IsNullOrWhiteSpace($child.Key)) { continue }

            $isBindCtx = ($path -join '/') -match '(?i)bind'
            $setting = $null
            if ($isBindCtx) {
                $setting = $this.NewBind($child, $path, $file)
            } else {
                $setting = $this.NewConvar($child, $file)
            }
            $acc.Add($setting)
        }
    }

    hidden [Setting] NewBind([VdfNode] $node, [string[]] $path, [DiscoveredFile] $file) {
        $isAnalog = ($path -join '/') -match '(?i)analog'
        # En .vcfg de teclas, la clave es la tecla fisica y el valor el comando.
        $s = [Setting]::new('bind', $node.Value)
        $s.Type  = if ($isAnalog) { [SettingType]::AnalogBind } else { [SettingType]::Bind }
        $s.Extra['Key']     = $node.Key
        $s.Extra['Command'] = $node.Value
        $s.Extra['Context'] = ($path -join '/')
        $s.Metadata.SourceFile = $file.Path
        $s.Metadata.SourceLine = $node.Line
        $s.Metadata.RawLine    = '"{0}"  "{1}"' -f $node.Key, $node.Value
        $s.Metadata.Hash       = Get-StringHash -Text ("{0}={1}" -f $node.Key, $node.Value)
        return $s
    }

    hidden [Setting] NewConvar([VdfNode] $node, [DiscoveredFile] $file) {
        $s = [Setting]::new($node.Key, $node.Value)
        $s.Type = $this.InferType($node.Value)
        $s.Metadata.SourceFile = $file.Path
        $s.Metadata.SourceLine = $node.Line
        $s.Metadata.RawLine    = '"{0}"  "{1}"' -f $node.Key, $node.Value
        $s.Metadata.Hash       = Get-StringHash -Text ("{0}={1}" -f $node.Key, $node.Value)
        return $s
    }

    hidden [SettingType] InferType([string] $value) {
        if ($null -eq $value) { return [SettingType]::String }
        $v = $value.Trim()
        if ($v -eq '0' -or $v -eq '1') { return [SettingType]::Bool }
        if ($v -match '^-?\d+$')        { return [SettingType]::Integer }
        if ($v -match '^-?\d*\.\d+$')   { return [SettingType]::Float }
        return [SettingType]::String
    }
}
