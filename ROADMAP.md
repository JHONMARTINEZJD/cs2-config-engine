# Roadmap

Estado durable del desarrollo. Lo mantiene el agente `pm` (`.claude/agents/pm.md`)
y cualquiera puede editarlo a mano. Una tarea se marca hecha solo cuando esta
implementada, probada, verificada ejecutando y commiteada.

Rama de trabajo: `claude/zealous-lovelace-htuxyu`

Supuestos de producto tomados en A1 (opcion conservadora, revisables por el dueno):

1. **Que cuenta como "cambiada".** Una clave se reporta como cambiada si se movio
   cualquiera de `value`, `type`, `category`, `state` u `occurrences`, y la entrada
   dice en `fields` cual. El hash no entra en la comparacion porque se deriva de
   nombre+valor y seria redundante; se reporta, pero no decide. Motivo: recategorizar
   un bind sin cambiar su comando es informacion real y ocultarla contradiria el
   principio de que nada se pierde.
2. **Totales por clave, no por fila.** `previousTotal`/`currentTotal` cuentan claves
   distintas. Los duplicados conservados no inflan los totales; su numero viaja en
   `occurrences` de cada entrada y un cambio en ese numero se reporta como cambio.
3. **Tope de filas en el Markdown.** `BackupReport.md` muestra como maximo 50 filas
   por tabla (`ReportGenerator::DiffRowLimit`) y avisa del corte. La lista completa
   siempre esta en `ConfigDiff.json`, que es la fuente de la verdad; el corte es
   determinista porque las entradas ya vienen ordenadas.

Supuestos de producto tomados en A2 (opcion conservadora, revisables por el dueno):

4. **Un restore escribe copias fieles, no archivos regenerados.** Se escriben los
   archivos que el snapshot guardo en `raw/`, byte a byte, y NO una reconstruccion
   de los `.vcfg` desde `Inventory.json`. No existe un escritor de `.vcfg` y
   fabricar uno a ciegas para sobreescribir archivos del jugador seria la decision
   arriesgada. Consecuencia conocida: un snapshot sin `raw/` (rotado, copiado a
   medias) se puede previsualizar pero no aplicar, y se dice con un aviso. El dia
   que exista un escritor de `.vcfg` (o si el dueno prefiere aplicar ajuste por
   ajuste) esto se puede ampliar sin tocar el preview.
5. **Sin `Manifest.json` no se escribe nada.** El destino de cada archivo sale del
   manifiesto del snapshot. Adivinar donde vive un `.vcfg` es exactamente la
   suposicion que no se hace sobre archivos del jugador.
6. **La copia de seguridad del restore ES el backup previo exigido**, no un
   snapshot nuevo: `<salida>/restore/<id>/backup-<ts>/` guarda el contenido
   anterior de cada destino tocado y se conserva despues de aplicar. Tomar un
   snapshot completo antes de restaurar acoplaria el restore al descubrimiento y
   al historial, y rotaria snapshots utiles.
7. **Dos banderas, no una.** `-RestoreTarget LiveFiles` y `-AllowLiveFileWrites`
   son parametros distintos a proposito: equivocarse en uno no puede llegar a
   escribir sobre la configuracion real. La puerta se comprueba en el motor, al
   planificar, no solo en el CLI.

Supuestos de producto tomados en A3 (opcion conservadora, revisables por el dueno):

8. **El catalogo generado complementa a `fallbacks.json`; no lo sustituye.**
   `config/fallbacks.json` sigue siendo la lista CURADA de convars que se inyectan
   en el autoexec cuando faltan, y `config/convars.json` (generado) aporta SOLO
   metadatos (default, tipo, descripcion) y no inyecta ninguna entrada. Motivo: el
   catalogo real tendra miles de entradas e inyectarlas convertiria el autoexec en
   un listado del motor en lugar de en la configuracion del jugador, y multiplicaria
   cada snapshot. En los metadatos manda lo curado y el generado rellena huecos. La
   regla intocable no se mueve: los fallbacks solo se aplican a variables AUSENTES y
   nunca sobreescriben la configuracion viva.
9. **Ausencia del volcado no es obsolescencia.** Una convar que no aparezca en el
   volcado NO se marca obsoleta: el volcado puede estar truncado o ser de otra build,
   y deducir obsolescencia de una ausencia contradiria que la configuracion viva
   manda. La lista `deprecated` sigue siendo curada.
