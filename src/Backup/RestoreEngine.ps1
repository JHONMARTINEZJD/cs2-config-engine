<#
.SYNOPSIS
    Camino de vuelta: previsualizar y aplicar un snapshot anterior, con backup
    previo y rollback atomico (A2).
.DESCRIPTION
    Hasta A2 el motor era unidireccional: leer la config viva, clasificarla y
    exportarla. Faltaba poder volver a un estado anterior.

    Que se restaura, y por que:
      Se escriben las COPIAS FIELES que el snapshot guardo en `raw/`, byte a
      byte, no una reconstruccion de los archivos a partir de `Inventory.json`.
      Motivo: no existe (todavia) un escritor de `.vcfg`, y generar uno a ciegas
      para sobreescribir archivos del jugador seria la decision arriesgada. La
      copia fiel es exactamente el estado al que se quiere volver y no puede
      corromper formato. `Inventory.json` se usa para el PREVIEW semantico, que
      es donde aporta: decir que ajustes cambiarian.

    Seguridad, no negociable:
      - Por defecto se escribe en la carpeta de salida, nunca sobre los `.vcfg`
        ni `.cfg` vivos del jugador.
      - Tocar los archivos del jugador exige pedirlo dos veces
        (`RestoreTarget = LiveFiles` y `-AllowLiveFileWrites`), backup previo del
        estado actual y rollback atomico.
      - El modo por defecto es solo-mostrar: `Plan()` no escribe nada nunca.
        Solo `Apply()` toca el disco.

    Rollback atomico, en tres fases:
      0. Precondiciones. Si algun destino existe pero no es un archivo, se
         aborta ANTES de escribir nada.
      1. Backup. Se copia el contenido actual de cada destino existente a
         `backup-<ts>/`, y se anotan los destinos que no existian para poder
         borrarlos. Si el backup falla, no se ha escrito nada todavia.
      2. Escritura. Si cualquier escritura falla a mitad, se deshacen TODAS las
         ya hechas (restaurar bytes previos, borrar los creados, quitar las
         carpetas que se crearon si quedan vacias) y se relanza el error con
         contexto. El jugador queda como estaba.

    Tolerancia a fallos: un snapshot inexistente, sin `Inventory.json`, con el
    inventario corrupto o sin copias en `raw/` produce un error con la ruta y la
    accion concreta a tomar, nunca una excepcion pelada ni una escritura parcial.
#>

Set-StrictMode -Version Latest

# Destino de la escritura. Enum y no cadena para que un valor invalido no llegue
# nunca a la fase de escritura.
enum RestoreTarget {
    Output      # carpeta de salida del motor (por defecto, siempre seguro)
    LiveFiles   # los archivos vivos del jugador (exige permiso explicito)
}

# Una escritura planificada: de donde sale, a donde iria y que le pasaria al
# archivo que ya esta ahi.
class RestoreFileAction {
    [string] $Name          # nombre del archivo tal cual lo guardo el snapshot
    [string] $SourcePath    # copia fiel dentro del snapshot (raw/)
    [string] $TargetPath    # ruta que se escribiria
    [string] $OriginalPath  # ruta viva original segun Manifest.json ('' si se ignora)
    [long]   $Size
    [string] $Status        # create | overwrite | identical

    RestoreFileAction() {
        $this.Name         = ''
        $this.SourcePath   = ''
        $this.TargetPath   = ''
        $this.OriginalPath = ''
        $this.Size         = 0
        $this.Status       = 'create'
    }
}

<#
    Plan de restauracion: el "que pasaria si". Es el objeto que se muestra en el
    preview y el que consume Apply(); asi lo aplicado es literalmente lo
    mostrado, no un segundo calculo que podria diferir.
#>
class RestorePlan {
    [string]        $SnapshotId
    [string]        $SnapshotPath
    [RestoreTarget] $Target
    [bool]          $LiveWritesAllowed
    [bool]          $Applied
    [bool]          $RolledBack
    [string]        $BackupPath      # copia del estado previo (vacio hasta aplicar)
    [string]        $TargetRoot      # carpeta destino cuando Target = Output
    [ConfigDiffResult] $Diff
    [System.Collections.Generic.List[RestoreFileAction]] $Files
    [System.Collections.Generic.List[string]]            $Warnings

