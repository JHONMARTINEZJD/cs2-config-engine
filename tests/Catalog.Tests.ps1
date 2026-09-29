#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pruebas del importador de volcados de `cvarlist` y del catalogo generado (A3).
.DESCRIPTION
    Todos los volcados de estas pruebas son SINTETICOS y estan marcados como
    tales: los nombres llevan "fixture" a proposito. Este repositorio no tiene
    ningun volcado real de CS2, asi que lo que se comprueba aqui es el
    comportamiento del parser frente a las hipotesis de formato que documenta
    Catalog/CvarListParser.ps1, no que esas hipotesis coincidan con la salida real
    del juego. Eso ultimo solo se puede cerrar con un volcado del dueno.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'src/Bootstrap.ps1')

    $script:Log     = [Logger]::new([LogLevel]::Error, $null)
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures/cvarlist-synthetic.txt'

    function New-Parser { return [CvarListParser]::new($script:Log) }

    function Get-Entry {
        param([CvarListParseResult] $Result, [string] $Name)
        return @($Result.Entries | Where-Object { $_.Name -eq $Name })[0]
    }

    function Get-Rejection {
        param([CvarListParseResult] $Result, [int] $Line)
        return @($Result.Rejections | Where-Object { $_.SourceLine -eq $Line })[0]
    }
}

Describe 'CvarListParser, filas bien formadas' {
    BeforeAll { $script:P = New-Parser }

    It 'lee nombre, valor, banderas y descripcion de una fila con separador de dos puntos' {
        $r = $script:P.Parse('cl_fixture_alpha : 1 : , a, cl : Convar sintetica bien formada')
        $r.Entries.Count | Should -Be 1
        $e = $r.Entries[0]
        $e.Name         | Should -Be 'cl_fixture_alpha'
        $e.DefaultValue | Should -Be '1'
        $e.Description  | Should -Be 'Convar sintetica bien formada'
        $e.Kind         | Should -Be ([CvarEntryKind]::Convar)
        $e.Shape        | Should -Be 'colon-table'
        ($e.Flags -join '|') | Should -Be 'a|cl'
    }

    It 'lee una fila en columnas alineadas separadas por varios espacios' {
        $r = $script:P.Parse('cl_fixture_columns        128         a, cl             Fila en columnas')
        $r.Entries.Count | Should -Be 1
        $r.Entries[0].DefaultValue | Should -Be '128'
        $r.Entries[0].Description  | Should -Be 'Fila en columnas'
        $r.Entries[0].Shape        | Should -Be 'column-table'
    }

    It 'lee una fila separada por tabuladores' {
        $r = $script:P.Parse("sv_fixture_tab`t0`tsv, rep`tFila con tabuladores")
        $r.Entries.Count | Should -Be 1
        $r.Entries[0].DefaultValue | Should -Be '0'
        ($r.Entries[0].Flags -join '|') | Should -Be 'sv|rep'
    }

    It 'no parte la columna de banderas cuando solo hay un espacio entre campos' {
        # La coma dice que el campo continua: sin eso "a, cl" se partiria en dos
        # campos y la mitad de las banderas acabaria dentro de la descripcion.
        $r = $script:P.Parse('cl_fixture_spaced 1 a, cl Fila con un solo espacio')
        $r.Entries.Count | Should -Be 1
        ($r.Entries[0].Flags -join '|') | Should -Be 'a|cl'
        $r.Entries[0].Description | Should -Be 'Fila con un solo espacio'
        $r.Entries[0].Shape       | Should -Be 'spaced-row'
    }

    It 'conserva un valor entrecomillado que contiene espacios' {
        $r = $script:P.Parse('cl_fixture_quoted : "dos palabras" : , a, cl : Valor con espacios')
        $r.Entries.Count | Should -Be 1
        $r.Entries[0].DefaultValue | Should -Be 'dos palabras'
        $r.Entries[0].Description  | Should -Be 'Valor con espacios'
    }

    It 'conserva la descripcion completa cuando contiene el separador del formato' {
        $r = $script:P.Parse('cl_fixture_sep : 3 : , a : Relacion de aspecto : ancho frente a alto')
        $r.Entries.Count | Should -Be 1
        $r.Entries[0].Description | Should -Be 'Relacion de aspecto : ancho frente a alto'
    }

    It 'conserva la descripcion entrecomillada que contiene el separador' {
        $r = $script:P.Parse('cl_fixture_dq : 2 : , a : "Descripcion : entrecomillada"')
        $r.Entries[0].Description | Should -Be 'Descripcion : entrecomillada'
    }

    It 'no arrastra el separador de una columna de banderas vacia a la descripcion' {
        $r = $script:P.Parse('cl_fixture_noflags : 64 :  : Sin columna de banderas')
        $r.Entries[0].Description | Should -Be 'Sin columna de banderas'
        $r.Entries[0].Flags.Count | Should -Be 0
    }

    It 'trata un marcador cmd como concommand y no como valor por defecto' {
        $r = $script:P.Parse('fixture_command_dump : cmd : , cl : Un concommand')
        $e = $r.Entries[0]
        $e.Kind         | Should -Be ([CvarEntryKind]::ConCommand)
        $e.DefaultValue | Should -Be ''
        # El marcador no debe robarle el puesto a la columna de banderas de verdad.
        ($e.Flags -join '|') | Should -Be 'cl'
        $e.Description  | Should -Be 'Un concommand'
    }

    It 'reconoce como banderas una columna con una bandera que no esta en el vocabulario' {
        # Tolerancia a banderas futuras: varios tokens cortos separados por comas
        # son banderas aunque el vocabulario no las conozca.
        $r = $script:P.Parse('cl_fixture_unknown : 5 : , a, zzz_flag_futura : Bandera desconocida')
        ($r.Entries[0].Flags -join '|') | Should -Be 'a|zzz_flag_futura'
        $r.Entries[0].Description | Should -Be 'Bandera desconocida'
    }

    It 'acepta los comandos de accion con prefijo mas o menos' {
        $r = $script:P.Parse('+fixture_action : cmd : , cl : Comando de accion')
        $r.Entries.Count | Should -Be 1
        $r.Entries[0].Name | Should -Be '+fixture_action'
    }
}

