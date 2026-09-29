<#
.SYNOPSIS
    Parser tolerante del volcado de `cvarlist` de la consola de CS2.
.DESCRIPTION
    Convierte el texto que el juego escribe con

        con_logfile cvars.txt
        cvarlist
        con_logfile ""

    en entradas estructuradas (nombre, valor por defecto, banderas, descripcion).
    De ahi sale `config/convars.json` (ver Catalog/ConvarCatalog.ps1), que es lo
    que sustituye a mantener defaults y tipos a mano.

    ---------------------------------------------------------------------------
    LO QUE SE ASUME DEL FORMATO, Y CON QUE CONFIANZA
    ---------------------------------------------------------------------------
    El formato exacto de `cvarlist` NO esta verificado contra un volcado real de
    CS2: varia entre builds y este repositorio todavia no tiene ninguno. Por eso
    el parser NO es una regex unica, sino una cascada de hipotesis nombradas, y
    cada entrada se queda con el nombre de la hipotesis que encajo
    (`CvarListEntry::Shape`) para poder auditar despues cual acerto de verdad.

    Hipotesis 1 (`colon-table`, ALTA confianza para Source 1, MEDIA para CS2).
        Tabla con los campos separados por dos puntos rodeados de espacios:

            sv_cheats           : 0        : , sv, rep : Allow cheats on server

    Hipotesis 2 (`column-table`, MEDIA). Columnas alineadas, separadas por dos o
        mas espacios o por tabuladores:

            sv_cheats             0        sv, rep     Allow cheats on server

    Hipotesis 3 (`spaced-row`, BAJA). Un solo espacio entre campos; la
        descripcion se reconstruye uniendo el resto de campos. Solo se acepta si
        el nombre y el valor son reconocibles, porque una frase de consola suelta
        tambien encaja en "palabras separadas por espacios".

    En las tres, el REPARTO de campos no es posicional ciego, sino guiado por los
    datos: el campo 0 tiene que tener forma de nombre de convar, la columna de
    banderas se reconoce por su contenido (ver EsBanderas) y TODO lo que va
    despues se vuelve a unir con su separador original, de modo que una
    descripcion que contenga ` : ` sobrevive intacta.

    Lo que no encaja en ninguna hipotesis NO se descarta (principio del
    proyecto): viaja en `Rejections` con su numero de linea, su texto crudo y el
    motivo, y el catalogo generado lo publica para que se pueda revisar. Un
    volcado real que traiga filas en `unrecognized` es precisamente la senal de
    que hay que ampliar una hipotesis, y por eso se cuentan y se guardan.
#>

Set-StrictMode -Version Latest

# Naturaleza de la entrada. Importa mas de lo que parece: un concommand NO tiene
# valor por defecto y no puede inyectarse como fallback en el autoexec, asi que
# el catalogo lo guarda en una seccion aparte.
enum CvarEntryKind {
    Convar
    ConCommand
    Unknown
}

<#
    Un campo de una fila, con el separador literal que lo precedia. Guardar el
    separador es lo que permite reconstruir la descripcion tal cual estaba
    cuando el separador del formato aparece DENTRO de la descripcion.
#>
class CvarListField {
    [string] $Text
    [bool]   $Quoted
    [string] $SepBefore

    CvarListField([string] $text, [bool] $quoted, [string] $sepBefore) {
        $this.Text      = $text
        $this.Quoted    = $quoted
        $this.SepBefore = $sepBefore
    }
}

class CvarListEntry {
    [string]        $Name
    [string]        $DefaultValue
    [string[]]      $Flags
    [string]        $Description
    [CvarEntryKind] $Kind
    [int]           $SourceLine     # 1-based, sobre el volcado
    [string]        $RawLine
    [string]        $Shape          # hipotesis que encajo, para auditoria

    CvarListEntry() {
        $this.Name         = ''
        $this.DefaultValue = ''
        $this.Flags        = @()
        $this.Description  = ''
        $this.Kind         = [CvarEntryKind]::Unknown
        $this.SourceLine   = -1
        $this.RawLine      = ''
        $this.Shape        = ''
    }
}

