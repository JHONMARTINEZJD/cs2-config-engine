<#
.SYNOPSIS
    Diff semantico por setting entre el snapshot actual y el anterior.
.DESCRIPTION
    Hasta A1 el unico "diff" del motor comparaba el hash global del snapshot y
    tres conteos (binds/convars/aliases). Eso responde "cambio algo?" pero nunca
    "que cambio?", que es justo lo que hace falta para hablar de un motor de
    sincronizacion (y lo que A2 necesita para poder mostrar que aplicaria un
    restore antes de tocar nada).

    El material del diff sale de `Inventory.json`, que cada snapshot ya escribe
    con el inventario completo. `history.json` no guarda settings, asi que no
    sirve como base de comparacion por setting; se sigue usando para hashes y
    conteos, que es lo que si contiene.

    Identidad de un setting: SIEMPRE `Setting::Key()`, nunca el nombre suelto.
    Un bind se identifica por `bind::<tecla>` y un alias por `alias::<nombre>`,
    de modo que rebindear una tecla se ve como un cambio de esa tecla y no como
    "el nombre bind cambio de valor". Para reconstruir la clave del inventario
    anterior se rehidrata un [Setting] y se llama a su propio `Key()`: el
    algoritmo de clave vive en un unico sitio.

    Tolerancia a fallos (principio del proyecto): un `Inventory.json` ausente,
    vacio, truncado, corrupto o incoherente NO aborta nada. Se registra
    advertencia y el diff degrada a "sin base de comparacion", que el reporte
    dice con claridad en lugar de inventar deltas o pintar tablas vacias.

    Determinismo: el mismo par de snapshots produce el mismo JSON byte a byte.
    No se anade ninguna marca de tiempo propia y todo se ordena por
    (orden de categoria, clave).
#>

Set-StrictMode -Version Latest

<#
    Resultado del diff. Se expone como objeto (y no solo como JSON) para que el
    reporte Markdown y las pruebas trabajen sobre la misma estructura.

    PreviousTotal / CurrentTotal cuentan CLAVES DISTINTAS, no filas: el universo
    del diff es la clave estable. Los duplicados conservados no inflan esos
    totales; su numero viaja en el campo `occurrences` de cada entrada, y un
    cambio en el numero de duplicados se reporta como modificacion.

    Invariantes utiles:
        CurrentTotal  = Added.Count    + Modified.Count + Unchanged
        PreviousTotal = Removed.Count  + Modified.Count + Unchanged
#>
class ConfigDiffResult {
    [bool]   $HasBaseline
    [string] $Baseline            # 'inventory' cuando hay base real, 'none' si degrado
    [string] $BaselineWarning     # motivo de la degradacion ('' si no hubo)
    [string] $PreviousSnapshotId
    [string] $CurrentSnapshotId
    [int]    $PreviousTotal
    [int]    $CurrentTotal
    [int]    $Unchanged
    [System.Collections.Generic.List[object]] $Added
    [System.Collections.Generic.List[object]] $Removed
    [System.Collections.Generic.List[object]] $Modified

    ConfigDiffResult() {
        $this.HasBaseline        = $false
        $this.Baseline           = 'none'
        $this.BaselineWarning    = ''
        $this.PreviousSnapshotId = ''
        $this.CurrentSnapshotId  = ''
        $this.PreviousTotal      = 0
        $this.CurrentTotal       = 0
        $this.Unchanged          = 0
        $this.Added    = [System.Collections.Generic.List[object]]::new()
        $this.Removed  = [System.Collections.Generic.List[object]]::new()
        $this.Modified = [System.Collections.Generic.List[object]]::new()
    }

    [int] TotalChanges() {
        return $this.Added.Count + $this.Removed.Count + $this.Modified.Count
    }