Describe 'CvarListParser, basura y ruido alrededor de las filas' {
    BeforeAll { $script:P = New-Parser }

    It 'no produce entradas con un volcado vacio' {
        $r = $script:P.Parse('')
        $r.Entries.Count    | Should -Be 0
        $r.Rejections.Count | Should -Be 0
        $r.DeclaredTotal    | Should -Be -1
    }

    It 'no produce entradas con un volcado de solo espacios' {
        $r = $script:P.Parse("   `n`t`n  ")
        $r.Entries.Count | Should -Be 0
        $r.CountByReason('blank') | Should -Be 3
    }

    It 'descarta los encabezados sin contarlos como no reconocidos' {
        $r = $script:P.Parse("-------------- cvar list --------------`nname             value     flags`ncl_fixture_a : 1 : , a : Valida")
        $r.Entries.Count           | Should -Be 1
        $r.CountByReason('header') | Should -Be 2
        $r.Unrecognized().Count    | Should -Be 0
    }

    It 'descarta las reglas de guiones' {
        $r = $script:P.Parse("--------------------`n====`ncl_fixture_a : 1 : , a : Valida")
        $r.CountByReason('ruler') | Should -Be 2
        $r.Entries.Count          | Should -Be 1
    }

    It 'lee el total que declara la linea de resumen' {
        $r = $script:P.Parse("cl_fixture_a : 1 : , a : Valida`n2412 total convars/concommands")
        $r.DeclaredTotal            | Should -Be 2412
        $r.CountByReason('summary') | Should -Be 1
    }

    It 'lee tambien la variante del resumen sin la barra' {
        $r = $script:P.Parse('137 total convars')
        $r.DeclaredTotal | Should -Be 137
    }

    It 'avisa de un volcado truncado comparando con el total declarado' {
        $r = $script:P.Parse("cl_fixture_a : 1 : , a : Valida`n900 total convars/concommands")
        $r.LooksTruncated() | Should -BeTrue
    }

    It 'no avisa de truncado cuando el volcado no declara ningun total' {
        # Un volcado cortado a mitad de fila, sin linea de resumen, no se puede
        # declarar truncado sin inventarse el dato.
        $r = $script:P.Parse("cl_fixture_a : 1 : , a : Valida`ncl_fixture_b : 2 : , a")
        $r.DeclaredTotal    | Should -Be -1
        $r.LooksTruncated() | Should -BeFalse
    }

    It 'conserva la salida de consola que no encaja en ninguna hipotesis' {
        $basura = 'Loading resource file scripts/fixture/basura.res'
        $r = $script:P.Parse("cl_fixture_a : 1 : , a : Valida`n$basura")
        $r.Entries.Count        | Should -Be 1
        $r.Unrecognized().Count | Should -Be 1
        # Nada se descarta: la linea viaja entera y con su numero.
        $r.Unrecognized()[0].RawLine    | Should -Be $basura
        $r.Unrecognized()[0].SourceLine | Should -Be 2
    }

    It 'no convierte una frase de consola en minusculas en una convar inventada' {
        # Sin el filtro de credibilidad, "se ha desconectado del servidor" pasaria
        # por la convar 'se' con valor 'ha'.
        $r = $script:P.Parse('se ha desconectado del servidor de prueba')
        $r.Entries.Count        | Should -Be 0
        $r.Unrecognized().Count | Should -Be 1
    }

    It 'no toma por convar una clave con mayusculas' {
        $r = $script:P.Parse('JugadorNombre : 1 : , a : No es una convar del motor')
        $r.Entries.Count        | Should -Be 0
        $r.Unrecognized().Count | Should -Be 1
    }

    It 'conserva una fila repetida en lugar de sobreescribir la primera' {
        $r = $script:P.Parse("cl_fixture_a : 1 : , a : Primera`ncl_fixture_a : 9 : , a : Segunda")
        $r.Entries.Count | Should -Be 1
        $r.Entries[0].DefaultValue | Should -Be '1'
        $r.CountByReason('duplicate') | Should -Be 1
        (Get-Rejection -Result $r -Line 2).RawLine | Should -Match 'Segunda'
    }

    It 'cuenta todas las lineas del volcado, tambien las que no son filas' {
        $r = $script:P.Parse("cl_fixture_a : 1 : , a : Valida`n`nbasura Que No Encaja")
        $r.TotalLines | Should -Be 3
    }
}