    RestorePlan() {
        $this.SnapshotId        = ''
        $this.SnapshotPath      = ''
        $this.Target            = [RestoreTarget]::Output
        $this.LiveWritesAllowed = $false
        $this.Applied           = $false
        $this.RolledBack        = $false
        $this.BackupPath        = ''
        $this.TargetRoot        = ''
        $this.Files    = [System.Collections.Generic.List[RestoreFileAction]]::new()
        $this.Warnings = [System.Collections.Generic.List[string]]::new()
    }

    <#
        Cambios de ajuste que el preview de un Apply debe mostrar: SOLO los de
        `value`.

        ConfigDiffEngine::ComparedFields compara cinco campos (value, type,
        category, state, occurrences) porque para el historico de ConfigDiff.json
        los cinco son informacion real y nada se descarta. Pero para decidir si
        aplicar un snapshot los otros cuatro son ruido: que una convar se haya
        recategorizado o que su estado pase de Synced a Duplicated no cambia lo
        que el juego va a leer. El filtro vive AQUI, en la presentacion: A1 sigue
        publicando los cinco campos intactos.
    #>
    [object[]] ValueChanges() {
        $out = [System.Collections.Generic.List[object]]::new()
        foreach ($e in $this.Diff.Modified) {
            if (@($e['fields']) -contains 'value') { $out.Add($e) }
        }
        return @($out)
    }

    # Cambios detectados que el preview oculta por no afectar al valor.
    [int] HiddenChangeCount() {
        return $this.Diff.Modified.Count - $this.ValueChanges().Count
    }

    [int] WriteCount() {
        $n = 0
        foreach ($f in $this.Files) { if ($f.Status -ne 'identical') { $n++ } }
        return $n
    }

    <#
        Preview legible. Formato pensado para responder, en este orden, las tres
        preguntas que decide quien lo lee: donde va a escribir esto, que ajustes
        cambian de valor, y que archivos se tocan.
    #>
    [string] Render() {
        $sb = [System.Text.StringBuilder]::new()
        $mode = if ($this.Applied) { 'APLICADO' } elseif ($this.RolledBack) { 'REVERTIDO' } else { 'SOLO-MOSTRAR (nada escrito)' }
        [void]$sb.AppendLine("=== Restore del snapshot $($this.SnapshotId) -> $mode ===")
        if ($this.Target -eq [RestoreTarget]::LiveFiles) {
            [void]$sb.AppendLine('Destino: ARCHIVOS VIVOS DEL JUGADOR (se sobreescriben sus .vcfg/.cfg)')
        } else {
            [void]$sb.AppendLine("Destino: carpeta de salida ($($this.TargetRoot)); no se toca ningun archivo del jugador")
        }
        if (-not $this.Applied -and -not $this.RolledBack) {
            [void]$sb.AppendLine('Para escribir de verdad, repita el comando con -Apply.')
        }
        if ($this.BackupPath) {
            [void]$sb.AppendLine("Backup del estado previo: $($this.BackupPath)")
        }
        [void]$sb.AppendLine()

        $changes = $this.ValueChanges()
        [void]$sb.AppendLine(('-- Ajustes:  valor distinto {0} | altas {1} | bajas {2} | sin cambios {3}' -f
            $changes.Count, $this.Diff.Added.Count, $this.Diff.Removed.Count, $this.Diff.Unchanged))
        if ($this.HiddenChangeCount() -gt 0) {
            [void]$sb.AppendLine(('   (omitidas {0} diferencia(s) que no tocan el valor: solo type/category/state/occurrences)' -f
                $this.HiddenChangeCount()))
        }
        foreach ($e in $changes) {
            [void]$sb.AppendLine(('   ~ {0,-34} {1} -> {2}' -f [string]$e['key'], [string]$e['previousValue'], [string]$e['currentValue']))
        }
        foreach ($e in $this.Diff.Added) {
            [void]$sb.AppendLine(('   + {0,-34} (ausente) -> {1}' -f [string]$e['key'], [string]$e['value']))
        }
        foreach ($e in $this.Diff.Removed) {
            [void]$sb.AppendLine(('   - {0,-34} {1} -> (deja de estar)' -f [string]$e['key'], [string]$e['value']))
        }
        [void]$sb.AppendLine()

        [void]$sb.AppendLine(('-- Archivos: {0} a escribir de {1} en el snapshot' -f $this.WriteCount(), $this.Files.Count))
        foreach ($f in $this.Files) {
            $dest = if ($this.Target -eq [RestoreTarget]::LiveFiles) { $f.TargetPath } else { "$($f.TargetPath)  (original: $($f.OriginalPath))" }
            [void]$sb.AppendLine(('   {0,-10} {1,-28} {2} bytes  -> {3}' -f $f.Status, $f.Name, $f.Size, $dest))
        }
        if ($this.Warnings.Count -gt 0) {
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('-- Avisos:')
            foreach ($w in $this.Warnings) { [void]$sb.AppendLine("   ! $w") }
        }
        return ($sb.ToString() -replace "`r`n", "`n")
    }

