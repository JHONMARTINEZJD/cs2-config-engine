<#
.SYNOPSIS
    Motor de sincronizacion: construye el GameConfig final, determinista.
.DESCRIPTION
    Reglas:
      1. La configuracion viva SIEMPRE tiene prioridad. Los archivos llegan ya
         ordenados por relevancia; el primer valor visto para una Key gana y los
         posteriores se marcan como Duplicated (pero se conservan).
      2. Los fallbacks SOLO se aplican a variables ausentes. Nunca sobrescriben.
      3. Enriquece metadatos (descripcion, default) desde el catalogo.
      4. Agrupa en categorias y ordena de forma determinista para que la misma
         entrada produzca siempre la misma salida.
#>

Set-StrictMode -Version Latest

class FallbackCatalog {
    hidden [hashtable] $Convars       # nameLower -> @{ default; type; description }
    hidden [hashtable] $Deprecated    # nameLower -> $true

    FallbackCatalog([string] $path, [Logger] $log) {
        $this.Convars    = @{}
        $this.Deprecated = @{}
        if (-not (Test-Path -LiteralPath $path)) {
            $log.Warn("No se encontro catalogo de fallbacks: $path")
            return
        }
        try {
            $json = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
            foreach ($prop in $json.convars.PSObject.Properties) {
                $this.Convars[$prop.Name.ToLowerInvariant()] = @{
                    default     = $prop.Value.default
                    type        = $prop.Value.type
                    description = $prop.Value.description
                }
            }
            foreach ($d in $json.deprecated) { $this.Deprecated[$d.ToLowerInvariant()] = $true }
            $log.Info("Catalogo fallback: $($this.Convars.Count) convars, $($this.Deprecated.Count) obsoletas")
        } catch {
            $log.Error("Error leyendo fallbacks: $($_.Exception.Message)")
        }
    }

    [bool] Has([string] $name)        { return $this.Convars.ContainsKey($name.ToLowerInvariant()) }
    [hashtable] Get([string] $name)   { return $this.Convars[$name.ToLowerInvariant()] }
    [string[]] AllNames()             { return @($this.Convars.Keys) }
    [bool] IsDeprecated([string] $n)  { return $this.Deprecated.ContainsKey($n.ToLowerInvariant()) }
}

class SyncEngine {
    hidden [Logger] $Log
    hidden [FallbackCatalog] $Fallbacks
    hidden [Classifier] $Classifier

    SyncEngine([Logger] $log, [FallbackCatalog] $fallbacks, [Classifier] $classifier) {
        $this.Log        = $log
        $this.Fallbacks  = $fallbacks
        $this.Classifier = $classifier
    }

    [GameConfig] Build([System.Collections.Generic.List[Setting]] $parsed,
                       [CS2Location] $cs2, [SteamLocation] $steam,
                       [DiscoveredFile[]] $files) {

        $cfg = [GameConfig]::new()
        $cfg.SteamId   = $cs2.SteamId
        $cfg.SteamPath = $steam.SteamRoot
        $cfg.CS2Path   = $cs2.GameRoot
        $cfg.CfgPath   = $cs2.LocalCfgPath
        foreach ($f in $files) { $cfg.SourceFiles.Add($f.Path) }

        # 1. Deduplicacion respetando prioridad de config viva.
        $seen   = [System.Collections.Generic.Dictionary[string, Setting]]::new()
        $merged = [System.Collections.Generic.List[Setting]]::new()
        foreach ($s in $parsed) {
            $key = $s.Key()
            if ($seen.ContainsKey($key)) {
                $s.State = [SettingState]::Duplicated   # conservado, marcado
                $merged.Add($s)
                continue
            }
            $seen[$key] = $s
            $merged.Add($s)
        }

        # 2. Enriquecer metadatos + marcar obsoletas (sin eliminar).
        foreach ($s in $merged) {
            if ($this.Fallbacks.Has($s.Name)) {
                $meta = $this.Fallbacks.Get($s.Name)
                if (-not $s.Metadata.Description)  { $s.Metadata.Description  = $meta.description }
                if (-not $s.Metadata.DefaultValue) { $s.Metadata.DefaultValue = $meta.default }
            }
            if ($this.Fallbacks.IsDeprecated($s.Name)) { $s.State = [SettingState]::Obsolete }
        }

        # 3. Fallbacks SOLO para variables ausentes.
        foreach ($name in $this.Fallbacks.AllNames()) {
            if ($seen.ContainsKey($name)) { continue }
            $meta = $this.Fallbacks.Get($name)
            $fb = [Setting]::new($name, [string]$meta.default)
            $fb.Priority = [SettingPriority]::Fallback
            $fb.State    = [SettingState]::FallbackApplied
            $fb.Type     = [SettingType]::Unknown
            $fb.Metadata.Description  = $meta.description
            $fb.Metadata.DefaultValue = $meta.default
            $fb.Metadata.SourceFile   = '(fallback catalog)'
            $fb.Metadata.Hash         = Get-StringHash -Text ("{0}={1}" -f $name, $meta.default)
            $seen[$name] = $fb
            $merged.Add($fb)
            $this.Log.Debug("Fallback aplicado para ausente: $name = $($meta.default)")
        }

        # 4. Clasificar.
        $this.Classifier.ClassifyAll($merged)

        # 5. Agrupar por categoria y ordenar determinista.
        $this.GroupIntoCategories($cfg, $merged)

        $this.Log.Info("GameConfig construido: $($cfg.TotalSettings()) ajustes en $($cfg.Categories.Count) categorias")
        return $cfg
    }

    hidden [void] GroupIntoCategories([GameConfig] $cfg, [System.Collections.Generic.List[Setting]] $settings) {
        $byCat = @{}
        foreach ($s in $settings) {
            if (-not $byCat.ContainsKey($s.CategoryCode)) {
                $byCat[$s.CategoryCode] = [System.Collections.Generic.List[Setting]]::new()
            }
            $byCat[$s.CategoryCode].Add($s)
        }

        foreach ($code in ($byCat.Keys | Sort-Object { [CategoryMap]::OrderFor($_) })) {
            $cat = [ConfigCategory]::new($code, [CategoryMap]::NameFor($code), [CategoryMap]::OrderFor($code))
            # Orden determinista dentro de la categoria: tipo, nombre, tecla/valor.
            $ordered = $byCat[$code] | Sort-Object `
                @{ Expression = { $_.Type.ToString() } }, `
                @{ Expression = { $_.Name } }, `
                @{ Expression = { if ($_.Extra.ContainsKey('Key')) { $_.Extra['Key'] } else { $_.Value } } }
            foreach ($s in $ordered) { $cat.Add($s) }
            $cfg.Categories.Add($cat)
        }
    }
}