Describe 'CvarListParser sobre el fixture completo' {
    BeforeAll { $script:R = (New-Parser).ParseFile($script:Fixture) }

    It 'lee las doce filas del fixture y separa el concommand' {
        $script:R.Entries.Count  | Should -Be 12
        $script:R.ConvarCount()  | Should -Be 11
        $script:R.CommandCount() | Should -Be 1
    }

    It 'deja exactamente las dos lineas de consola como no reconocidas' {
        $script:R.Unrecognized().Count | Should -Be 2
    }

    It 'cuadra con el total que declara el propio fixture' {
        $script:R.DeclaredTotal    | Should -Be 12
        $script:R.LooksTruncated() | Should -BeFalse
    }

    It 'registra que hipotesis de formato encajo en cada fila' {
        # El recuento por hipotesis es lo que permitira auditar, con el volcado
        # real, cual de las tres acerto de verdad.
        $script:R.ShapeCounts['colon-table']  | Should -Be 9
        $script:R.ShapeCounts['column-table'] | Should -Be 2
        $script:R.ShapeCounts['spaced-row']   | Should -Be 1
    }

    It 'trata los comentarios del fixture como ruido reconocido' {
        $script:R.CountByReason('comment') | Should -Be 4
    }

    It 'da el mismo resultado leyendo el archivo que parseando su texto' {
        $texto = Get-Content -LiteralPath $script:Fixture -Raw -Encoding utf8
        $otro  = (New-Parser).Parse($texto)
        $otro.Entries.Count | Should -Be $script:R.Entries.Count
    }
}