    # Registro serializable de la operacion. Sin marcas de tiempo propias: el
    # determinismo de los artefactos es regla del proyecto, y la hora ya va en
    # el nombre de la carpeta de backup.
    [System.Collections.Specialized.OrderedDictionary] ToHashtable() {
        return [ordered]@{
            snapshotId   = $this.SnapshotId
            snapshotPath = $this.SnapshotPath
            target       = $this.Target.ToString()
            applied      = $this.Applied
            rolledBack   = $this.RolledBack
            backupPath   = $this.BackupPath
            targetRoot   = $this.TargetRoot
            settings     = [ordered]@{
                valueChanges = $this.ValueChanges().Count
                hidden       = $this.HiddenChangeCount()
                added        = $this.Diff.Added.Count
                removed      = $this.Diff.Removed.Count
                unchanged    = $this.Diff.Unchanged
            }
            files        = @($this.Files | ForEach-Object {
                [ordered]@{
                    name         = $_.Name
                    status       = $_.Status
                    size         = $_.Size
                    source       = $_.SourcePath
                    target       = $_.TargetPath
                    originalPath = $_.OriginalPath
                }
            })
            warnings     = @($this.Warnings)
        }
    }
}

class RestoreEngine {
    hidden [Logger] $Log
    hidden [string] $BackupRoot
    hidden [string] $OutputRoot

    RestoreEngine([Logger] $log, [string] $backupRoot, [string] $outputRoot) {
        $this.Log        = $log
        $this.BackupRoot = $backupRoot
        $this.OutputRoot = $outputRoot
    }

    # ------------------------------------------------------------ resolucion

    <#
        Id de snapshot a restaurar. 'latest' (o vacio) toma el mas reciente: los
        ids son `yyyyMMdd-HHmmss`, asi que el orden lexicografico descendente ya
        es el cronologico y no hace falta leer history.json.

        Un id inexistente no lanza un error opaco: dice donde busco y que hay
        disponible, que es lo unico accionable.
    #>
    [string] ResolveSnapshotId([string] $requested) {
        $ids = $this.AvailableSnapshotIds()
        if ([string]::IsNullOrWhiteSpace($requested) -or $requested.Trim().ToLowerInvariant() -eq 'latest') {
            if ($ids.Count -eq 0) {
                throw "No hay ningun snapshot en '$($this.BackupRoot)'. Ejecute primero un backup (sin -Restore) para crear uno."
            }
            return $ids[0]
        }
        $wanted = $requested.Trim()
        foreach ($id in $ids) { if ($id -eq $wanted) { return $id } }
        $available = if ($ids.Count -eq 0) { '(ninguno)' } else { ($ids -join ', ') }
        throw "No existe el snapshot '$wanted' en '$($this.BackupRoot)'. Disponibles: $available."
    }

