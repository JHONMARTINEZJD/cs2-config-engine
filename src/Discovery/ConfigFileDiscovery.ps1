<#
.SYNOPSIS
    Descubre TODOS los archivos de configuracion relevantes de CS2.
.DESCRIPTION
    No usa una lista cerrada. Recorre recursivamente las raices de busqueda y
    captura cualquier archivo cuya extension o nombre encaje con los patrones de
    configuracion conocidos, dejando margen para incorporaciones futuras de Valve.

    Filosofia: "Si el juego lo guarda, la herramienta lo debe respaldar."
#>

Set-StrictMode -Version Latest

class DiscoveredFile {
    [string] $Path
    [string] $Name
    [string] $Kind        # vcfg | cfg | vdf | unknown
    [long]   $Size
    [string] $Hash
}

class ConfigFileDiscovery {
    hidden [Logger] $Log

    # Extensiones consideradas configuracion. Ampliable.
    # .txt queda fuera a proposito: bajo 730\local no hay configuracion de
    # consola en .txt, solo notas y volcados, y sus claves acababan emitidas
    # como comandos en el autoexec. Un .txt concreto se puede incorporar
    # anadiendolo a $KnownNames.
    static [string[]] $Extensions = @('.vcfg', '.cfg', '.vdf')

    # Nombres prioritarios conocidos (orden de relevancia para el merge).
    static [string[]] $KnownNames = @(
        'cs2_user_convars.vcfg',
        'cs2_user_keys.vcfg',
        'user_convars.vcfg',
        'user_keys.vcfg',
        'config.cfg',
        'autoexec.cfg'
    )

    ConfigFileDiscovery([Logger] $log) { $this.Log = $log }

    [DiscoveredFile[]] Discover([string[]] $searchRoots) {
        $found = [System.Collections.Generic.Dictionary[string, DiscoveredFile]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($root in $searchRoots) {
            if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
            $items = Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                if (-not $this.IsConfigFile($item)) { continue }
                if ($found.ContainsKey($item.FullName)) { continue }

                $df = [DiscoveredFile]::new()
                $df.Path = $item.FullName
                $df.Name = $item.Name
                $df.Kind = $this.ClassifyKind($item.Name)
                $df.Size = $item.Length
                $df.Hash = Get-FileHashSafe -Path $item.FullName
                $found[$item.FullName] = $df
            }
        }

        $result = $this.SortByRelevance($found.Values)
        $this.Log.Info("Archivos de configuracion descubiertos: $($result.Count)")
        foreach ($f in $result) { $this.Log.Debug("  -> $($f.Name)  [$($f.Kind)]  $($f.Size) bytes") }
        return $result
    }

    hidden [bool] IsConfigFile([System.IO.FileInfo] $item) {
        $ext = $item.Extension.ToLowerInvariant()
        if ([ConfigFileDiscovery]::Extensions -contains $ext) { return $true }
        if ([ConfigFileDiscovery]::KnownNames -contains $item.Name.ToLowerInvariant()) { return $true }
        return $false
    }

    hidden [string] ClassifyKind([string] $name) {
        $lower = $name.ToLowerInvariant()
        if ($lower.EndsWith('.vcfg')) { return 'vcfg' }
        if ($lower.EndsWith('.cfg'))  { return 'cfg' }
        if ($lower.EndsWith('.vdf'))  { return 'vdf' }
        return 'unknown'
    }

    <#
        Los archivos conocidos van primero y en su orden; el resto, alfabetico.

        Importa mas de lo que parece: de este orden depende cual de dos valores
        duplicados gana la deduplicacion en SyncEngine, asi que se compara de
        forma ORDINAL y no con Sort-Object, que cotejaria segun la cultura
        activa. El indice se rellena a 4 digitos para que 2 no quede antes de 10.
    #>
    hidden [DiscoveredFile[]] SortByRelevance([System.Collections.Generic.ICollection[DiscoveredFile]] $files) {
        $known = [ConfigFileDiscovery]::KnownNames
        $ordenados = Sort-OrdinalBy -Items @($files) -KeySelector {
            param($f)
            $idx = [array]::IndexOf($known, $f.Name.ToLowerInvariant())
            if ($idx -lt 0) { $idx = 1000 }
            Join-OrdinalKey -Parts @($idx.ToString('D4'), $f.Name)
        }
        return [DiscoveredFile[]]$ordenados
    }
}