Describe 'ConvarCatalogBuilder' {
    BeforeAll {
        $script:R       = (New-Parser).ParseFile($script:Fixture)
        $script:Builder = [ConvarCatalogBuilder]::new($script:Log)
        $script:Json    = $script:Builder.Render($script:R, 'fixture sintetico', 'cvarlist-synthetic.txt', 'abc123')
        $script:Model   = $script:Json | ConvertFrom-Json
    }

    It 'genera un catalogo identico byte a byte para la misma entrada' {
        $otro = $script:Builder.Render($script:R, 'fixture sintetico', 'cvarlist-synthetic.txt', 'abc123')
        # Comparacion ORDINAL: -eq y Should -Be cotejan segun la cultura activa.
        [string]::Equals($script:Json, $otro, [System.StringComparison]::Ordinal) | Should -BeTrue
    }

    It 'no mete ninguna marca de tiempo en el catalogo' {
        # El determinismo exige que regenerar desde el mismo volcado de el mismo
        # archivo, asi que la procedencia se firma con el hash, no con el reloj.
        $script:Json | Should -Not -Match '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}'
    }

    It 'ordena las convars de forma ordinal y no segun la cultura del sistema' {
        # Se comprueba la propiedad, no una lista esperada: cada nombre coteja
        # ORDINALMENTE antes que el siguiente. Con Sort-Object el orden dependeria
        # de la cultura (en danes "aa" va detras de la z) y el catalogo dejaria de
        # ser identico entre maquinas.
        $nombres = @($script:Model.convars.PSObject.Properties.Name)
        $nombres.Count | Should -BeGreaterThan 1
        for ($i = 1; $i -lt $nombres.Count; $i++) {
            [System.StringComparer]::Ordinal.Compare($nombres[$i - 1], $nombres[$i]) |
                Should -BeLessThan 0
        }
    }

    It 'publica la procedencia del volcado para poder auditarlo' {
        $script:Model.source.label      | Should -Be 'fixture sintetico'
        $script:Model.source.dumpFile   | Should -Be 'cvarlist-synthetic.txt'
        $script:Model.source.dumpSha256 | Should -Be 'abc123'
        $script:Model.source.dumpLines  | Should -Be 22
        $script:Model.catalogVersion    | Should -Be 1
    }

    It 'marca el formato de cvarlist como no verificado' {
        # No hay ningun volcado real de CS2 en el proyecto: mientras esto sea
        # false, las columnas del catalogo son una hipotesis.
        $script:Model.source.formatVerified | Should -BeFalse
    }

    It 'firma el volcado con su hash cuando no se le da etiqueta' {
        $sinEtiqueta = $script:Builder.Render($script:R, '', 'cvarlist-synthetic.txt', 'deadbeefcafe0123')
        ($sinEtiqueta | ConvertFrom-Json).source.label | Should -Be 'sha256:deadbeefcafe'
    }

    It 'infiere el tipo de cada convar con la misma regla que el parser del motor' {
        $script:Model.convars.cl_fixture_alpha.type  | Should -Be 'Bool'
        $script:Model.convars.cl_fixture_beta.type   | Should -Be 'Float'
        $script:Model.convars.cl_fixture_columns.type | Should -Be 'Integer'
        $script:Model.convars.cl_fixture_quoted.type | Should -Be 'String'
        # La regla es la del modelo, no una copia: si alguien cambia una, cambian
        # las dos.
        $script:Model.convars.cl_fixture_beta.type |
            Should -Be ([Setting]::InferTypeFromValue('0.75').ToString())
    }

    It 'separa los concommands de las convars' {
        $script:Model.commands.PSObject.Properties.Name | Should -Contain 'fixture_command_dump'
        @($script:Model.convars.PSObject.Properties.Name) |
            Should -Not -Contain 'fixture_command_dump'
    }

    It 'publica las lineas no reconocidas en lugar de tirarlas' {
        @($script:Model.unrecognized).Count | Should -Be 2
        @($script:Model.unrecognized)[0].raw | Should -Not -BeNullOrEmpty
    }

    It 'escribe el catalogo en disco con el mismo contenido que devuelve Render' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cat-{0}.json" -f [guid]::NewGuid())
        try {
            $script:Builder.Write($script:R, $tmp, 'fixture sintetico', 'cvarlist-synthetic.txt', 'abc123')
            $leido = [System.IO.File]::ReadAllText($tmp)
            [string]::Equals($leido, $script:Json, [System.StringComparison]::Ordinal) | Should -BeTrue
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        }
    }
}