10. **La procedencia se firma con el hash, no con el reloj.** `source.label` lo pone
    el usuario (`-CatalogLabel`, la build o la fecha) y siempre se guarda el sha256
    del volcado. NO se usa la fecha de modificacion del archivo: copiarlo la cambia y
    el catalogo dejaria de ser reproducible desde el mismo contenido. Sin etiqueta se
    firma con el prefijo del sha256 y se avisa.
11. **Los concommands van en una seccion aparte.** No tienen valor por defecto y no
    se pueden escribir como asignacion en un autoexec, asi que nunca pueden colarse
    como convars. Se conservan porque nada se descarta.

---

## Modulo A — Motor de configuracion

### Hecho

- [x] **Arranque del launcher.** `run.ps1` invocaba `Ensure-Dependencies -AllowInstall $true`;
      un `[switch]` no acepta el valor separado, el enlace de parametros fallaba con
      error terminante y tumbaba `run.bat`, `run.cmd`, `run.ps1` y `launch.ps1`. (`6e4a93b`)
- [x] **Descubrimiento fuera de Windows.** `$env:SystemDrive` nulo hacia reventar
      `Join-Path` en lugar de lanzar el error controlado que pide `-SteamPath`. (`6e4a93b`)
- [x] **Categorias perdidas del autoexec.** El exportador recorria una lista literal
      de 45 nombres; el catalogo tiene 50. Bob, Spectator, Demo, GOTV y Practice
      desaparecian del archivo generado. Ahora los bloques se derivan de
      `CategoryMap::Blocks` y `AssertComplete()` falla si una categoria queda
      huerfana. (`d1b59f3`)
- [x] **Encabezados de bloque duplicados.** Se imprimian una vez por categoria. (`d1b59f3`)
- [x] **Autoexec ejecutable.** Obsoletas, duplicados, invalidas y claves no
      reconocidas se emiten comentadas con su motivo en lugar de crudas. P49 sigue
      activo: tiene forma de convar valida y comentarlo romperia config real. (`d1b59f3`)
- [x] **Catch-all de clasificacion.** La regla `(cl_|sv_|developer|hud_)` de P44
      absorbia toda convar `cl_`/`sv_` sin clasificar y dejaba P48/P49 inalcanzables.
      Patrones acotados con `(?:^|[\s;])` y P44 con convars de desarrollo reales. (`d1b59f3`)
- [x] **Basura con mayusculas.** `Classifier` usaba `-match`, insensible a caso, asi
      que claves como `JugadorNombre` pasaban por convar valida. Ahora `-cmatch`. (`d1b59f3`)
- [x] **Alias circulares.** DFS con pila de recursion; antes un grafo en diamante sin
      ciclos se reportaba como error. El mensaje incluye el ciclo concreto. (`d1b59f3`)
- [x] **Tipos de fallback.** Respetan el campo `type` del catalogo en lugar de entrar
      siempre como `Unknown`, que falseaba los conteos del snapshot. (`d1b59f3`)
- [x] **Higiene.** Codigo muerto de `CfgParser` reconectado, `ConfigModule` eliminado,
      `run.ps1` migrado a la API de Pester 5, `.gitignore`, CI en `windows-latest`,
      fuera `tmp_debug.ps1` y `output/pester-results.xml`. (`d1b59f3`)
- [x] **Prerrequisito de A2 — `Setting::FromHashtable()`.** Inverso completo de
      `ToHashtable()` (valor, tipo, prioridad, estado, categoria, `Extra` y metadatos),
      con la misma tolerancia que tenia la rehidratacion parcial del diff. `ConfigDiffEngine`
      la consume y su `ParseType` local desaparece; ahora los dos origenes posibles de una
      fila del indice (config viva e inventario) pasan por `EntryFromSetting`. (`179b2b3`)
- [x] **A2 — `Restore` / `Apply` con rollback.** Clase nueva `RestoreEngine`
      (`src/Backup/RestoreEngine.ps1`, cargada despues de `Reporting/ConfigDiff.ps1`
      porque sus firmas referencian `[ConfigDiffEngine]`). Modo por defecto solo-mostrar;
      destino por defecto la carpeta de salida; escribir sobre los `.vcfg`/`.cfg` del
      jugador exige `-RestoreTarget LiveFiles` **y** `-AllowLiveFileWrites`, backup previo
      en `<salida>/restore/<id>/backup-<ts>/` y rollback atomico en tres fases. El preview
      es el diff de A1 al reves via `ConfigDiffEngine::CompareConfigs`, filtrado a los
      cambios de `value` en la presentacion. Superficie del CLI: `-Restore <id|latest>`,
      `-Apply`, `-RestoreTarget`, `-AllowLiveFileWrites`. (`179b2b3`)