    <#
        Resumen por categoria, ordenado por el orden del catalogo.
        El acumulador es un SortedDictionary con comparador ORDINAL: Sort-Object
        compara cadenas segun la cultura activa, asi que el mismo par de
        snapshots podria ordenarse distinto en otra maquina y romper el
        determinismo byte a byte.
    #>
    [object[]] ByCategory() {
        $acc = [System.Collections.Generic.SortedDictionary[string, object]]::new([System.StringComparer]::Ordinal)
        foreach ($e in $this.Added)    { $this.Bump($acc, [string]$e['category'], 'added') }
        foreach ($e in $this.Removed)  { $this.Bump($acc, [string]$e['category'], 'removed') }
        foreach ($e in $this.Modified) { $this.Bump($acc, [string]$e['category'], 'modified') }
        return @($acc.Values)
    }

    hidden [void] Bump([System.Collections.Generic.SortedDictionary[string, object]] $acc,
                       [string] $code, [string] $bucket) {
        $sortKey = '{0:D5}|{1}' -f [CategoryMap]::OrderFor($code), $code
        if (-not $acc.ContainsKey($sortKey)) {
            $acc[$sortKey] = [ordered]@{
                code     = $code
                name     = [CategoryMap]::NameFor($code)
                added    = 0
                removed  = 0
                modified = 0
            }
        }
        $acc[$sortKey][$bucket] = [int]$acc[$sortKey][$bucket] + 1
    }

    # Nodo serializable que se inserta en ConfigDiff.json.
    [System.Collections.Specialized.OrderedDictionary] ToHashtable() {
        return [ordered]@{
            baseline        = $this.Baseline
            baselineWarning = if ($this.BaselineWarning) { $this.BaselineWarning } else { $null }
            previousTotal   = $this.PreviousTotal
            currentTotal    = $this.CurrentTotal
            summary         = [ordered]@{
                added     = $this.Added.Count
                removed   = $this.Removed.Count
                modified  = $this.Modified.Count
                unchanged = $this.Unchanged
            }
            byCategory      = @($this.ByCategory())
            added           = @($this.Added)
            removed         = @($this.Removed)
            modified        = @($this.Modified)
        }
    }
}

class ConfigDiffEngine {
    hidden [Logger] $Log

    # Campos comparados para decidir si una clave cambio, en orden determinista.
    # El hash NO entra: se deriva de nombre+valor, asi que seria redundante con
    # `value` y solo anadiria ruido. Se reporta, pero no decide.
    static [string[]] $ComparedFields = @('value', 'type', 'category', 'state', 'occurrences')

    ConfigDiffEngine([Logger] $log) { $this.Log = $log }

    <#
        Compara la config viva actual contra el inventario del snapshot anterior.

        $previousSnapshotId vacio significa "no hay snapshot anterior": es el
        primer backup, no un error, y no se emite advertencia.
    #>
    [ConfigDiffResult] Compare([GameConfig] $cfg, [string] $currentSnapshotId,
                               [string] $previousSnapshotId, [string] $previousInventoryPath) {
        $res = [ConfigDiffResult]::new()
        $res.CurrentSnapshotId  = if ($currentSnapshotId)  { $currentSnapshotId }  else { '' }
        $res.PreviousSnapshotId = if ($previousSnapshotId) { $previousSnapshotId } else { '' }

        $current = $this.IndexFromConfig($cfg)
        $res.CurrentTotal = $current.Count

        if ([string]::IsNullOrWhiteSpace($previousSnapshotId)) {
            $this.Log.Info('Diff: no hay snapshot anterior; este es el primer estado registrado.')
            return $res
        }

        $previous = $this.LoadInventoryIndex($previousInventoryPath, $res)
        if ($null -eq $previous) {
            # Ya quedo la advertencia registrada en LoadInventoryIndex.
            return $res
        }

        $res.HasBaseline   = $true
        $res.Baseline      = 'inventory'
        $res.PreviousTotal = $previous.Count

        $added    = [System.Collections.Generic.List[object]]::new()
        $removed  = [System.Collections.Generic.List[object]]::new()
        $modified = [System.Collections.Generic.List[object]]::new()

        foreach ($key in $current.Keys) {
            $cur = $current[$key]
            if (-not $previous.Contains($key)) {
                $added.Add($this.NewPresenceEntry($cur))
                continue
            }
            $prv = $previous[$key]
            $fields = $this.ChangedFields($prv, $cur)
            if ($fields.Count -eq 0) {
                $res.Unchanged++
                continue
            }
            $modified.Add($this.NewChangeEntry($prv, $cur, $fields))
        }
        foreach ($key in $previous.Keys) {
            if ($current.Contains($key)) { continue }
            $removed.Add($this.NewPresenceEntry($previous[$key]))
        }

        foreach ($e in $this.SortEntries($added))    { $res.Added.Add($e) }
        foreach ($e in $this.SortEntries($removed))  { $res.Removed.Add($e) }
        foreach ($e in $this.SortEntries($modified)) { $res.Modified.Add($e) }

        $this.Log.Info(('Diff frente a {0}: +{1} / -{2} / ~{3} (sin cambios {4})' -f
            $res.PreviousSnapshotId, $res.Added.Count, $res.Removed.Count,
            $res.Modified.Count, $res.Unchanged))
        return $res
    }