<#
    Una linea que no se convirtio en entrada. Se conserva siempre.

    Motivos: blank, header, summary, ruler, duplicate, unrecognized.
    Solo `unrecognized` significa "no supe leer esto"; el resto es basura
    esperada del volcado y se cuenta para poder cuadrar los totales.
#>
class CvarListRejection {
    [int]    $SourceLine
    [string] $RawLine
    [string] $Reason

    CvarListRejection([int] $line, [string] $raw, [string] $reason) {
        $this.SourceLine = $line
        $this.RawLine    = $raw
        $this.Reason     = $reason
    }
}

class CvarListParseResult {
    [System.Collections.Generic.List[CvarListEntry]]     $Entries
    [System.Collections.Generic.List[CvarListRejection]] $Rejections
    # Total que declara el propio volcado ("1234 total convars/concommands").
    # -1 si no aparece. Sirve para avisar de un volcado truncado.
    [int]       $DeclaredTotal
    [int]       $TotalLines
    [hashtable] $ShapeCounts     # hipotesis -> nº de filas que encajaron

    CvarListParseResult() {
        $this.Entries       = [System.Collections.Generic.List[CvarListEntry]]::new()
        $this.Rejections    = [System.Collections.Generic.List[CvarListRejection]]::new()
        $this.DeclaredTotal = -1
        $this.TotalLines    = 0
        $this.ShapeCounts   = @{}
    }

    [CvarListRejection[]] Unrecognized() {
        return @($this.Rejections | Where-Object { $_.Reason -eq 'unrecognized' })
    }

    [int] CountByReason([string] $reason) {
        return @($this.Rejections | Where-Object { $_.Reason -eq $reason }).Count
    }

    [int] ConvarCount()    { return @($this.Entries | Where-Object { $_.Kind -ne [CvarEntryKind]::ConCommand }).Count }
    [int] CommandCount()   { return @($this.Entries | Where-Object { $_.Kind -eq [CvarEntryKind]::ConCommand }).Count }

    # Verdad incomoda que conviene tener a mano: si el volcado declara un total y
    # no cuadra con lo leido, esta truncado o hay filas que no se supieron leer.
    [bool] LooksTruncated() {
        if ($this.DeclaredTotal -lt 0) { return $false }
        return $this.Entries.Count -lt $this.DeclaredTotal
    }
}

class CvarListParser {
    hidden [Logger] $Log

    # Vocabulario de banderas cortas del motor. Es una HIPOTESIS tomada de la
    # salida de Source 1 (FCVAR_*); CS2 puede imprimir otras. Ampliar aqui es el
    # punto de extension previsto cuando exista un volcado real: una bandera
    # desconocida no rompe nada, solo hace que esa columna se lea como parte de
    # la descripcion en lugar de como banderas.
    static [string[]] $KnownFlags = @(
        'a', 'archive', 'cheat', 'cl', 'client', 'clientcmd_can_execute', 'cmd',
        'demo', 'dev', 'devonly', 'game', 'hidden', 'linked', 'nf', 'norecord',
        'notify', 'numeric', 'per_user', 'print', 'prot', 'protected', 'rel',
        'release', 'rep', 'replicated', 'server_can_execute', 'sp', 'sv',
        'server', 'string', 'user', 'userinfo'
    )

    # Marcadores que el motor usa para decir "esto es un comando, no una convar".
    static [string[]] $CommandMarkers = @('cmd', 'concommand', 'command')

    # La columna de banderas nunca esta mas a la derecha que esto. Sin el tope,
    # una descripcion que contenga algo como "a, sv" se leeria como banderas.
    static [int] $MaxFlagsFieldIndex = 3

