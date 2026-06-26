<#
.SYNOPSIS
    Selector de parser por archivo (patron Strategy / Factory).
.DESCRIPTION
    Cada parser es independiente y se registra aqui. Permite agregar nuevos
    formatos sin modificar el resto del sistema (principio abierto/cerrado).
    Devuelve el primer parser cuyo CanParse() acepte el archivo.
#>

Set-StrictMode -Version Latest

class ParserFactory {
    hidden [System.Collections.Generic.List[object]] $Parsers
    hidden [Logger] $Log

    ParserFactory([Logger] $log) {
        $this.Log = $log
        $this.Parsers = [System.Collections.Generic.List[object]]::new()
        # Orden de preferencia: VCFG primero, CFG despues.
        $this.Register([VcfgParser]::new())
        $this.Register([CfgParser]::new())
    }

    [void] Register([object] $parser) {
        $this.Parsers.Add($parser)
    }

    [object] ResolveFor([DiscoveredFile] $file) {
        foreach ($p in $this.Parsers) {
            if ($p.CanParse($file)) { return $p }
        }
        return $null
    }

    # Parsea un conjunto de archivos y devuelve todos los settings encontrados.
    [System.Collections.Generic.List[Setting]] ParseAll([DiscoveredFile[]] $files) {
        $all = [System.Collections.Generic.List[Setting]]::new()
        foreach ($file in $files) {
            $parser = $this.ResolveFor($file)
            if ($null -eq $parser) {
                $this.Log.Warn("Sin parser para $($file.Name); se omite el contenido pero se registra el archivo.")
                continue
            }
            $this.Log.Debug("Parseando $($file.Name) con $($parser.Name())")
            $settings = $parser.Parse($file, $this.Log)
            foreach ($s in $settings) { $all.Add($s) }
        }
        return $all
    }
}
