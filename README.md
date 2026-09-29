# CS2 Configuration Snapshot Engine

Motor profesional en **PowerShell** para descubrir, parsear, clasificar, validar y exportar la configuración **viva** de Counter-Strike 2 (CS2 / appid 730). Diseñado con una arquitectura modular orientada a objetos, tolerante a fallos y **determinista**: la misma instalación produce siempre el mismo snapshot.

> Filosofía central: **la configuración viva del juego SIEMPRE manda**. Los valores por defecto (fallbacks) solo rellenan variables ausentes y **nunca** sobrescriben lo que el jugador ya tiene. Ningún comando se descarta jamás: lo desconocido se conserva y se etiqueta.

---

## Características

- **Descubrimiento automático** de Steam, bibliotecas, instalación de CS2, SteamID activo (multi-cuenta) y el árbol `userdata\<SteamID>\730\local\cfg`, sin asumir rutas literales.
- **Parser robusto propio** (tokenizer carácter a carácter, no regex ingenuas) para los formatos `.vcfg`/`.vdf` (VDF anidado) y `.cfg` (comandos de consola). Soporta comillas con escapes, comentarios `//` y `/* */`, y bloques `{ }`.
- **Clasificación granular** en 50 categorías (`P00`–`P49`) mediante reglas regex externas y ampliables. Lo que no encaja en ninguna regla no se pierde: va a `P49` si tiene forma de convar válida, o a `P48` si no.
- **Motor de sincronización determinista**: deduplicación con prioridad de config viva, marcado de duplicados/obsoletos, enriquecimiento de metadatos y aplicación de fallbacks solo a ausentes.
- **Validación** de tipos, valores y consistencia con reporte de problemas.
- **Exportadores** múltiples: `autoexec.cfg`, JSON, Markdown, YAML y CSV.
- **Snapshots con respaldo** y reportes legibles (resumen por categoría, conteos, estados).
- **Logging estructurado** con niveles y archivo opcional.
- **Pruebas Pester** para el tokenizer, los parsers, el clasificador y el motor de sincronización.

---

## Requisitos