- [x] **A1 — Diff semantico entre snapshots.** `ConfigDiff.json` ya reporta altas, bajas
      y cambios **por ajuste** con valor antes y despues, identificados por
      `Setting::Key()` (`bind::<tecla>`, `alias::<nombre>`, nombre de convar) y
      agrupados por categoria, mas un resumen legible con tabla de cambiadas en
      `BackupReport.md`. Clase nueva `ConfigDiffEngine` en `src/Reporting/ConfigDiff.ps1`;
      la base de comparacion es el `Inventory.json` del snapshot anterior, cuya ruta
      resuelve `SnapshotManager::GetInventoryPath`. (`18059fa`)

- [x] **A3 (mitad construible) — Importador de volcados de `cvarlist` y catalogo
      generado.** Clases nuevas en `src/Catalog/`: `CvarListParser` (parser tolerante
      del volcado, tres hipotesis de formato nombradas y auditables) y
      `ConvarCatalogBuilder` + `ConvarCatalog` (genera y lee `config/convars.json`,
      determinista y con la procedencia del volcado dentro). Entrada de CLI
      `-ImportCvarList` / `-CatalogLabel` / `-CatalogPath`, documentada en el README
      con los comandos exactos de la consola de CS2. Puente con lo que ya existia:
      `FallbackCatalog` gana una segunda capa (`HasMetadata`/`GetMetadata`/
      `InjectableNames`) donde manda lo curado y el generado rellena huecos, sin
      inyectar nada nuevo. De paso, la inferencia de tipo que estaba duplicada en
      `CfgParser` y `VcfgParser` pasa a `Setting::InferTypeFromValue()` y la usan los
      dos parsers y el catalogo, para que el mismo valor no se tipe distinto segun
      quien lo lea. 53 pruebas nuevas con fixtures sinteticos; las 98 anteriores
      siguen pasando. (`021adbe`)

### Siguiente

- [ ] **A3 (lo que falta) — cerrar el catalogo con un volcado REAL.** Bloqueado por
      el dueno, no por el codigo: en este contenedor no hay CS2 y no existe ningun
      volcado real, asi que el formato de `cvarlist` de CS2 sigue siendo una
      HIPOTESIS (`source.formatVerified = false` en el catalogo generado). Lo que hace
      falta, en concreto:
        1. El archivo `cvars.txt` generado con `con_logfile cvars.txt; cvarlist;
           con_logfile ""`, y la build del juego para `-CatalogLabel`.
        2. Ejecutar `-ImportCvarList` y mirar la seccion `unrecognized` del catalogo:
           cada linea de ahi es una fila que ninguna de las tres hipotesis supo leer.
           Con eso se ajustan las hipotesis (o se anade una cuarta) y se amplia
           `CvarListParser::KnownFlags` con las banderas que CS2 imprima de verdad.
        3. Comprobar `source.shapes` para saber cual de las tres hipotesis acerto, y
           `looksTruncated` para descartar que el volcado se corto.
        4. Cuando el formato quede confirmado, poner `formatVerified` a true y
           decidir con datos si el catalogo puede empezar a alimentar tambien la
           clasificacion (P00..P49) y la deteccion de convars retiradas, que HOY NO
           HACE a proposito.
      Puntos de extension dejados listos y sin fabricar: `CvarListParser::KnownFlags`,
      `CvarListParser::NoisePatterns` y `MaxFlagsFieldIndex` son datos estaticos
      ampliables, y cada entrada del catalogo publica en `shape` la hipotesis que
      encajo para poder auditarlo fila a fila.
- [ ] **A4 — Perfiles portables.** Exportar e importar un perfil con su hash para
      llevar la config a otra maquina o compartirla. Depende de A1. Con A2 cerrada ya
      tiene la mitad hecha: `Setting::FromHashtable()` da la importacion ajuste por
      ajuste y `RestoreEngine` da el preview y el rollback. Lo que falta de verdad es
      un escritor de `.vcfg` (o decidir que un perfil se aplica siempre via
      `autoexec.cfg`, que es la opcion sin riesgo).
- [ ] **A5 — Empaquetar como modulo PowerShell** (`.psd1` + `.psm1`) en lugar de
      dot-sourcear los 21 archivos de `src` uno a uno. Da `Import-Module`, version semantica y distribucion
      sin el `iex` contra una rama sin verificar.

## Modulo B — Lista publica de servidores

