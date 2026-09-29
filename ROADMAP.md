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

### Siguiente

- [ ] **A3 — Catalogo de convars generado, no a mano.** 18 fallbacks y 48 regex
      escritas a mano se quedan viejas en cada actualizacion de Valve. Generar el
      catalogo desde el juego (`con_logfile cvars.txt; cvarlist; con_logfile ""`) y
      versionarlo arregla de raiz defaults, tipos y clasificacion. Alto valor:
      la mitad de los bugs de clasificacion ya cerrados no habrian existido.
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
- [ ] **Una variable local no puede llamarse igual que una propiedad de su clase.**
      Dentro de un metodo de clase de PowerShell, `$name = ...` falla al parsear con
      "Cannot assign property, use '$this.Name'" si la clase tiene una propiedad
      `Name`, tambien en metodos estaticos, donde no hay `$this`. Por eso
      `FromHashtable` usa `$settingName` y `$extraNode`. No esta documentado en
      ningun sitio obvio y cuesta un ciclo cada vez.
- [ ] **El emparejamiento entre `Manifest.json` y `raw/` es implicito.**
      `SnapshotManager::Create` desambigua colisiones de nombre con `_1`, `_2`... y no
      deja constancia de que copia corresponde a que archivo del manifiesto; el
      restore lo reconstruye recorriendo el manifiesto en orden y verificando el hash
      declarado. Funciona y detecta el desajuste, pero lo limpio seria que `Create`
      anotase el nombre real de la copia en el manifiesto (`rawName`). Cambio pequeno
      y compatible: los snapshots viejos seguirian resolviendose por orden.
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