    # Ruido esperado alrededor de las filas. Se comprueba en ORDEN: el resumen
    # antes que el encabezado, porque de el se saca DeclaredTotal.
    static [object[]] $NoisePatterns = @(
        @{ reason = 'summary'; pattern = '^\s*(?<n>\d+)\s+total\s+(?:convars?|concommands?|convars/concommands|commands?)\b' }
        @{ reason = 'summary'; pattern = '^\s*total\s*[:=]?\s*(?<n>\d+)\s*(?:convars?|concommands?|convars/concommands)?\s*$' }
        @{ reason = 'ruler';   pattern = '^\s*[-=_*]{3,}\s*$' }
        # Un volcado tal cual sale de con_logfile no trae comentarios, pero uno
        # recortado a mano (o un fixture) si, y no son filas que no se supieron
        # leer: son ruido reconocido.
        @{ reason = 'comment'; pattern = '^\s*(?://|#|;)' }
        @{ reason = 'header';  pattern = '^\s*cvar\s+list\b' }
        @{ reason = 'header';  pattern = '^\s*-+\s*cvar\s+list' }
        @{ reason = 'header';  pattern = '^\s*name\s*[:|]?\s+(?:value|default)\b' }
        @{ reason = 'header';  pattern = '^\s*\[\s*console\s*\]\s*$' }
    )

    CvarListParser([Logger] $log) {
        $this.Log = $log
    }