- [ ] **B1 — Obtener la lista.** Via `IGameServersService/GetServerList/v1` con API key
      y filtro `\appid\730\dedicated\1`, o el master server UDP
      (`hl2master.steampowered.com:27011`) sin key.
- [ ] **B2 — Medir de verdad.** `A2S_INFO` con 5-10 muestras por servidor, reportando
      **minimo, mediana y jitter**, no el promedio. El jitter es lo que se siente:
      45 ms con 30 de jitter juega peor que 70 estable. Ninguna herramienta del nicho
      da esto, es el diferenciador.
- [ ] **B3 — Historico.** Reutilizar `SnapshotManager` para saber que servidores son
      buenos **a que hora**. Informacion que hoy no existe en ninguna herramienta.
- [ ] **B4 — Salida a `.cfg`.** Aliases `connect` de favoritos al autoexec; cierra el
      circulo con el modulo A.

`System.Net.Sockets.UdpClient` y `ForEach-Object -Parallel` cubren esto en
PowerShell; no hace falta cambiar de lenguaje.

## Modulo C — Relays y ping

- [ ] **C1 — Palanca oficial primero.** Escribir `mm_dedicated_search_maxping` al
      autoexec segun latencia medida. Sin privilegios, sin riesgo, soportado por
      Valve. Es el modo por defecto.
- [ ] **C2 — POPs SDR.** Traer la config de
      `https://api.steampowered.com/ISteamApps/GetSDRConfig/v1?appid=730` y medir RTT
      por relay para ordenar por latencia medida, no por pais.
      **Los nombres de campo no estan verificados** (el proxy del contenedor bloquea
      ese host): modelar sobre la respuesta real.
- [ ] **C3 — Modo picker, opt-in.** Reglas de firewall con prefijo propio
      (`CS2CE-block-<pop>`) para poder limpiarlas sin tocar reglas ajenas, estado
      previo guardado en el snapshot, y limpieza atomica si el proceso muere.
      Requiere administrador. Avisos claros: SDR reenruta incluso a mitad de partida,
      y bloquear de mas produce colas eternas.
- [ ] **C4 — Medir bufferbloat.** Lo que de verdad baja la latencia percibida y casi
      ninguna herramienta reporta. Aportaria mas que todos los pickers juntos.

## Deuda conocida

- [ ] `SteamDiscovery` y `CS2Discovery` leen `libraryfolders.vdf` y
      `appmanifest_730.acf` con regex, teniendo `VdfParser` ya cargado. Contradice el
      discurso del README sobre no usar regex ingenuas. El `-replace '\\\\','\'` es un
      unescape parcial.
- [ ] El paso de PSScriptAnalyzer del CI no se ha podido ejecutar localmente (PSGallery
      bloqueada). Los archivos de clases no parsean en aislamiento, asi que lleva
      `-ErrorAction SilentlyContinue` para que ese ruido no de un rojo falso. Revisar
      en el primer run real.
