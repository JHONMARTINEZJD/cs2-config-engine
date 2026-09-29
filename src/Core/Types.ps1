<#
.SYNOPSIS
    Modelo de dominio del Configuration Snapshot Engine.
.DESCRIPTION
    Define las clases que componen el modelo interno jerarquico:

        GameConfig
          -> ConfigCategory (P00..P49)
            -> Setting
              -> SettingMetadata

    El agrupamiento de categorias en bloques de alto nivel vive en CategoryMap,
    no como una capa de objetos intermedia.

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

    <#
        Inverso de ToHashtable(): rehidrata un [Setting] completo desde el nodo
        que escribe Inventory.json (o desde cualquier tabla hash con la misma
        forma). Vive aqui, junto a ToHashtable() y a Key(), porque la forma
        serializada de un Setting es asunto del Setting: hasta A2 el diff
        mantenia su propia rehidratacion parcial (solo nombre, valor, tipo y
        extra) y un restore necesita el objeto entero.

        Acepta indistintamente una [hashtable] y el PSCustomObject que devuelve
        ConvertFrom-Json, porque el material real llega de un JSON en disco.

        Tolerancia (principio del proyecto: nada se descarta, nada revienta):
        cualquier campo ausente, nulo o con basura degrada al valor neutro que
        pondria el constructor, nunca aborta. La UNICA causa de descarte es un
        nombre vacio: sin nombre no hay Key() posible, asi que el ajuste no
        podria identificarse ni deduplicarse y se devuelve $null para que quien
        llama lo omita.

        Determinismo: un capturedAt ausente o ilegible NO se sustituye por la
        hora actual (eso haria que rehidratar dos veces el mismo inventario
        diese objetos distintos), sino por DateTime::MinValue.

        Nota deliberada: `category` se rehidrata tal cual viene, pero NO es
        autoritativa para agrupar. Manda siempre el bloque que contiene al
        ajuste, porque CategoryCode vale P48 por defecto y solo lo rellena
        SyncEngine. Quien consume un inventario sobreescribe CategoryCode con el
        codigo del bloque; ver ConfigDiffEngine::EntryFromInventory y
        RestoreEngine::ConfigFromInventory.
    #>
    static [Setting] FromHashtable([object] $data) {
        if ($null -eq $data) { return $null }

        $settingName = [string][Setting]::Field($data, 'name', '')
        if ([string]::IsNullOrWhiteSpace($settingName)) { return $null }

        $s = [Setting]::new($settingName, [string][Setting]::Field($data, 'value', ''))
        $s.Type     = [SettingType][Setting]::ParseEnumValue([SettingType],
                          [string][Setting]::Field($data, 'type', ''), [SettingType]::Unknown)
        $s.Priority = [SettingPriority][Setting]::ParseEnumValue([SettingPriority],
                          [string][Setting]::Field($data, 'priority', ''), [SettingPriority]::LiveConfig)
        $s.State    = [SettingState][Setting]::ParseEnumValue([SettingState],
                          [string][Setting]::Field($data, 'state', ''), [SettingState]::Unknown)

        $category = [string][Setting]::Field($data, 'category', '')
        if (-not [string]::IsNullOrWhiteSpace($category)) { $s.CategoryCode = $category.Trim() }

        $s.Metadata.SourceFile   = [string][Setting]::Field($data, 'sourceFile',  '')
        $s.Metadata.RawLine      = [string][Setting]::Field($data, 'rawLine',     '')
        $s.Metadata.Description  = [string][Setting]::Field($data, 'description', '')
        $s.Metadata.DefaultValue = [string][Setting]::Field($data, 'default',     '')
        $s.Metadata.Hash         = [string][Setting]::Field($data, 'hash',        '')

        [int] $line = -1
        if (-not [int]::TryParse([string][Setting]::Field($data, 'sourceLine', ''),
                                 [ref] $line)) { $line = -1 }
        $s.Metadata.SourceLine = $line

        # ConvertFrom-Json ya convierte un ISO-8601 en [datetime]; si llega como
        # texto se parsea con cultura invariante para no depender de la
        # configuracion regional de la maquina.
        $capturedNode = [Setting]::Field($data, 'capturedAt', $null)
        $s.Metadata.CapturedAt = [datetime]::MinValue
        if ($capturedNode -is [datetime]) {
            $s.Metadata.CapturedAt = [datetime]$capturedNode
        } else {
            [datetime] $captured = [datetime]::MinValue
            if ([datetime]::TryParse([string]$capturedNode,
                                     [System.Globalization.CultureInfo]::InvariantCulture,
                                     [System.Globalization.DateTimeStyles]::RoundtripKind,
                                     [ref] $captured)) {
                $s.Metadata.CapturedAt = $captured
            }
        }

        # Extra guarda la tecla de un bind, el cuerpo de un alias, etc. Key()
        # depende de Extra['Key'], asi que perderlo convertiria cada bind
        # rehidratado en "bind::<comando>" y todos los binds colisionarian.
        $extraNode = [Setting]::Field($data, 'extra', $null)
        if ($null -ne $extraNode) {
            if ($extraNode -is [System.Collections.IDictionary]) {
                foreach ($k in $extraNode.Keys) {
                    if ($null -eq $k) { continue }
                    $s.Extra[[string]$k] = [string]$extraNode[$k]
                }
            } elseif ($extraNode -isnot [string] -and $extraNode -isnot [ValueType]) {
                foreach ($p in $extraNode.PSObject.Properties) { $s.Extra[$p.Name] = [string]$p.Value }
            }
        }
        return $s
    }

    # Lectura tolerante de un campo, venga de JSON (PSCustomObject) o de una
    # tabla hash. Con Set-StrictMode acceder a una propiedad inexistente es
    # terminante, asi que todo acceso al material serializado pasa por aqui.
    hidden static [object] Field([object] $obj, [string] $field, [object] $default) {
        if ($null -eq $obj) { return $default }
        if ($obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($field) -and $null -ne $obj[$field]) { return $obj[$field] }
            return $default
        }
        $p = $obj.PSObject.Properties[$field]
        if ($null -eq $p -or $null -eq $p.Value) { return $default }
        return $p.Value
    }

    # Resuelve el nombre de un miembro de enum por su texto. Fuera del catalogo
    # de nombres (cadena vacia, numero, valor retirado en otra version) se
    # devuelve el neutro que pide quien llama en lugar de lanzar.
    hidden static [object] ParseEnumValue([type] $enumType, [string] $declared, [object] $fallback) {
        if ([string]::IsNullOrWhiteSpace($declared)) { return $fallback }
        $wanted = $declared.Trim()
        foreach ($n in [enum]::GetNames($enumType)) {
            if ($n -eq $wanted) { return [enum]::Parse($enumType, $n) }
        }
        return $fallback
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