Describe 'ConvarCatalog, lector del catalogo generado' {
    BeforeAll {
        $script:CatFile = Join-Path ([System.IO.Path]::GetTempPath()) ("cat-{0}.json" -f [guid]::NewGuid())
        $r = (New-Parser).ParseFile($script:Fixture)
        [ConvarCatalogBuilder]::new($script:Log).Write($r, $script:CatFile, 'fixture sintetico',
                                                      'cvarlist-synthetic.txt', 'abc123')
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:CatFile) { Remove-Item -LiteralPath $script:CatFile -Force }
    }

    It 'lee las convars del catalogo y no los concommands' {
        $cat = [ConvarCatalog]::new($script:CatFile, $script:Log)
        $cat.Count() | Should -Be 11
        $cat.Has('cl_fixture_alpha')     | Should -BeTrue
        $cat.Has('fixture_command_dump') | Should -BeFalse
    }

    It 'busca sin distinguir mayusculas' {
        $cat = [ConvarCatalog]::new($script:CatFile, $script:Log)
        $cat.Has('CL_FIXTURE_ALPHA') | Should -BeTrue
        $cat.Get('CL_Fixture_Alpha').default | Should -Be '1'
    }

    It 'devuelve un catalogo vacio cuando el archivo no existe, en lugar de fallar' {
        $cat = [ConvarCatalog]::new((Join-Path ([System.IO.Path]::GetTempPath()) 'no-existe-jamas.json'), $script:Log)
        $cat.Count() | Should -Be 0
        $cat.Has('cl_fixture_alpha') | Should -BeFalse
    }

    It 'degrada a catalogo vacio con un archivo corrupto en lugar de tumbar el motor' {
        $malo = Join-Path ([System.IO.Path]::GetTempPath()) ("malo-{0}.json" -f [guid]::NewGuid())
        try {
            Set-Content -LiteralPath $malo -Value '{ esto no es json' -Encoding utf8
            $cat = [ConvarCatalog]::new($malo, $script:Log)
            $cat.Count() | Should -Be 0
        } finally {
            if (Test-Path -LiteralPath $malo) { Remove-Item -LiteralPath $malo -Force }
        }
    }

    It 'conserva la etiqueta de procedencia' {
        $cat = [ConvarCatalog]::new($script:CatFile, $script:Log)
        $cat.Label | Should -Be 'fixture sintetico'
    }
}