- **PowerShell 7+** (usa clases, `enum`, tipado estricto). Windows recomendado para el descubrimiento real de rutas de Steam.
- [Pester 5+](https://pester.dev/) para ejecutar las pruebas (`Install-Module Pester -Scope CurrentUser`).

---

## Estructura del proyecto

```
cs2-config-engine/
├─ CS2ConfigEngine.ps1            # Punto de entrada (CLI)
├─ config/
│  ├─ classification-rules.json   # Reglas regex de clasificación (P00–P49)
│  └─ fallbacks.json              # Valores por defecto + convars obsoletas
├─ src/
│  ├─ Bootstrap.ps1               # Carga (dot-source) todas las clases en orden
│  ├─ Core/                       # Types, Logging, Hashing
│  ├─ Discovery/                  # Steam, CS2/SteamID y archivos de config
│  ├─ Parsing/                    # Tokenizer, VDF, VCFG, CFG y factory
│  ├─ Classification/             # CategoryMap + Classifier
│  ├─ Sync/                       # SyncEngine + FallbackCatalog
│  ├─ Validation/                 # Validator
│  ├─ Export/                     # Autoexec + JSON/MD/YAML/CSV
│  ├─ Backup/                     # SnapshotManager
│  └─ Reporting/                  # ReportGenerator
└─ tests/                         # Pruebas Pester
```

### Modelo de dominio

```
GameConfig
  └─ ConfigCategory (P00..P49)
       └─ Setting
            └─ SettingMetadata
```

Cada `Setting` lleva su `Type` (Bool/Integer/Float/String/Alias/Bind/AnalogBind/...), su `Priority` (LiveConfig > Derived > Fallback), su `State` (Synced/FallbackApplied/Duplicated/Invalid/Obsolete) y metadatos de origen (archivo, línea, texto crudo, hash).

---

## Uso

### Clonar el repositorio

```powershell
git clone https://github.com/JHONMARTINEZJD/cs2-config-engine.git
cd .\cs2-config-engine
```

### Desde Windows con un solo comando

Desde la carpeta del proyecto, en una terminal de Windows:

```bat
run.bat
```

También puedes usar:

```bat
run.cmd
```

Este launcher ejecuta el proyecto localmente sin necesidad de copiar y pegar comandos `iex` desde GitHub. Si no tienes PowerShell 7 instalado, intenta instalarlo automáticamente con `winget`.

### Desde una consola de PowerShell 7

```powershell
# Snapshot completo con todos los exportadores (salida por defecto ./output)
pwsh ./CS2ConfigEngine.ps1
```

### Ejecución remota desde GitHub

```powershell
iex "& { $(irm https://raw.githubusercontent.com/JHONMARTINEZJD/cs2-config-engine/master/launch.ps1) } -RepoUrl 'https://github.com/JHONMARTINEZJD/cs2-config-engine' -Branch 'master'"
```

Si tu rama por defecto cambia en el futuro, sustituye `master` por la rama correcta del repositorio.

Esto descarga el proyecto, lo ejecuta localmente y deja el backup y el nuevo autoexec en la carpeta de salida indicada o, si no se indica, en `~/Downloads/CS2ConfigEngine`.

> Nota de seguridad: el launcher descarga y ejecuta el contenido de una rama sin
> verificar su integridad. Quien tenga permiso de escritura en esa rama controla
> lo que se ejecuta en tu maquina. Si no eres el dueno del repositorio, clona y
> revisa antes de ejecutar.

### Mas ejemplos

```powershell
# Indicar un SteamID concreto (multi-cuenta) y carpeta de salida
pwsh ./CS2ConfigEngine.ps1 -SteamId 123456789 -OutputPath .\out

# Forzar la raíz de Steam si la autodetección falla
pwsh ./CS2ConfigEngine.ps1 -SteamPath "D:\Steam" -OutputPath .\out

# Elegir formatos de exportación, historial y nivel de log
pwsh ./CS2ConfigEngine.ps1 -Formats autoexec,json,markdown -MaxHistory 20 -LogLevel Debug

# Volver a un snapshot anterior. Por defecto SOLO MUESTRA lo que cambiaría.
pwsh ./CS2ConfigEngine.ps1 -Restore latest

# Restaurar de verdad, pero a la carpeta de salida: no toca la config del jugador
pwsh ./CS2ConfigEngine.ps1 -Restore 20260129-101500 -Apply

# Restaurar encima de los .vcfg/.cfg vivos: backup previo y rollback automático
pwsh ./CS2ConfigEngine.ps1 -Restore latest -Apply -RestoreTarget LiveFiles -AllowLiveFileWrites
```

### Parámetros principales

| Parámetro     | Descripción                                                            |
|---------------|------------------------------------------------------------------------|
| `-SteamPath`  | Ruta a la instalación de Steam (autodetectada si se omite).            |
| `-SteamId`    | SteamID a usar (autodetecta la cuenta activa si se omite).             |
| `-OutputPath` | Carpeta de salida para snapshots, exportaciones y reportes (`./output`).|
| `-MaxHistory` | Número de snapshots a conservar (por defecto `10`).                    |
| `-Formats`    | Formatos a exportar: `autoexec`, `json`, `markdown`, `yaml`, `csv`.    |
| `-LogLevel`   | `Debug`, `Info`, `Warn`, `Error`.                                      |

### Parámetros de restauración

| Parámetro               | Descripción                                                                                           |
|-------------------------|-------------------------------------------------------------------------------------------------------|
| `-Restore`              | Id de snapshot (o `latest`). Presente ⇒ modo restauración: no se crea backup nuevo ni se exporta nada. |
| `-Apply`                | Escribe de verdad. Sin él, `-Restore` solo muestra lo que cambiaría y **no toca el disco**.            |
| `-RestoreTarget`        | `Output` (por defecto) escribe en `<OutputPath>/restore/<id>/files`; `LiveFiles` sobre los del jugador.|
| `-AllowLiveFileWrites`  | Permiso explícito, obligatorio para `LiveFiles`. Son dos parámetros a propósito.                       |

Escribir sobre los archivos del jugador exige las dos banderas, copia previa del
estado actual en `<OutputPath>/restore/<id>/backup-<ts>/` y **rollback atómico**:
si cualquier escritura falla a mitad, se deshacen todas las anteriores y el
jugador queda exactamente como estaba. Lo que se escribe son las copias fieles
que el snapshot guardó en `raw/`, byte a byte, nunca una reconstrucción de los
`.vcfg` a partir del inventario.

---

## Salidas

- **`autoexec.cfg`** — configuración regenerada, agrupada por bloques y lista para `exec`. Nada se descarta: los duplicados, las convars obsoletas, las inválidas y las claves no reconocidas se escriben **comentadas** con el motivo al final de la línea, de modo que se conserva la trazabilidad sin que la consola de CS2 devuelva errores al ejecutar el archivo.
- **`snapshot.json`** — modelo completo serializado (ideal para diffs entre capturas).
- **`report.md`** — reporte humano con resumen por categoría, conteos y estados.
- **`snapshot.yaml` / `snapshot.csv`** — vistas alternativas para integración o análisis.
- **`ConfigDiff.json`** — diff semántico **por ajuste** frente al snapshot anterior: añadidas, eliminadas y cambiadas (con valor antes y después), identificadas por la clave estable (`bind::<tecla>`, `alias::<nombre>`, o el nombre de la convar) y agrupadas por categoría. Conserva además los hashes y los deltas de conteos que ya publicaba. La base de comparación es el `Inventory.json` del snapshot anterior; si falta o está corrupto, el diff degrada a "sin base de comparación" con la advertencia correspondiente en lugar de abortar o inventar deltas.
- **`BackupReport.md`** — el mismo diff en forma legible: resumen de altas/bajas/cambios y tabla de las cambiadas con antes y después.
- **Backup** con marca de tiempo de los archivos originales antes de cualquier escritura.
- **`restore/<id>/`** — al restaurar: `files/` con lo que se escribiría o escribió, `backup-<ts>/` con el estado previo (la red de seguridad del rollback) y `RestorePlan.json` con el registro de la operación.

---

## Extensibilidad

- **Nuevas categorías**: añade una entrada en `CategoryMap::Definitions`, asígnala a un bloque en `CategoryMap::Blocks` y añade su regla en `config/classification-rules.json`. No requiere tocar el clasificador ni los exportadores. `CategoryMap::AssertComplete()` (y la prueba que lo cubre) falla si una categoría se queda sin bloque, porque entonces desaparecería del `autoexec.cfg`.
- **Nuevos defaults / obsoletas**: edita `config/fallbacks.json`.
- **Nuevos formatos de archivo**: implementa un parser con `CanParse()`/`Parse()` y regístralo en `ParserFactory`.
- **Nuevos exportadores**: añade una clase en `src/Export/` siguiendo el patrón existente.

El diseño sigue principios SOLID (responsabilidad única por clase, abierto/cerrado vía factories y catálogos externos), de modo que las incorporaciones futuras de Valve se absorben sin reescrituras.

---

## Pruebas

```powershell
Invoke-Pester -Path ./tests
```

Las pruebas cubren: tokenización (comillas, escapes, comentarios, bloques), parseo VCFG/CFG, tolerancia a archivos malformados, clasificación por categoría, prioridad de config viva, aplicación de fallbacks solo a ausentes, marcado de obsoletas y determinismo de salida.

---

## Notas de diseño

- **Tolerancia a fallos**: un archivo ilegible o malformado nunca aborta el proceso; se registra una advertencia y se continúa.
- **Determinismo**: la deduplicación, agrupación y ordenación son estables, por lo que dos ejecuciones sobre el mismo estado generan exactamente el mismo snapshot.
- **Trazabilidad**: cada ajuste conserva su archivo y línea de origen y un hash de su valor, habilitando auditorías y diffs precisos.