    # Ids presentes en disco, del mas reciente al mas antiguo.
    [string[]] AvailableSnapshotIds() {
        if (-not (Test-Path -LiteralPath $this.BackupRoot)) { return @() }
        $dirs = @(Get-ChildItem -LiteralPath $this.BackupRoot -Directory -ErrorAction SilentlyContinue)
        if ($dirs.Count -eq 0) { return @() }
        # Orden ordinal descendente a proposito: Sort-Object compara segun la
        # cultura activa y "cual es el ultimo snapshot" no puede depender de eso.
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($d in $dirs) { $names.Add($d.Name) }
        $arr = $names.ToArray()
        [array]::Sort($arr, [System.StringComparer]::Ordinal)
        [array]::Reverse($arr)
        return $arr
    }

    <#
        Reconstruye el GameConfig del snapshot desde su Inventory.json.

        La categoria autoritativa es la del BLOQUE que contiene al ajuste, no el
        campo `category` del ajuste: ese sale de Setting::CategoryCode, que vale
        P48 por defecto y solo rellena SyncEngine. Misma regla que
        ConfigDiffEngine, para que el preview no invente cambios de categoria.
    #>
    [GameConfig] ConfigFromInventory([string] $snapshotId) {
        $path = Join-Path (Join-Path $this.BackupRoot $snapshotId) 'Inventory.json'
        if (-not (Test-Path -LiteralPath $path)) {
            throw ("El snapshot '$snapshotId' no tiene inventario ($path), asi que no se puede saber que cambiaria. " +
                   'Elija otro snapshot o vuelva a generarlo con un backup.')
        }
        $parsed = $null
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8
            if ([string]::IsNullOrWhiteSpace($raw)) {
                throw "el archivo esta vacio"
            }
            $parsed = $raw | ConvertFrom-Json
        } catch {
            throw "El inventario del snapshot '$snapshotId' es ilegible o corrupto ($path): $($_.Exception.Message). Elija otro snapshot."
        }
        if ($null -eq $parsed -or $null -eq $parsed.PSObject.Properties['categories']) {
            throw "El inventario del snapshot '$snapshotId' no tiene la forma esperada (sin 'categories'): $path. Elija otro snapshot."
        }