Describe 'Puente entre el catalogo generado y los fallbacks curados' {
    BeforeAll {
        $script:CuratedPath = Join-Path $script:Root 'config/fallbacks.json'
        $script:CatFile = Join-Path ([System.IO.Path]::GetTempPath()) ("puente-{0}.json" -f [guid]::NewGuid())
        $r = (New-Parser).ParseFile($script:Fixture)
        [ConvarCatalogBuilder]::new($script:Log).Write($r, $script:CatFile, 'fixture sintetico',
                                                      'cvarlist-synthetic.txt', 'abc123')
        $script:Fb = [FallbackCatalog]::new($script:CuratedPath, $script:CatFile, $script:Log)

        function New-LiveList {
            param([string] $Name, [string] $Value)
            $s = [Setting]::new($Name, $Value)
            $s.Type = [Setting]::InferTypeFromValue($Value)
            $list = [System.Collections.Generic.List[Setting]]::new()
            $list.Add($s)
            return $list
        }
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:CatFile) { Remove-Item -LiteralPath $script:CatFile -Force }
    }

    It 'no anade nada al conjunto que se inyecta cuando falta' {
        # La decision de A3: el catalogo generado aporta metadatos, no entradas.
        # Inyectar miles de convars convertiria el autoexec en un volcado del
        # motor en lugar de en la configuracion del jugador.
        $soloCurado = [FallbackCatalog]::new($script:CuratedPath, $script:Log)
        $script:Fb.InjectableNames().Count | Should -Be $soloCurado.InjectableNames().Count
        $script:Fb.InjectableNames() | Should -Not -Contain 'cl_fixture_alpha'
    }

    It 'expone los metadatos de una convar que solo conoce el catalogo generado' {
        $script:Fb.HasMetadata('cl_fixture_alpha') | Should -BeTrue
        $script:Fb.GetMetadata('cl_fixture_alpha').description | Should -Be 'Convar sintetica bien formada'
    }

    It 'da prioridad a la descripcion curada sobre la generada' {
        # sensitivity esta en la lista curada con descripcion en castellano.
        $script:Fb.GetMetadata('sensitivity').description | Should -Be 'Sensibilidad general del raton.'
    }

    It 'no conoce metadatos de una convar que no esta en ninguna de las dos capas' {
        $script:Fb.HasMetadata('cl_convar_que_no_existe_en_ningun_sitio') | Should -BeFalse
        $script:Fb.GetMetadata('cl_convar_que_no_existe_en_ningun_sitio') | Should -BeNullOrEmpty
    }

    It 'cuenta las entradas del catalogo generado' {
        $script:Fb.GeneratedCount() | Should -Be 11
    }

    It 'no marca obsoleta una convar por no aparecer en el volcado' {
        # El volcado puede estar truncado o ser de otra build: deducir
        # obsolescencia de una ausencia contradiria que la config viva manda.
        $script:Fb.IsDeprecated('cl_fixture_alpha') | Should -BeFalse
        $script:Fb.IsDeprecated('sensitivity')      | Should -BeFalse
        $script:Fb.IsDeprecated('mat_queue_mode')   | Should -BeTrue
    }

    It 'nunca sobreescribe el valor vivo con el del catalogo generado' {
        $classifier = [Classifier]::new($script:Log, (Join-Path $script:Root 'config/classification-rules.json'))
        $sync = [SyncEngine]::new($script:Log, $script:Fb, $classifier)
        $cfg = $sync.Build((New-LiveList -Name 'cl_fixture_alpha' -Value '7'),
                           [CS2Location]::new(), [SteamLocation]::new(), @())
        $vivo = @($cfg.AllSettings() | Where-Object { $_.Name -eq 'cl_fixture_alpha' })[0]
        $vivo.Value    | Should -Be '7'
        $vivo.Priority | Should -Be ([SettingPriority]::LiveConfig)
        # El catalogo solo rellena huecos de metadatos.
        $vivo.Metadata.DefaultValue | Should -Be '1'
        $vivo.Metadata.Description  | Should -Be 'Convar sintetica bien formada'
    }

    It 'no inyecta las convars del catalogo generado que faltan en la config viva' {
        $classifier = [Classifier]::new($script:Log, (Join-Path $script:Root 'config/classification-rules.json'))
        $sync = [SyncEngine]::new($script:Log, $script:Fb, $classifier)
        $cfg = $sync.Build((New-LiveList -Name 'cl_fixture_alpha' -Value '7'),
                           [CS2Location]::new(), [SteamLocation]::new(), @())
        $nombres = @($cfg.AllSettings() | ForEach-Object { $_.Name })
        $nombres | Should -Not -Contain 'cl_fixture_beta'
        # Los curados si se inyectan, como antes de A3.
        $nombres | Should -Contain 'sensitivity'
    }
}
