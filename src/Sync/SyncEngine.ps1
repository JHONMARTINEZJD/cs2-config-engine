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

    Desde A3 el catalogo tiene DOS capas y la distincion es deliberada:

      * La lista CURADA (config/fallbacks.json) decide QUE se inyecta cuando
        falta. Son pocas y elegidas a mano.
      * El catalogo GENERADO (config/convars.json, hecho con -ImportCvarList)
        aporta solo METADATOS y no inyecta nada, porque tiene miles de entradas
        y volcarlas al autoexec seria publicar el motor, no la configuracion del
        jugador. Ver la cabecera de Catalog/ConvarCatalog.ps1.

    En los metadatos manda lo curado y el generado rellena huecos. La regla 2 no
    cambia: ninguna de las dos capas sobreescribe jamas un valor vivo.
#>

Set-StrictMode -Version Latest

class FallbackCatalog {
    hidden [hashtable]     $Convars       # nameLower -> @{ default; type; description }  (curado)
    hidden [hashtable]     $Deprecated    # nameLower -> $true                            (curado)
    hidden [ConvarCatalog] $Generated     # catalogo generado; solo metadatos, nunca inyecta

    # Sin catalogo generado: comportamiento identico al anterior a A3.
    FallbackCatalog([string] $path, [Logger] $log) {
        $this.LoadCurated($path, $log)
        $this.Generated = [ConvarCatalog]::new('', $log)
    }

    # Con catalogo generado. Se pasa la ruta y no el objeto para que quien llama
    # no tenga que saber que hacer cuando el archivo no existe: un catalogo
    # ausente da un catalogo vacio, no un error.
    FallbackCatalog([string] $path, [string] $generatedPath, [Logger] $log) {
        $this.LoadCurated($path, $log)
        $this.Generated = [ConvarCatalog]::new($generatedPath, $log)
    }

    hidden [void] LoadCurated([string] $path, [Logger] $log) {
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

    # Nombres que SE INYECTAN cuando faltan: solo los curados. El catalogo
    # generado queda fuera a proposito (ver la cabecera del archivo).
    [string[]] InjectableNames() { return @($this.Convars.Keys) }

    [bool] HasMetadata([string] $settingName) {
        if ([string]::IsNullOrWhiteSpace($settingName)) { return $false }
        if ($this.Convars.ContainsKey($settingName.ToLowerInvariant())) { return $true }
        return $this.Generated.Has($settingName)
    }

    <#
        Metadatos de una convar: manda lo curado y el catalogo generado rellena
        solo los campos que lo curado deja vacios. Devuelve $null si no hay nada.
        Nunca se mezcla con el valor vivo: quien llama decide, y solo rellena
        huecos.
    #>
    [hashtable] GetMetadata([string] $settingName) {
        if ([string]::IsNullOrWhiteSpace($settingName)) { return $null }
        $clave = $settingName.ToLowerInvariant()
        $curado = if ($this.Convars.ContainsKey($clave)) { $this.Convars[$clave] } else { $null }
        $gen    = $this.Generated.Get($settingName)
        if ($null -eq $curado) { return $gen }
        if ($null -eq $gen)    { return $curado }

        $mezcla = @{
            default     = $curado.default
            type        = $curado.type
            description = $curado.description
        }
        foreach ($campo in @('default', 'type', 'description')) {
            if ([string]::IsNullOrWhiteSpace([string]$mezcla[$campo])) { $mezcla[$campo] = $gen[$campo] }
        }
        return $mezcla
    }

    [bool] IsDeprecated([string] $settingName) {
        if ([string]::IsNullOrWhiteSpace($settingName)) { return $false }
        return $this.Deprecated.ContainsKey($settingName.ToLowerInvariant())
    }

    # Entradas del catalogo generado, para los informes y el log del motor.
    [int] GeneratedCount() { return $this.Generated.Count() }
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

        # 2. Enriquecer metadatos + marcar obsoletas (sin eliminar). Los metadatos
        #    pueden venir de la lista curada o del catalogo generado, y SOLO
        #    rellenan huecos: un valor vivo no se toca nunca.
        foreach ($s in $merged) {
            $meta = $this.Fallbacks.GetMetadata($s.Name)
            if ($null -ne $meta) {
                if (-not $s.Metadata.Description)  { $s.Metadata.Description  = $meta.description }
                if (-not $s.Metadata.DefaultValue) { $s.Metadata.DefaultValue = $meta.default }
            }
            if ($this.Fallbacks.IsDeprecated($s.Name)) { $s.State = [SettingState]::Obsolete }
        }

        # 3. Fallbacks SOLO para variables ausentes, y solo los CURADOS: el
        #    catalogo generado aporta metadatos, no entradas nuevas.
        foreach ($name in $this.Fallbacks.InjectableNames()) {
            if ($seen.ContainsKey($name)) { continue }
            $meta = $this.Fallbacks.GetMetadata($name)
            $fb = [Setting]::new($name, [string]$meta.default)
            $fb.Priority = [SettingPriority]::Fallback
            $fb.State    = [SettingState]::FallbackApplied
            $fb.Type     = $this.ResolveType([string]$meta.type)
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

    <#
        Traduce el campo "type" de fallbacks.json a SettingType. Antes los
        fallbacks se inyectaban siempre como Unknown, tirando el tipo que el
        catalogo ya declaraba y contaminando los conteos por tipo del snapshot.
        Un tipo ausente o desconocido degrada a Unknown sin fallar.
    #>
    hidden [SettingType] ResolveType([string] $declared) {
        if ([string]::IsNullOrWhiteSpace($declared)) { return [SettingType]::Unknown }
        foreach ($name in [enum]::GetNames([SettingType])) {
            if ($name -eq $declared.Trim()) { return [SettingType]$name }
        }
        $this.Log.Debug("Tipo de fallback no reconocido: '$declared'")
        return [SettingType]::Unknown
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
            # Comparacion ORDINAL, no Sort-Object: Sort-Object cotejaria segun la
            # cultura activa y de este orden salen el autoexec y todos los
            # exportadores, asi que en un sistema danes (donde "aa" se cot|eja
            # despues de la z) el mismo config generaria un archivo distinto.
            $ordered = Sort-OrdinalBy -Items @($byCat[$code]) -KeySelector {
                param($s)
                $tercero = if ($s.Extra.ContainsKey('Key')) { $s.Extra['Key'] } else { $s.Value }
                Join-OrdinalKey -Parts @($s.Type.ToString(), $s.Name, $tercero)
            }
            foreach ($s in $ordered) { $cat.Add($s) }
            $cfg.Categories.Add($cat)
        }
    }
}
