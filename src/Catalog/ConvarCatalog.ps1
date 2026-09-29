<#
.SYNOPSIS
    Catalogo de convars generado desde un volcado de `cvarlist`, y su lector.
.DESCRIPTION
    Dos responsabilidades, separadas a proposito:

      ConvarCatalogBuilder  toma un [CvarListParseResult] y produce el texto de
                            config/convars.json, determinista.
      ConvarCatalog         lee ese archivo y responde consultas de metadatos.

    ---------------------------------------------------------------------------
    COMO ENCAJA CON config/fallbacks.json (decision de producto de A3)
    ---------------------------------------------------------------------------
    El catalogo generado COMPLEMENTA a fallbacks.json; no lo sustituye, y se
    consulta DESPUES de el:

      * fallbacks.json sigue siendo la lista CURADA de convars que el motor
        inyecta en el autoexec cuando faltan en la configuracion viva. Son 18
        elegidas a mano. El catalogo generado tiene miles de entradas: inyectarlas
        todas convertiria el autoexec en un volcado del motor en lugar de en la
        configuracion del jugador, y multiplicaria el tamano de cada snapshot.
        Por eso el catalogo generado NO aporta ninguna entrada al conjunto de
        inyeccion: solo aporta METADATOS (valor por defecto, tipo, descripcion).

      * En los metadatos manda lo curado. Las descripciones escritas a mano son
        deliberadas y estan en castellano; el catalogo generado rellena solo los
        huecos, empezando por las convars que la lista curada no menciona.

      * La regla que no se toca: los fallbacks solo se aplican a variables
        AUSENTES y nunca sobreescriben la configuracion viva. El catalogo generado
        no cambia nada de eso porque no participa en la inyeccion, y su unico
        efecto sobre un ajuste vivo es rellenar Description/DefaultValue cuando
        estan vacios, que es lo que ya hacia la lista curada.

      * Tampoco deduce obsolescencia. Una convar que no aparece en el volcado NO
        se marca obsoleta: el volcado puede estar truncado o venir de otra build,
        y marcar algo obsoleto por ausencia contradiria el principio de que la
        configuracion viva manda. La lista `deprecated` sigue siendo curada.

    Los concommands del volcado se guardan en una seccion `commands` aparte
    precisamente para que nunca puedan colarse como convars con valor: no tienen
    default y no se pueden escribir en un autoexec como asignacion. Se conservan
    porque nada se descarta y porque los modulos B y C los necesitaran.
#>

Set-StrictMode -Version Latest

class ConvarCatalogBuilder {
    hidden [Logger] $Log

    # Version del FORMATO del archivo, no de su contenido. Sube solo si cambia la
    # forma del JSON, para que un lector viejo pueda rechazar uno nuevo.
    static [int] $FormatVersion = 1

    ConvarCatalogBuilder([Logger] $log) {
        $this.Log = $log
    }

    <#
        Devuelve el texto JSON del catalogo. Determinista: la misma entrada
        produce byte a byte el mismo texto.

        Determinismo, en concreto:
          * Las claves se ordenan de forma ORDINAL con Sort-OrdinalBy, no con
            Sort-Object: la colacion del sistema haria que en danes cl_aa_* saliera
            detras de cl_zz_* y el archivo dejaria de ser identico entre maquinas.
          * NO hay marca de tiempo. La procedencia se firma con el sha256 del
            volcado y con la etiqueta que da el usuario (la build o la fecha), no
            con el reloj: regenerar el catalogo desde el mismo volcado dos veces
            tiene que dar el mismo archivo.
          * Los saltos de linea se normalizan a LF.
    #>
    [string] Render([CvarListParseResult] $parsed, [string] $label,
                    [string] $dumpName, [string] $dumpHash) {

        $etiqueta = $this.ResolveLabel($label, $dumpHash)

        $convars  = [ordered]@{}
        $comandos = [ordered]@{}

        $ordenadas = Sort-OrdinalBy -Items @($parsed.Entries) -KeySelector {
            param($e) Join-OrdinalKey -Parts @($e.Name.ToLowerInvariant(), $e.SourceLine.ToString('D8'))
        }

        foreach ($e in $ordenadas) {
            if ($e.Kind -eq [CvarEntryKind]::ConCommand) {
                $comandos[$e.Name] = [ordered]@{
                    flags       = @($e.Flags)
                    description = $e.Description
                    shape       = $e.Shape
                }
                continue
            }
            # El tipo sale de la MISMA regla que usa el parser de la config viva
            # ([Setting]::InferTypeFromValue), para que el mismo valor no se tipe
            # distinto segun si lo leyo el motor del disco o del catalogo.
            $convars[$e.Name] = [ordered]@{
                default     = $e.DefaultValue
                type        = [Setting]::InferTypeFromValue($e.DefaultValue).ToString()
                flags       = @($e.Flags)
                description = $e.Description
                shape       = $e.Shape
            }
        }

        # Las lineas que ninguna hipotesis supo leer se PUBLICAN, no se tiran: son
        # la lista de trabajo para ajustar el parser contra el volcado real.
        $noLeidas = @()
        foreach ($r in $parsed.Unrecognized()) {
            $noLeidas += [ordered]@{ line = $r.SourceLine; raw = $r.RawLine }
        }

        $formas = [ordered]@{}
        foreach ($k in (Sort-OrdinalBy -Items @($parsed.ShapeCounts.Keys) -KeySelector { param($s) [string]$s })) {
            $formas[[string]$k] = [int]$parsed.ShapeCounts[$k]
        }

        $modelo = [ordered]@{
            '$schema'      = 'internal://cs2-config-engine/convars'
            catalogVersion = [ConvarCatalogBuilder]::FormatVersion
            description    = 'Catalogo de convars GENERADO desde un volcado de cvarlist de CS2. No editar a mano: se regenera con -ImportCvarList. Complementa a fallbacks.json (que sigue siendo la lista curada de inyeccion) aportando solo metadatos; los fallbacks siguen aplicandose unicamente a variables ausentes y nunca sobreescriben la configuracion viva.'
            source         = [ordered]@{
                kind              = 'cvarlist-dump'
                label             = $etiqueta
                dumpFile          = $dumpName
                dumpSha256        = $dumpHash
                dumpLines         = $parsed.TotalLines
                declaredTotal     = $parsed.DeclaredTotal
                parsedEntries     = $parsed.Entries.Count
                unrecognizedLines = $parsed.Unrecognized().Count
                duplicateLines    = $parsed.CountByReason('duplicate')
                looksTruncated    = $parsed.LooksTruncated()
                shapes            = $formas
                # El formato de cvarlist no esta verificado contra un volcado real
                # de CS2. Mientras esto sea false, el catalogo es utilizable pero
                # sus columnas son una hipotesis.
                formatVerified    = $false
            }
            convars      = $convars
            commands     = $comandos
            unrecognized = $noLeidas
        }

        $json = $modelo | ConvertTo-Json -Depth 8
        return ($json -replace "`r`n", "`n")
    }