    # ---------------------------------------------------------------- indices

    <#
        Indexa la config viva por clave estable.

        Los duplicados se conservan en el modelo (nada se descarta), asi que una
        clave puede aparecer varias veces. El representante es el ejemplar que
        NO esta marcado Duplicated, es decir el que gano la deduplicacion de
        SyncEngine y por tanto el valor que manda. Elegir "el primero que
        aparezca" seria ademas fragil: dentro de una categoria el orden lo fija
        un Sort-Object por (tipo, nombre, tecla/valor).
    #>
    hidden [System.Collections.Specialized.OrderedDictionary] IndexFromConfig([GameConfig] $cfg) {
        $idx = [ordered]@{}
        foreach ($cat in $cfg.Categories) {
            foreach ($s in $cat.Settings) {
                $entry = [ordered]@{
                    key         = $s.Key()
                    name        = $s.Name
                    value       = $s.Value
                    type        = $s.Type.ToString()
                    state       = $s.State.ToString()
                    # Manda la categoria que contiene al ajuste, no
                    # $s.CategoryCode: ese campo vale P48 por defecto en el
                    # constructor y solo lo rellena SyncEngine, asi que un
                    # GameConfig armado de otra forma (fixtures, y sobre todo el
                    # preview de un restore en A2, que se construye desde un
                    # inventario) reportaria un cambio de categoria fantasma.
                    category    = $cat.Code
                    hash        = $s.Metadata.Hash
                    occurrences = 1
                }
                $this.Merge($idx, $entry, ($s.State -eq [SettingState]::Duplicated))
            }
        }
        return $idx
    }

    # Inserta o fusiona una entrada en el indice contando repeticiones.
    hidden [void] Merge([System.Collections.Specialized.OrderedDictionary] $idx,
                        [System.Collections.Specialized.OrderedDictionary] $entry, [bool] $isDuplicate) {
        $key = [string]$entry['key']
        if (-not $idx.Contains($key)) {
            $idx[$key] = $entry
            return
        }
        $existing = $idx[$key]
        $count    = [int]$existing['occurrences'] + 1
        if ($isDuplicate) {
            $existing['occurrences'] = $count
            return
        }
        # El ejemplar no duplicado manda: sustituye al representante y hereda el conteo.
        $entry['occurrences'] = $count
        $idx[$key] = $entry
    }

    <#
        Carga e indexa el Inventory.json del snapshot anterior. Devuelve $null y
        deja la advertencia en $res.BaselineWarning ante cualquier problema.
    #>
    hidden [System.Collections.Specialized.OrderedDictionary] LoadInventoryIndex(
            [string] $path, [ConfigDiffResult] $res) {

        if ([string]::IsNullOrWhiteSpace($path)) {
            return $this.Degrade($res, "El snapshot anterior $($res.PreviousSnapshotId) no expone Inventory.json.")
        }
        if (-not (Test-Path -LiteralPath $path)) {
            return $this.Degrade($res, "No se encontro el inventario del snapshot anterior: $path")
        }

        $parsed = $null
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8
            if ([string]::IsNullOrWhiteSpace($raw)) {
                return $this.Degrade($res, "El inventario del snapshot anterior esta vacio: $path")
            }
            $parsed = $raw | ConvertFrom-Json
        } catch {
            return $this.Degrade($res, "Inventario anterior ilegible o corrupto ($path): $($_.Exception.Message)")
        }

