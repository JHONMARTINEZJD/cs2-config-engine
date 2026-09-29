# Roadmap

Estado durable del desarrollo. Lo mantiene el agente `pm` (`.claude/agents/pm.md`)
y cualquiera puede editarlo a mano. Una tarea se marca hecha solo cuando esta
implementada, probada, verificada ejecutando y commiteada.

Rama de trabajo: `claude/zealous-lovelace-htuxyu`

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

### Siguiente

- [ ] **A1 — Diff semantico entre snapshots.** `ConfigDiff.json` solo compara hashes y
      conteos. Hace falta diff por setting: anadidas, eliminadas y cambiadas con valor
      antes y despues, agrupadas por categoria. Los hashes por setting ya existen, asi
      que es casi gratis. **Es la feature que justifica llamar a esto un motor de
      sincronizacion.** Sin dependencias, puramente aditivo.
- [ ] **A2 — `Restore` / `Apply` con rollback.** Hoy el flujo es unidireccional:
      leer y exportar. Falta el camino de vuelta desde un snapshot.
      Supuesto conservador mientras el dueno no diga otra cosa: por defecto se escribe
      en la carpeta de salida y **nunca** sobre los `.vcfg` vivos; escribir sobre
      archivos del jugador exige un parametro explicito, backup previo y rollback
      atomico si algo falla a mitad. Depende de A1 para poder mostrar que cambiaria.
- [ ] **A3 — Catalogo de convars generado, no a mano.** 18 fallbacks y 48 regex
      escritas a mano se quedan viejas en cada actualizacion de Valve. Generar el
      catalogo desde el juego (`con_logfile cvars.txt; cvarlist; con_logfile ""`) y
      versionarlo arregla de raiz defaults, tipos y clasificacion. Alto valor:
      la mitad de los bugs de clasificacion ya cerrados no habrian existido.
- [ ] **A4 — Perfiles portables.** Exportar e importar un perfil con su hash para
      llevar la config a otra maquina o compartirla. Depende de A1.
- [ ] **A5 — Empaquetar como modulo PowerShell** (`.psd1` + `.psm1`) en lugar de
      dot-sourcear 19 archivos. Da `Import-Module`, version semantica y distribucion
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