    [void] Write([CvarListParseResult] $parsed, [string] $outPath, [string] $label,
                 [string] $dumpName, [string] $dumpHash) {
        $texto = $this.Render($parsed, $label, $dumpName, $dumpHash)
        $dir = Split-Path -Parent $outPath
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($outPath, $texto, [System.Text.UTF8Encoding]::new($false))
        $this.Log.Info("Catalogo de convars escrito: $outPath ($($parsed.Entries.Count) entradas)")
    }

    <#
        Procedencia auditable sin depender del reloj. Si el usuario no dice de
        que build o fecha es el volcado se usa el prefijo de su sha256, que al
        menos identifica el volcado de forma reproducible, y se avisa: la fecha
        de modificacion del archivo NO se usa porque copiar el volcado la cambia
        y el catalogo dejaria de ser reproducible desde el mismo contenido.
    #>
    hidden [string] ResolveLabel([string] $label, [string] $dumpHash) {
        if (-not [string]::IsNullOrWhiteSpace($label)) { return $label.Trim() }
        $this.Log.Warn('Sin -CatalogLabel: la procedencia se firma solo con el sha256 del volcado. Pase la build o la fecha para poder auditarlo.')
        if ([string]::IsNullOrWhiteSpace($dumpHash)) { return 'desconocida' }
        return ('sha256:{0}' -f $dumpHash.Substring(0, [Math]::Min(12, $dumpHash.Length)))
    }
}

<#
    Lector del catalogo generado. Es OPCIONAL: sin el archivo, el motor funciona
    igual que antes de A3 con la lista curada, asi que su ausencia no es un aviso
    ruidoso sino una traza de depuracion.
#>
class ConvarCatalog {
    hidden [hashtable] $Convars     # nameLower -> @{ default; type; description; flags }
    [string] $Label
    [int]    $CatalogVersion

    ConvarCatalog([string] $path, [Logger] $log) {
        $this.Convars        = @{}
        $this.Label          = ''
        $this.CatalogVersion = 0

        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
            $log.Debug("Sin catalogo generado de convars ($path); se usa solo la lista curada.")
            return
        }
        try {
            $json = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json

            $version = [Setting]::Field($json, 'catalogVersion', 0)
            [int] $v = 0
            if (-not [int]::TryParse([string]$version, [ref] $v)) { $v = 0 }
            $this.CatalogVersion = $v
            if ($v -gt [ConvarCatalogBuilder]::FormatVersion) {
                $log.Warn("El catalogo $path declara la version de formato $v y este motor entiende hasta $([ConvarCatalogBuilder]::FormatVersion); se leera lo que se reconozca.")
            }

            $source = [Setting]::Field($json, 'source', $null)
            if ($null -ne $source) { $this.Label = [string][Setting]::Field($source, 'label', '') }

            $nodo = [Setting]::Field($json, 'convars', $null)
            if ($null -ne $nodo) {
                foreach ($prop in $nodo.PSObject.Properties) {
                    $this.Convars[$prop.Name.ToLowerInvariant()] = @{
                        default     = [string][Setting]::Field($prop.Value, 'default',     '')
                        type        = [string][Setting]::Field($prop.Value, 'type',        '')
                        description = [string][Setting]::Field($prop.Value, 'description', '')
                        flags       = @([Setting]::Field($prop.Value, 'flags', @()))
                    }
                }
            }
            $log.Info("Catalogo generado de convars: $($this.Convars.Count) entradas (origen: $($this.Label))")
        } catch {
            # Un catalogo ilegible degrada al comportamiento anterior a A3 en
            # lugar de tumbar el backup: es una fuente de metadatos, no de verdad.
            $log.Error("Error leyendo el catalogo de convars ($path): $($_.Exception.Message)")
            $this.Convars = @{}
        }
    }

    [bool] Has([string] $settingName) {
        if ([string]::IsNullOrWhiteSpace($settingName)) { return $false }
        return $this.Convars.ContainsKey($settingName.ToLowerInvariant())
    }

    [hashtable] Get([string] $settingName) {
        if (-not $this.Has($settingName)) { return $null }
        return $this.Convars[$settingName.ToLowerInvariant()]
    }

    [int] Count() { return $this.Convars.Count }
}
