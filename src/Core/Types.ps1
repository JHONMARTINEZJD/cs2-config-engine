<#
.SYNOPSIS
    Modelo de dominio del Configuration Snapshot Engine.
.DESCRIPTION
    Define las clases que componen el modelo interno jerarquico:

        GameConfig
          -> Module
            -> Category
              -> Setting
                -> SettingMetadata

    Cada nivel es independiente y serializable. Las clases NO contienen logica
    de IO ni de parseo; solo representan datos y operaciones triviales sobre
    ellos (principio de responsabilidad unica).
#>

Set-StrictMode -Version Latest

# Tipos de valor reconocidos por el motor. "Unknown" permite tolerancia a
# formatos futuros introducidos por Valve sin perder la informacion.
enum SettingType {
    Bool
    Integer
    Float
    String
    Alias
    Bind
    AnalogBind
    List
    Block
    Unknown
}

# Origen/prioridad del valor. La configuracion viva del juego SIEMPRE gana.
enum SettingPriority {
    LiveConfig   = 0   # leido directamente de los .vcfg/.cfg del usuario
    Derived      = 1   # derivado/normalizado a partir de la config viva
    Fallback     = 2   # valor por defecto, solo si la variable no existe
}

enum SettingState {
    Synced
    FallbackApplied
    Duplicated
    Invalid
    Obsolete
    Unknown
}

<#
    Metadatos asociados a cada Setting. Se separan del Setting para mantener la
    clase principal ligera y permitir extender los metadatos sin tocar el resto.
#>
class SettingMetadata {
    [string]   $SourceFile          # archivo de origen
    [int]      $SourceLine          # linea original (1-based, -1 si desconocida)
    [string]   $RawLine             # texto crudo tal cual aparece en el archivo
    [string]   $Description         # descripcion humana (puede venir del catalogo)
    [string]   $DefaultValue        # valor fallback/por defecto conocido
    [datetime] $CapturedAt          # cuando se capturo
    [string]   $Hash                # hash del valor actual

    SettingMetadata() {
        $this.SourceFile   = ''
        $this.SourceLine   = -1
        $this.RawLine      = ''
        $this.Description  = ''
        $this.DefaultValue = ''
        $this.CapturedAt   = [datetime]::UtcNow
        $this.Hash         = ''
    }
}

<#
    Una unidad de configuracion: una convar, un bind, un alias, etc.
#>
class Setting {
    [string]          $Name
    [string]          $Value
    [SettingType]     $Type
    [SettingPriority] $Priority
    [SettingState]    $State
    [string]          $CategoryCode   # p.ej. "P24"
    [SettingMetadata] $Metadata
    # Para binds: tecla -> comando. Para analogbinds y alias guardamos extra.
    [hashtable]       $Extra

    Setting([string] $name, [string] $value) {
        $this.Name     = $name
        $this.Value    = $value
        $this.Type     = [SettingType]::Unknown
        $this.Priority = [SettingPriority]::LiveConfig
        $this.State    = [SettingState]::Synced
        $this.CategoryCode = 'P48'   # Unknown Commands por defecto
        $this.Metadata = [SettingMetadata]::new()
        $this.Extra    = @{}
    }

    # Clave estable e insensible a mayusculas usada para deduplicar.
    [string] Key() {
        if ($this.Type -eq [SettingType]::Bind -or $this.Type -eq [SettingType]::AnalogBind) {
            $k = if ($this.Extra.ContainsKey('Key')) { $this.Extra['Key'] } else { $this.Value }
            return ('{0}::{1}' -f $this.Name, $k).ToLowerInvariant()
        }
        if ($this.Type -eq [SettingType]::Alias) {
            return ('alias::{0}' -f $this.Name).ToLowerInvariant()
        }
        return $this.Name.ToLowerInvariant()
    }

    [hashtable] ToHashtable() {
        return @{
            name        = $this.Name
            value       = $this.Value
            type        = $this.Type.ToString()
            priority    = $this.Priority.ToString()
            state       = $this.State.ToString()
            category    = $this.CategoryCode
            sourceFile  = $this.Metadata.SourceFile
            sourceLine  = $this.Metadata.SourceLine
            rawLine     = $this.Metadata.RawLine
            description = $this.Metadata.Description
            default     = $this.Metadata.DefaultValue
            capturedAt  = $this.Metadata.CapturedAt.ToString('o')
            hash        = $this.Metadata.Hash
            extra       = $this.Extra
        }
    }
}

<#
    Agrupa Settings de una misma categoria granular (P00..P49).
#>
class ConfigCategory {
    [string]    $Code        # "P24"
    [string]    $Name        # "Crosshair"
    [int]       $Order       # orden determinista
    [System.Collections.Generic.List[Setting]] $Settings

    ConfigCategory([string] $code, [string] $name, [int] $order) {
        $this.Code     = $code
        $this.Name     = $name
        $this.Order    = $order
        $this.Settings = [System.Collections.Generic.List[Setting]]::new()
    }

    [void] Add([Setting] $setting) {
        $this.Settings.Add($setting)
    }

    [int] Count() { return $this.Settings.Count }
}

<#
    Modulo de alto nivel que agrupa categorias relacionadas.
#>
class ConfigModule {
    [string] $Name
    [int]    $Order
    [System.Collections.Generic.List[ConfigCategory]] $Categories

    ConfigModule([string] $name, [int] $order) {
        $this.Name       = $name
        $this.Order      = $order
        $this.Categories = [System.Collections.Generic.List[ConfigCategory]]::new()
    }
}

<#
    Raiz del modelo. Mantiene un indice plano de todos los settings ademas de la
    jerarquia, para acelerar busquedas y deduplicacion.
#>
class GameConfig {
    [string]   $SteamId
    [string]   $SteamPath
    [string]   $CS2Path
    [string]   $CfgPath
    [datetime] $CapturedAt
    [System.Collections.Generic.List[ConfigCategory]] $Categories
    [System.Collections.Generic.List[string]]         $SourceFiles

    GameConfig() {
        $this.SteamId     = ''
        $this.SteamPath   = ''
        $this.CS2Path     = ''
        $this.CfgPath     = ''
        $this.CapturedAt  = [datetime]::UtcNow
        $this.Categories  = [System.Collections.Generic.List[ConfigCategory]]::new()
        $this.SourceFiles = [System.Collections.Generic.List[string]]::new()
    }

    [System.Collections.Generic.IEnumerable[Setting]] AllSettings() {
        $all = [System.Collections.Generic.List[Setting]]::new()
        foreach ($cat in $this.Categories) {
            foreach ($s in $cat.Settings) { $all.Add($s) }
        }
        return $all
    }

    [int] TotalSettings() {
        $n = 0
        foreach ($cat in $this.Categories) { $n += $cat.Settings.Count }
        return $n
    }

    [int] CountByType([SettingType] $type) {
        $n = 0
        foreach ($cat in $this.Categories) {
            foreach ($s in $cat.Settings) { if ($s.Type -eq $type) { $n++ } }
        }
        return $n
    }
}