    [CvarListParseResult] ParseFile([string] $path) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "No se encontro el volcado de cvarlist: $path"
        }
        # -Raw preserva el archivo tal cual; el troceado en lineas lo hace Parse
        # para que dar texto o dar archivo produzca exactamente lo mismo.
        $text = Get-Content -LiteralPath $path -Raw -Encoding utf8
        $this.Log.Info("Volcado de cvarlist leido: $path")
        return $this.Parse($text)
    }

    [CvarListParseResult] Parse([string] $text) {
        $result = [CvarListParseResult]::new()
        if ([string]::IsNullOrEmpty($text)) {
            $this.Log.Warn('Volcado de cvarlist vacio: 0 entradas.')
            return $result
        }

        # Se acepta CRLF, LF y CR sueltos: el volcado viene de Windows pero puede
        # llegar copiado por cualquier via.
        $lines = $text -split "`r`n|`n|`r"
        $result.TotalLines = $lines.Count

        # Nombre ya visto -> primera linea donde aparecio. El primero gana; los
        # siguientes se conservan como 'duplicate'.
        $seen = [System.Collections.Generic.Dictionary[string, int]]::new()

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $raw  = [string]$lines[$i]
            $num  = $i + 1

            if ([string]::IsNullOrWhiteSpace($raw)) {
                $result.Rejections.Add([CvarListRejection]::new($num, $raw, 'blank'))
                continue
            }

            $noise = $this.MatchNoise($raw)
            if ($null -ne $noise) {
                if ($noise.reason -eq 'summary' -and $noise.total -ge 0) {
                    $result.DeclaredTotal = [int]$noise.total
                }
                $result.Rejections.Add([CvarListRejection]::new($num, $raw, [string]$noise.reason))
                continue
            }

            $entry = $this.ParseRow($raw, $num)
            if ($null -eq $entry) {
                $result.Rejections.Add([CvarListRejection]::new($num, $raw, 'unrecognized'))
                continue
            }

            $clave = $entry.Name.ToLowerInvariant()
            if ($seen.ContainsKey($clave)) {
                $result.Rejections.Add([CvarListRejection]::new($num, $raw, 'duplicate'))
                continue
            }
            $seen[$clave] = $num
            $result.Entries.Add($entry)
            if (-not $result.ShapeCounts.ContainsKey($entry.Shape)) { $result.ShapeCounts[$entry.Shape] = 0 }
            $result.ShapeCounts[$entry.Shape] = [int]$result.ShapeCounts[$entry.Shape] + 1
        }

        $noLeidas = $result.Unrecognized().Count
        $this.Log.Info(("cvarlist parseado: {0} entradas ({1} convars, {2} comandos), {3} lineas no reconocidas de {4}" -f
            $result.Entries.Count, $result.ConvarCount(), $result.CommandCount(), $noLeidas, $result.TotalLines))
        if ($noLeidas -gt 0) {
            $this.Log.Warn("$noLeidas lineas no encajaron en ninguna hipotesis de formato; se conservan en el catalogo para revision.")
        }
        if ($result.LooksTruncated()) {
            $this.Log.Warn(("El volcado declara {0} entradas y se leyeron {1}: parece truncado." -f
                $result.DeclaredTotal, $result.Entries.Count))
        }
        return $result
    }

    # Devuelve @{ reason; total } si la linea es ruido conocido, $null si no.
    hidden [hashtable] MatchNoise([string] $raw) {
        foreach ($p in [CvarListParser]::NoisePatterns) {
            $m = [regex]::Match($raw, [string]$p.pattern,
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $m.Success) { continue }
            $total = -1
            if ($m.Groups['n'].Success) {
                [int] $parsed = 0
                if ([int]::TryParse($m.Groups['n'].Value, [ref] $parsed)) { $total = $parsed }
            }
            return @{ reason = [string]$p.reason; total = $total }
        }
        return $null
    }

    <#
        Intenta las tres hipotesis en orden de confianza. Devuelve $null si
        ninguna encaja, y entonces quien llama conserva la linea como
        'unrecognized'.
    #>
    hidden [CvarListEntry] ParseRow([string] $raw, [int] $num) {
        # Hipotesis 1: tabla con ':' como separador. Solo si hay al menos un ':'
        # con espacio a algun lado, para no confundir un "Ratio 1:1" dentro de
        # una descripcion con un separador de columna.
        if ($raw -match '(?:\s:|:\s|:$)') {
            $campos = $this.SplitFields($raw, ':')
            if ($campos.Count -ge 2) {
                $e = $this.BuildEntry($campos, $raw, $num, 'colon-table')
                if ($null -ne $e) { return $e }
            }
        }

        # Hipotesis 2: columnas separadas por 2+ espacios o tabuladores.
        $campos = $this.SplitFields($raw, 'wide')
        if ($campos.Count -ge 2) {
            $e = $this.BuildEntry($campos, $raw, $num, 'column-table')
            if ($null -ne $e) { return $e }
        }

        # Hipotesis 3: un solo espacio. La menos fiable, va ultima.
        $campos = $this.SplitFields($raw, 'space')
        if ($campos.Count -ge 2) {
            $e = $this.BuildEntry($campos, $raw, $num, 'spaced-row')
            if ($null -ne $e) { return $e }
        }

        return $null
    }

    <#
        Troceado consciente de las comillas. Recorre la linea caracter a
        caracter (no regex ingenua, igual que el Tokenizer del motor) y devuelve
        cada campo con el separador literal que lo precedia.

        $mode: ':' separador dos puntos con espacios opcionales alrededor
               'wide'  dos o mas espacios, o cualquier tabulador
               'space' cualquier racha de espacios en blanco
    #>
    hidden [System.Collections.Generic.List[CvarListField]] SplitFields([string] $linea, [string] $mode) {
        # La sangria de la fila no es un campo: se recorta antes de trocear para
        # que un volcado indentado no produzca un primer campo vacio.
        $linea  = if ($null -eq $linea) { '' } else { $linea.Trim() }
        $campos = [System.Collections.Generic.List[CvarListField]]::new()
        $buf    = [System.Text.StringBuilder]::new()
        $sep    = ''          # separador que precede al campo que se esta armando
        $quoted = $false      # el campo actual llego entrecomillado
        $pos    = 0
        $len    = $linea.Length

        while ($pos -lt $len) {
            $c = $linea[$pos]

            if ($c -eq '"') {
                # Campo entrecomillado: se copia tal cual hasta la comilla de
                # cierre, asi que un separador dentro de las comillas no parte el
                # campo. Una comilla sin cerrar se lee hasta el fin de linea en
                # lugar de fallar.
                $quoted = $true
                $pos++
                while ($pos -lt $len -and $linea[$pos] -ne '"') {
                    [void]$buf.Append($linea[$pos]); $pos++
                }
                if ($pos -lt $len) { $pos++ }   # consume la comilla de cierre
                continue
            }

            # OJO: MatchSeparator se declara [string], y un metodo de clase de
            # PowerShell CONVIERTE lo devuelto al tipo declarado, asi que un
            # `return $null` sale como cadena vacia y no como $null. Comprobar
            # contra $null daba por bueno un separador de longitud 0 y el bucle
            # no avanzaba nunca. La ausencia de separador se comprueba por vacio.
            $sepTexto = $this.MatchSeparator($linea, $pos, $mode)
            # Una coma al final de lo acumulado dice que el campo continua: en la
            # hipotesis de un solo espacio, ", " separa banderas dentro de la MISMA
            # columna, no columnas entre si, y sin esto "a, cl" se partiria en dos
            # campos y la mitad de las banderas acabaria en la descripcion.
            if ($mode -eq 'space' -and $buf.Length -gt 0 -and $buf[$buf.Length - 1] -eq ',') {
                $sepTexto = ''
            }
            if (-not [string]::IsNullOrEmpty($sepTexto)) {
                $campos.Add([CvarListField]::new($buf.ToString(), $quoted, $sep))
                [void]$buf.Clear()
                $quoted = $false
                $sep    = $sepTexto
                $pos   += $sepTexto.Length
                continue
            }

            [void]$buf.Append($c)
            $pos++
        }
        $campos.Add([CvarListField]::new($buf.ToString(), $quoted, $sep))

        # Los extremos se recortan; los campos intermedios vacios se conservan
        # porque una columna vacia (por ejemplo banderas ausentes) es informacion
        # de posicion: "nombre : 0 :  : desc" no es lo mismo que "nombre : 0 : desc".
        for ($i = 0; $i -lt $campos.Count; $i++) {
            if (-not $campos[$i].Quoted) { $campos[$i].Text = $campos[$i].Text.Trim() }
        }
        while ($campos.Count -gt 1 -and [string]::IsNullOrEmpty($campos[$campos.Count - 1].Text)) {
            $campos.RemoveAt($campos.Count - 1)
        }
        return $campos
    }

    <#
        Devuelve el texto literal del separador que empieza en $pos, o cadena
        vacia si ahi no empieza un separador. Vacio y no $null a proposito: el
        tipo de retorno declarado es [string] y PowerShell convierte lo devuelto
        a ese tipo, de modo que un $null saldria igualmente como ''.
    #>
    hidden [string] MatchSeparator([string] $linea, [int] $pos, [string] $mode) {
        $len = $linea.Length
        if ($mode -eq ':') {
            # Espacios opcionales + ':' + espacios opcionales. Se exige espacio a
            # un lado para no partir "1:1".
            $j = $pos
            while ($j -lt $len -and ($linea[$j] -eq ' ' -or $linea[$j] -eq "`t")) { $j++ }
            if ($j -ge $len -or $linea[$j] -ne ':') { return '' }
            $antesHayEspacio = ($j -gt $pos)
            $k = $j + 1
            while ($k -lt $len -and ($linea[$k] -eq ' ' -or $linea[$k] -eq "`t")) { $k++ }
            $despuesHayEspacio = ($k -gt $j + 1) -or ($k -ge $len)
            if (-not ($antesHayEspacio -or $despuesHayEspacio)) { return '' }
            return $linea.Substring($pos, $k - $pos)
        }

        if ($mode -eq 'wide') {
            if ($linea[$pos] -eq "`t") {
                $j = $pos
                while ($j -lt $len -and ($linea[$j] -eq ' ' -or $linea[$j] -eq "`t")) { $j++ }
                return $linea.Substring($pos, $j - $pos)
            }
            if ($linea[$pos] -ne ' ') { return '' }
            $j = $pos
            while ($j -lt $len -and ($linea[$j] -eq ' ' -or $linea[$j] -eq "`t")) { $j++ }
            if (($j - $pos) -lt 2) { return '' }
            return $linea.Substring($pos, $j - $pos)
        }

        # 'space'
        if (-not [char]::IsWhiteSpace($linea[$pos])) { return '' }
        $j = $pos
        while ($j -lt $len -and [char]::IsWhiteSpace($linea[$j])) { $j++ }
        return $linea.Substring($pos, $j - $pos)
    }

    <#
        Reparto de campos guiado por los datos, no por posiciones fijas.
        Devuelve $null si la fila no es creible como entrada de cvarlist.
    #>
    hidden [CvarListEntry] BuildEntry([System.Collections.Generic.List[CvarListField]] $campos,
                                      [string] $raw, [int] $num, [string] $shape) {
        if ($campos.Count -lt 2) { return $null }

        $nombre = $campos[0].Text
        if (-not $this.LooksLikeConvarName($nombre)) { return $null }

        $e = [CvarListEntry]::new()
        $e.Name       = $nombre
        $e.SourceLine = $num
        $e.RawLine    = $raw.TrimEnd()
        $e.Shape      = $shape
        $e.Kind       = [CvarEntryKind]::Convar

        # 1. La columna del valor. Un marcador de comando en esa posicion no es un
        #    valor sino el tipo de entrada: un concommand no tiene default. Se
        #    resuelve ANTES de buscar las banderas porque 'cmd' pertenece tambien
        #    al vocabulario de banderas, y tomarlo por la columna de banderas
        #    empujaria las banderas de verdad dentro de la descripcion.
        $iValor = 1
        if ([CvarListParser]::CommandMarkers -contains $campos[1].Text.ToLowerInvariant()) {
            $e.Kind = [CvarEntryKind]::ConCommand
            $iValor = 2
        }

        # 2. Localizar la columna de banderas por su contenido, no por su posicion.
        $iFlags = -1
        $tope = [Math]::Min($campos.Count - 1, [CvarListParser]::MaxFlagsFieldIndex)
        for ($i = $iValor; $i -le $tope; $i++) {
            if ($campos[$i].Quoted) { continue }   # un campo citado es texto, no columna de banderas
            if ($this.LooksLikeFlags($campos[$i].Text)) { $iFlags = $i; break }
        }

        # 3. Valor por defecto: lo que hay entre el nombre (o el marcador) y las
        #    banderas.
        $finValor = if ($iFlags -ge 0) { $iFlags - 1 } else { $iValor }
        $partesValor = @()
        for ($i = $iValor; $i -le $finValor -and $i -lt $campos.Count; $i++) {
            $partesValor += $campos[$i].Text
        }
        if ($e.Kind -ne [CvarEntryKind]::ConCommand) {
            $e.DefaultValue = ($partesValor -join ' ').Trim()
        }

        # 4. Banderas. 'cmd' entre las banderas tambien marca concommand.
        if ($iFlags -ge 0) {
            $e.Flags = $this.ParseFlags($campos[$iFlags].Text)
            foreach ($f in $e.Flags) {
                if ([CvarListParser]::CommandMarkers -contains $f) { $e.Kind = [CvarEntryKind]::ConCommand }
            }
            # Si las banderas revelan que era un comando, lo que se habia tomado
            # por valor no lo era.
            if ($e.Kind -eq [CvarEntryKind]::ConCommand) { $e.DefaultValue = '' }
        }

        # 5. Descripcion: TODO lo que queda, reunido con sus separadores
        #    originales. Asi una descripcion que contenga el separador del
        #    formato (' : ') vuelve a salir tal cual estaba.
        $iDesc = if ($iFlags -ge 0) { $iFlags + 1 } else { $iValor + 1 }
        #    Los campos vacios del principio (una columna de banderas ausente, por
        #    ejemplo) no aportan separador: sin esto la descripcion empezaria por
        #    el ' : ' que precedia al primer campo con texto.
        $sb = [System.Text.StringBuilder]::new()
        for ($i = $iDesc; $i -lt $campos.Count; $i++) {
            if ($sb.Length -eq 0) {
                if ([string]::IsNullOrEmpty($campos[$i].Text)) { continue }
                [void]$sb.Append($campos[$i].Text)
                continue
            }
            [void]$sb.Append($campos[$i].SepBefore)
            [void]$sb.Append($campos[$i].Text)
        }
        $e.Description = $sb.ToString().Trim()

        # 6. Credibilidad. Sin esto, cualquier frase de consola en minusculas
        #    ("se ha desconectado del servidor") se leeria como la convar 'se' con
        #    valor 'ha'. Se exige al menos UNA senal fuerte de que la fila es una
        #    fila de tabla y no prosa:
        #      a) hay columna de banderas reconocida;
        #      b) es un concommand declarado con su marcador;
        #      c) el valor por defecto venia entrecomillado;
        #      d) el valor por defecto es un numero;
        #      e) es una fila de tabla completa: separador de columnas explicito
        #         (dos puntos, o columnas alineadas) y tres campos o mas.
        #    Lo que no pasa el filtro NO se inventa como convar: se conserva como
        #    'unrecognized' y se publica en el catalogo para poder revisarlo.
        $valorCitado = ($iValor -lt $campos.Count) -and $campos[$iValor].Quoted
        $creible = ($iFlags -ge 0) -or
                   ($e.Kind -eq [CvarEntryKind]::ConCommand) -or
                   $valorCitado -or
                   ($e.DefaultValue -cmatch '^-?\d+(?:\.\d+)?$') -or
                   ($shape -ne 'spaced-row' -and $campos.Count -ge 3)
        if (-not $creible) { return $null }
        # Un valor sin comillas no puede llevar espacios; uno entrecomillado si,
        # porque las comillas son justamente la forma de expresarlo.
        if (-not $valorCitado -and $e.Kind -ne [CvarEntryKind]::ConCommand -and
            -not $this.LooksLikeScalar($e.DefaultValue)) { return $null }

        return $e
    }

    # Forma de nombre de convar/concommand. Deliberadamente sensible a
    # mayusculas y sin catch-all: las convars del motor son minusculas, y
    # aceptar cualquier palabra convertiria la salida de consola en catalogo.
    # Se admiten los prefijos + y - de los comandos de accion (+attack).
    hidden [bool] LooksLikeConvarName([string] $texto) {
        if ([string]::IsNullOrWhiteSpace($texto)) { return $false }
        return $texto -cmatch '^[+-]?[a-z_][a-z0-9_.]*$'
    }

    # Un valor por defecto creible: numero, cadena corta sin espacios, o vacio.
    hidden [bool] LooksLikeScalar([string] $texto) {
        if ([string]::IsNullOrEmpty($texto)) { return $true }
        return $texto -match '^[^\s]{1,32}$'
    }

    <#
        Reconoce la columna de banderas por su CONTENIDO, no por su posicion.
        Dos senales, y basta con una:
          a) todos los tokens estan en el vocabulario conocido (KnownFlags);
          b) hay 2 o mas tokens separados por comas y todos son palabras cortas
             en minusculas sin espacios.
        La segunda hace que una bandera que CS2 imprima y no conozcamos siga
        leyendose como bandera en lugar de contaminar la descripcion; la primera
        cubre la columna de una sola bandera, donde no hay coma que ayude.
        Una descripcion en prosa no pasa ninguna de las dos.
    #>
    hidden [bool] LooksLikeFlags([string] $texto) {
        if ([string]::IsNullOrWhiteSpace($texto)) { return $false }
        $tokens = @($this.ParseFlags($texto))
        if ($tokens.Count -eq 0) { return $false }

        $todasConocidas = $true
        foreach ($t in $tokens) {
            if ([CvarListParser]::KnownFlags -notcontains $t) { $todasConocidas = $false; break }
        }
        if ($todasConocidas) { return $true }

        if ($tokens.Count -lt 2 -or $texto -notmatch ',') { return $false }
        foreach ($t in $tokens) {
            if ($t -cnotmatch '^[a-z][a-z0-9_]{0,23}$') { return $false }
        }
        return $true
    }

    # Trocea "  , a, sv " en @('a','sv'). Los tokens vacios que deja el motor al
    # imprimir una coma inicial se descartan; el orden se conserva tal cual lo
    # imprimio el juego, que es informacion del volcado.
    hidden [string[]] ParseFlags([string] $texto) {
        if ([string]::IsNullOrWhiteSpace($texto)) { return @() }
        $salida = [System.Collections.Generic.List[string]]::new()
        foreach ($t in ($texto -split '[,;]')) {
            $limpio = $t.Trim().ToLowerInvariant()
            if ([string]::IsNullOrEmpty($limpio)) { continue }
            if (-not $salida.Contains($limpio)) { $salida.Add($limpio) }
        }
        return @($salida)
    }
}