        if ($null -eq $parsed -or $null -eq $parsed.PSObject.Properties['categories']) {
            return $this.Degrade($res, "El inventario anterior no tiene la forma esperada (sin 'categories'): $path")
        }

        $idx = [ordered]@{}
        foreach ($cat in @($parsed.categories)) {
            if ($null -eq $cat) { continue }
            $catCode = [string]$this.Prop($cat, 'code', '')
            foreach ($s in @($this.Prop($cat, 'settings', @()))) {
                if ($null -eq $s) { continue }
                $entry = $this.EntryFromInventory($s, $catCode)
                if ($null -eq $entry) { continue }
                $this.Merge($idx, $entry, ([string]$entry['state'] -eq 'Duplicated'))
            }
        }

        # Incoherencia declarada vs leida: senal de archivo truncado a mano.
        $declared = [int]$this.Prop($parsed, 'total', 0)
        if ($declared -gt 0 -and $idx.Count -eq 0) {
            return $this.Degrade($res, "El inventario anterior declara $declared ajustes pero no contiene ninguno: $path")
        }
        return $idx
    }

    hidden [System.Collections.Specialized.OrderedDictionary] Degrade([ConfigDiffResult] $res, [string] $message) {
        $res.HasBaseline     = $false
        $res.Baseline        = 'none'
        $res.BaselineWarning = $message
        $res.PreviousTotal   = 0
        $this.Log.Warn("Diff sin base de comparacion: $message")
        return $null
    }

    <#
        Rehidrata un setting del inventario en un [Setting] real solo para que la
        clave la calcule `Setting::Key()` y no una copia divergente de esa regla.
        Cualquier campo ausente o con basura degrada a un valor neutro; un
        setting sin nombre se descarta porque no tiene clave posible.
    #>
    hidden [System.Collections.Specialized.OrderedDictionary] EntryFromInventory([object] $s, [string] $fallbackCategory) {
        $name = [string]$this.Prop($s, 'name', '')
        if ([string]::IsNullOrWhiteSpace($name)) { return $null }
        $value = [string]$this.Prop($s, 'value', '')

        $setting = [Setting]::new($name, $value)
        $setting.Type = $this.ParseType([string]$this.Prop($s, 'type', ''))

        $extra = $this.Prop($s, 'extra', $null)
        if ($null -ne $extra) {
            if ($extra -is [System.Collections.IDictionary]) {
                foreach ($k in $extra.Keys) { $setting.Extra[[string]$k] = [string]$extra[$k] }
            } else {
                foreach ($p in $extra.PSObject.Properties) { $setting.Extra[$p.Name] = [string]$p.Value }
            }
        }

        # El bloque de categoria que contiene al ajuste es autoritativo, igual que
        # en IndexFromConfig: el campo 'category' de cada ajuste sale de
        # Setting::CategoryCode, que vale P48 por defecto y solo rellena
        # SyncEngine, asi que un inventario escrito desde un GameConfig armado de
        # otra forma discreparia de su propio agrupamiento y generaria cambios de
        # categoria fantasma. Solo se usa el campo del ajuste si el bloque no
        # declara codigo.
        $category = $fallbackCategory
        if ([string]::IsNullOrWhiteSpace($category)) { $category = [string]$this.Prop($s, 'category', '') }
        if ([string]::IsNullOrWhiteSpace($category)) { $category = 'P48' }

        $state = [string]$this.Prop($s, 'state', '')
        if ([string]::IsNullOrWhiteSpace($state)) { $state = [SettingState]::Unknown.ToString() }

        return [ordered]@{
            key         = $setting.Key()
            name        = $name
            value       = $value
            type        = $setting.Type.ToString()
            state       = $state
            category    = $category
            hash        = [string]$this.Prop($s, 'hash', '')
            occurrences = 1
        }
    }

    hidden [SettingType] ParseType([string] $declared) {
        if ([string]::IsNullOrWhiteSpace($declared)) { return [SettingType]::Unknown }
        foreach ($n in [enum]::GetNames([SettingType])) {
            if ($n -eq $declared.Trim()) { return [SettingType]$n }
        }
        return [SettingType]::Unknown
    }

    # Lectura tolerante de una propiedad, venga de JSON o de una tabla hash.
    hidden [object] Prop([object] $obj, [string] $name, [object] $default) {
        if ($null -eq $obj) { return $default }
        if ($obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($name)) { return $obj[$name] }
            return $default
        }
        $p = $obj.PSObject.Properties[$name]
        if ($null -eq $p -or $null -eq $p.Value) { return $default }
        return $p.Value
    }

    # --------------------------------------------------------------- entradas

    hidden [string[]] ChangedFields([object] $prv, [object] $cur) {
        $changed = [System.Collections.Generic.List[string]]::new()
        foreach ($f in [ConfigDiffEngine]::ComparedFields) {
            if ([string]$prv[$f] -cne [string]$cur[$f]) { $changed.Add($f) }
        }
        return $changed.ToArray()
    }

    # Entrada de alta o baja: el valor que entra, o el que deja de estar.
    hidden [System.Collections.Specialized.OrderedDictionary] NewPresenceEntry([object] $e) {
        return [ordered]@{
            key          = [string]$e['key']
            name         = [string]$e['name']
            type         = [string]$e['type']
            state        = [string]$e['state']
            category     = [string]$e['category']
            categoryName = [CategoryMap]::NameFor([string]$e['category'])
            value        = [string]$e['value']
            hash         = [string]$e['hash']
            occurrences  = [int]$e['occurrences']
        }
    }

    # Entrada de cambio: antes y despues completos, mas los campos que se movieron.
    hidden [System.Collections.Specialized.OrderedDictionary] NewChangeEntry([object] $prv, [object] $cur, [string[]] $fields) {
        return [ordered]@{
            key              = [string]$cur['key']
            name             = [string]$cur['name']
            type             = [string]$cur['type']
            category         = [string]$cur['category']
            categoryName     = [CategoryMap]::NameFor([string]$cur['category'])
            fields           = @($fields)
            previousValue    = [string]$prv['value']
            currentValue     = [string]$cur['value']
            previousType     = [string]$prv['type']
            previousCategory = [string]$prv['category']
            previousState    = [string]$prv['state']
            currentState     = [string]$cur['state']
            previousHash     = [string]$prv['hash']
            currentHash      = [string]$cur['hash']
            previousOccurrences = [int]$prv['occurrences']
            currentOccurrences  = [int]$cur['occurrences']
        }
    }

    <#
        Orden determinista: categoria segun el catalogo, luego clave ordinal.
        Se usa SortedDictionary con StringComparer::Ordinal en lugar de
        Sort-Object a proposito: Sort-Object compara cadenas segun la cultura
        activa, y eso haria que el JSON dejase de ser byte a byte igual en una
        maquina con otra configuracion regional. La clave de orden es unica
        porque la clave de setting ya lo es dentro del indice.
    #>
    hidden [object[]] SortEntries([System.Collections.Generic.List[object]] $entries) {
        $sorted = [System.Collections.Generic.SortedDictionary[string, object]]::new([System.StringComparer]::Ordinal)
        foreach ($e in $entries) {
            $sortKey = '{0:D5}|{1}|{2}' -f [CategoryMap]::OrderFor([string]$e['category']),
                                           [string]$e['category'], [string]$e['key']
            $sorted[$sortKey] = $e
        }
        return @($sorted.Values)
    }
}