        $cfg = [GameConfig]::new()
        $buckets = [System.Collections.Generic.SortedDictionary[string, object]]::new([System.StringComparer]::Ordinal)
        $loaded = 0
        foreach ($cat in @($parsed.categories)) {
            if ($null -eq $cat) { continue }
            $code = [string]$this.NodeField($cat, 'code', '')
            if ([string]::IsNullOrWhiteSpace($code)) { $code = 'P48' }
            foreach ($node in @($this.NodeField($cat, 'settings', @()))) {
                $setting = [Setting]::FromHashtable($node)
                if ($null -eq $setting) { continue }
                $setting.CategoryCode = $code
                $sortKey = '{0:D5}|{1}' -f [CategoryMap]::OrderFor($code), $code
                if (-not $buckets.ContainsKey($sortKey)) {
                    $buckets[$sortKey] = [ConfigCategory]::new($code, [CategoryMap]::NameFor($code), [CategoryMap]::OrderFor($code))
                }
                ([ConfigCategory]$buckets[$sortKey]).Add($setting)
                $loaded++
            }
        }
        if ($loaded -eq 0) {
            throw ("El inventario del snapshot '$snapshotId' no contiene ningun ajuste utilizable ($path). " +
                   'Restaurarlo dejaria la configuracion vacia, asi que se detiene aqui.')
        }
        foreach ($cat in $buckets.Values) { $cfg.Categories.Add([ConfigCategory]$cat) }
        $this.Log.Info("Snapshot ${snapshotId}: $loaded ajustes rehidratados del inventario.")
        return $cfg
    }

    # --------------------------------------------------------------- plan

    <#
        Construye el plan. NO escribe nada: es el modo por defecto del CLI.

        El preview semantico es el diff de A1 calculado al reves: la base es la
        config viva y el objetivo el inventario del snapshot, asi que "cambio"
        significa "cambiaria al aplicar". No hay comparador nuevo.
    #>
    [RestorePlan] Plan([string] $snapshotId, [GameConfig] $live, [RestoreTarget] $target, [bool] $allowLiveWrites) {
        if ($null -eq $live) {
            throw 'No se puede previsualizar un restore sin la configuracion viva: es la base de comparacion.'
        }
        if ($target -eq [RestoreTarget]::LiveFiles -and -not $allowLiveWrites) {
            throw ('Escribir sobre los archivos vivos del jugador exige el permiso explicito -AllowLiveFileWrites. ' +
                   'Sin el, use el destino por defecto (Output), que escribe en la carpeta de salida.')
        }

        $resolved = $this.ResolveSnapshotId($snapshotId)
        $dir = Join-Path $this.BackupRoot $resolved

        $plan = [RestorePlan]::new()
        $plan.SnapshotId        = $resolved
        $plan.SnapshotPath      = $dir
        $plan.Target            = $target
        $plan.LiveWritesAllowed = $allowLiveWrites
        $plan.TargetRoot        = Join-Path (Join-Path $this.OutputRoot 'restore') $resolved

        $snapCfg = $this.ConfigFromInventory($resolved)
        $plan.Diff = [ConfigDiffEngine]::new($this.Log).CompareConfigs(
            $live, $snapCfg, 'config viva', "snapshot $resolved")

        $this.PlanFiles($plan)
        $this.Log.Info(("Plan de restore $resolved -> $($target): $($plan.ValueChanges().Count) cambios de valor, " +
                        "$($plan.WriteCount()) archivos a escribir."))
        return $plan
    }

    <#
        Empareja cada archivo del Manifest.json con su copia fiel en `raw/`.

        SnapshotManager::Create copia los archivos en el mismo orden en que los
        lista el manifiesto y desambigua las colisiones de nombre anadiendo
        `_1`, `_2`... Aqui se recorre el manifiesto en ese mismo orden y se toma
        el siguiente candidato libre, con lo que se reproduce exactamente el
        emparejamiento original. Ademas se COMPRUEBA el hash del manifiesto: si
        no cuadra, el archivo se excluye con un aviso en lugar de escribir bytes
        equivocados encima de la config del jugador.
    #>
    hidden [void] PlanFiles([RestorePlan] $plan) {
        $rawDir = Join-Path $plan.SnapshotPath 'raw'
        if (-not (Test-Path -LiteralPath $rawDir)) {
            $plan.Warnings.Add("El snapshot no conserva copias en '$rawDir': se puede previsualizar, pero no hay nada que escribir.")
            return
        }
        $rawFiles = @{}
        foreach ($f in @(Get-ChildItem -LiteralPath $rawDir -File -ErrorAction SilentlyContinue)) {
            $rawFiles[$f.Name] = $f
        }

        $entries = $this.ManifestEntries($plan)
        $claimed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $used    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($entry in $entries) {
            $declaredName = [string]$this.NodeField($entry, 'name', '')
            $originalPath = [string]$this.NodeField($entry, 'path', '')
            if ([string]::IsNullOrWhiteSpace($declaredName) -and $originalPath) {
                $declaredName = Split-Path -Leaf $originalPath
            }
            if ([string]::IsNullOrWhiteSpace($declaredName)) { continue }

            $copy = $this.NextFreeCopy($rawFiles, $claimed, $declaredName)
            if ($null -eq $copy) {
                $plan.Warnings.Add("El manifiesto declara '$declaredName' pero el snapshot no guarda su copia en raw/: se omite.")
                continue
            }
            $claimed.Add($copy.Name) | Out-Null

            $declaredHash = [string]$this.NodeField($entry, 'hash', '')
            if ($declaredHash) {
                $actual = Get-FileHashSafe -Path $copy.FullName
                if ($actual -and $actual -ne $declaredHash.ToLowerInvariant()) {
                    $plan.Warnings.Add(("La copia '$($copy.Name)' no coincide con el hash que el manifiesto declara para " +
                        "'$declaredName': se omite para no escribir contenido equivocado."))
                    continue
                }
            }

            $action = [RestoreFileAction]::new()
            $action.Name         = $declaredName
            $action.SourcePath   = $copy.FullName
            $action.OriginalPath = $originalPath
            $action.Size         = $copy.Length
            $action.TargetPath   = $this.TargetPathFor($plan, $declaredName, $originalPath, $used)
            $used.Add($action.TargetPath) | Out-Null
            $action.Status       = $this.StatusFor($copy.FullName, $action.TargetPath)
            $plan.Files.Add($action)
        }

        foreach ($name in $rawFiles.Keys) {
            if ($claimed.Contains($name)) { continue }
            $plan.Warnings.Add("La copia '$name' esta en raw/ pero el manifiesto no la menciona: se omite (sin manifiesto no se sabe a donde va).")
        }
        if ($plan.Files.Count -eq 0) {
            $plan.Warnings.Add('No hay ningun archivo aplicable en este snapshot.')
        }
    }

    <#
        Entradas de archivo del Manifest.json, en el orden en que se escribieron.
        Sin manifiesto no hay ruta de destino posible: el preview semantico sigue
        siendo valido (sale del inventario), pero no se puede escribir nada,
        porque adivinar donde va cada `.vcfg` seria justo el tipo de suposicion
        que esta clase no hace sobre archivos del jugador.
    #>
    hidden [object[]] ManifestEntries([RestorePlan] $plan) {
        $path = Join-Path $plan.SnapshotPath 'Manifest.json'
        if (-not (Test-Path -LiteralPath $path)) {
            $plan.Warnings.Add("El snapshot no tiene Manifest.json ($path): no se sabe a donde va cada archivo, asi que no se escribira ninguno.")
            return @()
        }
        try {
            $parsed = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
        } catch {
            $plan.Warnings.Add("Manifest.json ilegible ($path): $($_.Exception.Message). No se escribira ningun archivo.")
            return @()
        }
        $files = $this.NodeField($parsed, 'files', $null)
        if ($null -eq $files) {
            $plan.Warnings.Add("Manifest.json no lista archivos ($path). No se escribira ninguno.")
            return @()
        }
        return @($files)
    }

    # Siguiente copia libre para un nombre declarado, replicando el sufijo `_N`
    # con el que SnapshotManager::UniquePath desambiguo las colisiones.
    hidden [object] NextFreeCopy([hashtable] $rawFiles, [System.Collections.Generic.HashSet[string]] $claimed, [string] $declaredName) {
        if ($rawFiles.ContainsKey($declaredName) -and -not $claimed.Contains($declaredName)) {
            return $rawFiles[$declaredName]
        }
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($declaredName)
        $ext  = [System.IO.Path]::GetExtension($declaredName)
        for ($i = 1; $i -le $rawFiles.Count; $i++) {
            $candidate = '{0}_{1}{2}' -f $stem, $i, $ext
            if ($rawFiles.ContainsKey($candidate) -and -not $claimed.Contains($candidate)) {
                return $rawFiles[$candidate]
            }
        }
        return $null
    }

    # Ruta que se escribiria. En Output se aplana a nombre de hoja bajo
    # `<salida>/restore/<id>/files/`, desambiguando si dos originales comparten
    # nombre; en LiveFiles es la ruta viva tal cual la anoto el manifiesto.
    hidden [string] TargetPathFor([RestorePlan] $plan, [string] $declaredName, [string] $originalPath,
                                  [System.Collections.Generic.HashSet[string]] $used) {
        if ($plan.Target -eq [RestoreTarget]::LiveFiles) {
            if ([string]::IsNullOrWhiteSpace($originalPath)) {
                throw ("El manifiesto no dice donde vivia '$declaredName', asi que no se puede restaurar sobre los archivos " +
                       'del jugador. Use el destino por defecto (Output) y copielo a mano.')
            }
            return $originalPath
        }
        $dir = Join-Path $plan.TargetRoot 'files'
        $leaf = if ($originalPath) { Split-Path -Leaf $originalPath } else { $declaredName }
        $candidate = Join-Path $dir $leaf
        if (-not $used.Contains($candidate)) { return $candidate }
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
        $ext  = [System.IO.Path]::GetExtension($leaf)
        for ($i = 1; $i -lt 10000; $i++) {
            $candidate = Join-Path $dir ('{0}_{1}{2}' -f $stem, $i, $ext)
            if (-not $used.Contains($candidate)) { return $candidate }
        }
        throw "Demasiadas colisiones de nombre para '$leaf' en $dir."
    }

    hidden [string] StatusFor([string] $sourcePath, [string] $targetPath) {
        if (-not (Test-Path -LiteralPath $targetPath)) { return 'create' }
        $a = Get-FileHashSafe -Path $sourcePath
        $b = Get-FileHashSafe -Path $targetPath
        if ($a -and $b -and $a -eq $b) { return 'identical' }
        return 'overwrite'
    }

    # -------------------------------------------------------------- aplicar

    <#
        Ejecuta el plan. Unico metodo de esta clase que escribe.

        Devuelve el mismo plan, ya con Applied/BackupPath/RolledBack rellenos,
        para que el CLI pueda volver a renderizarlo y mostrar lo que de verdad
        paso.
    #>
    [RestorePlan] Apply([RestorePlan] $plan) {
        if ($plan.Target -eq [RestoreTarget]::LiveFiles -and -not $plan.LiveWritesAllowed) {
            throw 'Este plan no tiene permiso para escribir sobre los archivos vivos del jugador.'
        }
        $pending = @($plan.Files | Where-Object { $_.Status -ne 'identical' })
        if ($pending.Count -eq 0) {
            $this.Log.Info('Restore: nada que escribir, el destino ya coincide con el snapshot.')
            $plan.Applied = $true
            $this.WriteRecord($plan)
            return $plan
        }

        # Fase 0: precondiciones. Mejor abortar sin haber tocado nada.
        foreach ($f in $pending) {
            if ((Test-Path -LiteralPath $f.TargetPath) -and (Test-Path -LiteralPath $f.TargetPath -PathType Container)) {
                throw "El destino '$($f.TargetPath)' existe y no es un archivo. Se aborta sin escribir nada."
            }
            if (-not (Test-Path -LiteralPath $f.SourcePath)) {
                throw "La copia '$($f.SourcePath)' ya no esta en el snapshot. Se aborta sin escribir nada."
            }
        }

        # Fase 1: backup del estado actual. Es lo que hace reversible la fase 2.
        # La carpeta se crea la primera vez que hay algo que copiar: un destino
        # que todavia no existe se revierte borrandolo, y dejar carpetas de
        # backup vacias solo ensuciaria la salida.
        $stamp   = [datetime]::Now.ToString('yyyyMMdd-HHmmss')
        $destDir = Join-Path (Join-Path (Join-Path $this.OutputRoot 'restore') $plan.SnapshotId) "backup-$stamp"

        $saved   = [System.Collections.Generic.List[object]]::new()   # destino -> copia previa (o $null si no existia)
        $index   = 0
        foreach ($f in $pending) {
            $index++
            $record = [ordered]@{ action = $f; backup = $null }
            if (Test-Path -LiteralPath $f.TargetPath) {
                if (-not $plan.BackupPath) {
                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                    $plan.BackupPath = $destDir
                }
                $copyName = '{0:D3}_{1}' -f $index, (Split-Path -Leaf $f.TargetPath)
                $record.backup = Join-Path $plan.BackupPath $copyName
                Copy-Item -LiteralPath $f.TargetPath -Destination $record.backup -Force
            }
            $saved.Add($record)
        }
        if ($plan.BackupPath) {
            $this.Log.Info("Restore: estado previo respaldado en $($plan.BackupPath)")
        }

        # Fase 2: escritura, reversible entera.
        $written     = [System.Collections.Generic.List[object]]::new()
        $createdDirs = [System.Collections.Generic.List[string]]::new()
        try {
            foreach ($record in $saved) {
                $f = [RestoreFileAction]$record.action
                $dir = Split-Path -Parent $f.TargetPath
                if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
                    $createdDirs.Add($dir)
                }
                [System.IO.File]::WriteAllBytes($f.TargetPath, [System.IO.File]::ReadAllBytes($f.SourcePath))
                $written.Add($record)
                $this.Log.Debug("Restore: escrito $($f.TargetPath)")
            }
        } catch {
            $reason = $_.Exception.Message
            $this.Log.Error("Restore abortado a mitad: $reason")
            $this.Rollback($plan, $written, $createdDirs)
            $plan.RolledBack = $true
            $this.WriteRecord($plan)
            $where = if ($plan.BackupPath) { " El estado previo se restauro desde $($plan.BackupPath)." } else { '' }
            throw "Restore abortado y revertido: $reason.$where No queda ningun archivo a medias."

        }

        $plan.Applied = $true
        $this.Log.Info("Restore aplicado: $($written.Count) archivos escritos en $($plan.Target).")
        $this.WriteRecord($plan)
        return $plan
    }

    <#
        Deshace las escrituras ya hechas, en orden inverso: devuelve los bytes
        previos a los archivos que existian y borra los que se crearon. Un fallo
        aqui no se silencia ni interrumpe el resto: se intenta deshacer todo y
        cada fallo queda como aviso en el plan y como error en el log, porque un
        rollback incompleto es exactamente lo que el usuario necesita saber.
    #>
    hidden [void] Rollback([RestorePlan] $plan, [System.Collections.Generic.List[object]] $written,
                           [System.Collections.Generic.List[string]] $createdDirs) {
        for ($i = $written.Count - 1; $i -ge 0; $i--) {
            $record = $written[$i]
            $f = [RestoreFileAction]$record.action
            try {
                if ($null -ne $record.backup) {
                    [System.IO.File]::WriteAllBytes($f.TargetPath, [System.IO.File]::ReadAllBytes([string]$record.backup))
                } elseif (Test-Path -LiteralPath $f.TargetPath) {
                    Remove-Item -LiteralPath $f.TargetPath -Force
                }
            } catch {
                $msg = "No se pudo revertir '$($f.TargetPath)': $($_.Exception.Message). Copia previa en $($record.backup)."
                $plan.Warnings.Add($msg)
                $this.Log.Error($msg)
            }
        }
        for ($i = $createdDirs.Count - 1; $i -ge 0; $i--) {
            $dir = $createdDirs[$i]
            try {
                if ((Test-Path -LiteralPath $dir) -and
                    @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item -LiteralPath $dir -Force
                }
            } catch {
                $this.Log.Warn("No se pudo quitar la carpeta creada '$dir': $($_.Exception.Message)")
            }
        }
        $this.Log.Info('Restore revertido: el estado previo quedo restaurado.')
    }

    # Registro de la operacion junto a los archivos restaurados, para que quede
    # rastro de que se escribio, desde donde y donde esta el backup.
    hidden [void] WriteRecord([RestorePlan] $plan) {
        $dir = Join-Path (Join-Path $this.OutputRoot 'restore') $plan.SnapshotId
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        ($plan.ToHashtable() | ConvertTo-Json -Depth 8) |
            Out-File -LiteralPath (Join-Path $dir 'RestorePlan.json') -Encoding utf8
    }

    # Lectura tolerante de un campo, venga de JSON o de una tabla hash.
    hidden [object] NodeField([object] $obj, [string] $field, [object] $default) {
        if ($null -eq $obj) { return $default }
        if ($obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($field) -and $null -ne $obj[$field]) { return $obj[$field] }
            return $default
        }
        $p = $obj.PSObject.Properties[$field]
        if ($null -eq $p -or $null -eq $p.Value) { return $default }
        return $p.Value
    }
}