- [ ] Sin `LICENSE`.
- [ ] El motor es Windows-only en la practica (rutas con `\` literal), no solo
      "Windows recomendado" como dice el README.
- [x] ~~`Setting` no tiene inverso de `ToHashtable()`.~~ Resuelto con
      `Setting::FromHashtable()` como prerrequisito de A2 (`179b2b3`).
- [x] **Un metodo de clase declarado `[string]` no puede devolver `$null`.**
      PowerShell CONVIERTE lo devuelto al tipo declarado, asi que `return $null` en un
      metodo `[string]` sale como cadena VACIA. El troceador de `cvarlist` usaba
      `if ($null -ne $sep)` para decidir si habia separador, daba por bueno uno de
      longitud cero y el bucle no avanzaba nunca: el parser se colgaba con la entrada
      mas tonta posible (`abc`). Ahora la ausencia se representa con cadena vacia y se
      comprueba con `IsNullOrEmpty`. Ojo: con los tipos por referencia (`[hashtable]`,
      una clase propia, `[string[]]`) `$null` SI viaja como `$null`; el problema es
      exclusivo de `[string]` y de los tipos de valor.
- [ ] **El formato de `cvarlist` de CS2 no esta verificado.** Todo lo que asume el
      parser esta documentado en la cabecera de `src/Catalog/CvarListParser.ps1` y
      marcado en el catalogo con `source.formatVerified = false`. No es deuda de
      diseno: es un dato que falta y que solo puede traer el dueno.
- [ ] **No hay `config/convars.json` en el repositorio, y es deliberado.** Generarlo
      desde el fixture sintetico y commitearlo meteria convars inventadas en el
      producto. El motor funciona sin el.
- [ ] **Una variable local no puede llamarse igual que una propiedad de su clase.**
      Dentro de un metodo de clase de PowerShell, `$name = ...` falla al parsear con
      "Cannot assign property, use '$this.Name'" si la clase tiene una propiedad
      `Name`, tambien en metodos estaticos, donde no hay `$this`. Por eso
      `FromHashtable` usa `$settingName` y `$extraNode`. No esta documentado en
      ningun sitio obvio y cuesta un ciclo cada vez.
- [x] **El emparejamiento entre `Manifest.json` y `raw/` ya es explicito.** `Create`
      anota en el snapshot con que nombre quedo cada copia (`RawNames`) y el manifiesto
      lo publica como `rawName`; el restore lo usa y solo reconstruye por orden si el
      manifiesto es antiguo y no lo trae. Verificado con el caso que lo motivaba: dos
      `config.cfg` en carpetas distintas, guardados como `config.cfg` y `config_1.cfg`,
      vuelven cada uno a SU archivo.
- [x] **El restore avisa de los ajustes que sobreviven.** Si la configuracion viva tiene
      ajustes en archivos que el snapshot no guardo, el preview los cuenta como bajas
      pero la escritura no los toca, asi que el estado final no es el del snapshot. Ahora
      se avisa, y solo en el destino LiveFiles, que es el unico que pretende dejar la
      config del jugador en un estado concreto.
- [x] **`Apply` reevalua el estado de cada destino.** El estado se calculaba al
      planificar, asi que un destino modificado entre el plan y la escritura se saltaba
      por 'identical' y el motor informaba de que ya coincidia con el snapshot cuando no
      era cierto. Salio al escribir la prueba del emparejamiento.
- [ ] **El preview de un restore es semantico sobre el inventario completo**, mientras
      que lo que se escribe son los archivos del snapshot. Si la config viva tiene
      ajustes en archivos que el snapshot no incluye, esos ajustes sobreviven a la
      escritura aunque el preview los cuente como bajas. Hoy no se avisa. Cuando haya
      un caso real que lo justifique, comparar las rutas del manifiesto con las
      fuentes de la config viva y avisar de las no cubiertas.
- [ ] `RestorePlan::ToHashtable` publica rutas absolutas del jugador en
      `RestorePlan.json`. Es deliberado (es un registro local de la operacion y esas
      rutas son el dato util), pero conviene recordarlo antes de que alguien pegue ese
      archivo en un issue publico.
- [ ] `ReportGenerator::WriteHashes` colapsa duplicados por clave y el ultimo gana, asi
      que el hash publicado puede no ser el del ejemplar vigente. El diff ya no depende
      de ese archivo (lee valores, no hashes), pero `Hashes.json` sigue siendo enganoso
      cuando hay duplicados.
- [x] **Determinismo frente a la cultura del sistema.** Estaba confirmado, no era
      teorico: ejecutando el codigo anterior bajo `da-DK`, `cl_aa_crosshair` y
      `cl_aardvark_crosshair` saltaban DETRAS de `cl_zz_crosshair` (la colacion danesa
      coteja "aa" como "a-anillo", despues de la z) y el autoexec salia distinto byte a
      byte para el mismo config. Se anade `src/Core/Ordering.ps1` (`Sort-OrdinalBy` y
      `Join-OrdinalKey`), ordenacion ordinal y estable, y se aplica a los cuatro sitios
      cuyo orden llega a la salida o a una decision: el orden dentro de cada categoria
      en `SyncEngine` (de ahi salen el autoexec y todos los exportadores), la relevancia
      de archivos en `ConfigFileDiscovery` (decide que duplicado gana la deduplicacion),
      la rotacion en `SnapshotManager` (decide que snapshots se borran) y el orden de
      hallazgos del `Validator`. Verificado: el autoexec sale identico byte a byte en
      en-US, da-DK, tr-TR y sv-SE. (`adcaeed`)

      Aprendido por el camino, y anotado en el brief del pm: las claves compuestas que
      devuelve `Join-OrdinalKey` **solo** pueden compararse de forma ordinal. Los
      operadores del lenguaje (`-eq`, `-ceq`) y `Should -Be` son sensibles a la cultura
      y la colacion IGNORA el separador U+001F, asi que dan por iguales dos claves
      distintas: `ab<US>c` y `a<US>bc` pasan ambas por "abc".
