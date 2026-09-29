#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pruebas de la ordenacion ordinal y del determinismo de la salida frente a la
    cultura del sistema.
.DESCRIPTION
    El motor promete que la misma entrada produce siempre el mismo snapshot.
    Sort-Object coteja cadenas segun la cultura activa, asi que esa promesa se
    rompia en cuanto la maquina tenia otra configuracion regional: en danes la
    secuencia "aa" se coteja como "a-anillo" y va despues de la z.

    Estas pruebas fijan el comportamiento en las dos capas: el ayudante ordinal,
    y el artefacto final que depende de el.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'src/Bootstrap.ps1')
    $script:Log = [Logger]::new([LogLevel]::Error, '')

    # Nombres elegidos a proposito: la colacion danesa los ordena distinto que
    # la comparacion ordinal.
    $script:NombresTrampa = @(
        'cl_aa_test', 'cl_ab_test', 'cl_zz', 'cla_x', 'cl_x',
        'cl_aardvark', 'cl_radar_scale', 'cl_radarscale'
    )

    # Ejecuta un bloque bajo una cultura concreta y restaura siempre la previa.
    function Invoke-EnCultura {
        param([string] $Cultura, [scriptblock] $Bloque)
        $previa = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture =
                [System.Globalization.CultureInfo]::new($Cultura)
            return (& $Bloque)
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $previa
        }
    }
}

Describe 'Sort-OrdinalBy' {
    It 'ordena igual en cualquier cultura' {
        $ordenar = { (Sort-OrdinalBy -Items $script:NombresTrampa -KeySelector { param($x) $x }) -join '|' }
        $referencia = Invoke-EnCultura -Cultura 'en-US' -Bloque $ordenar

        foreach ($cultura in @('da-DK', 'tr-TR', 'sv-SE', 'de-DE', 'es-CO')) {
            (Invoke-EnCultura -Cultura $cultura -Bloque $ordenar) |
                Should -BeExactly $referencia -Because "la cultura $cultura no debe cambiar el orden"
        }
    }

    It 'es estable: las claves iguales conservan el orden de llegada' {
        $items = @(
            [pscustomobject]@{ N = 'x'; Id = 1 }, [pscustomobject]@{ N = 'a'; Id = 2 }
            [pscustomobject]@{ N = 'x'; Id = 3 }, [pscustomobject]@{ N = 'a'; Id = 4 }
        )
        $asc = Sort-OrdinalBy -Items $items -KeySelector { param($i) $i.N }
        (($asc | ForEach-Object { $_.Id }) -join ',') | Should -Be '2,4,1,3'

        # Descendente invierte los grupos, no el orden dentro de cada grupo.
        $desc = Sort-OrdinalBy -Items $items -KeySelector { param($i) $i.N } -Descending
        (($desc | ForEach-Object { $_.Id }) -join ',') | Should -Be '1,3,2,4'
    }

    It 'tolera una coleccion vacia o nula' {
        @(Sort-OrdinalBy -Items @()   -KeySelector { param($x) $x }).Count | Should -Be 0
        @(Sort-OrdinalBy -Items $null -KeySelector { param($x) $x }).Count | Should -Be 0
    }
}

Describe 'Join-OrdinalKey' {
    It 'separa los tramos con un caracter que no aparece en los datos' {
        $clave = Join-OrdinalKey -Parts @('Bind', 'bind', 'space')
        $clave.Split([char]0x1F).Count | Should -Be 3
    }

    It 'trata un tramo nulo como cadena vacia sin fallar' {
        $clave = Join-OrdinalKey -Parts @('a', $null, 'b')
        $clave.Split([char]0x1F).Count | Should -Be 3
    }

    It 'no confunde dos claves distintas' {
        # Sin separador, ('ab','c') y ('a','bc') colisionarian.
        #
        # Se compara con StringComparer::Ordinal y NO con Should -Be: los
        # operadores de PowerShell son sensibles a la cultura y la colacion
        # ignora U+001F, asi que darian estas dos claves por iguales ("abc" y
        # "abc") aunque sus puntos de codigo difieran. Es justo el motivo por el
        # que Sort-OrdinalBy compara ordinalmente.
        $a = Join-OrdinalKey -Parts @('ab', 'c')
        $b = Join-OrdinalKey -Parts @('a', 'bc')
        [System.StringComparer]::Ordinal.Compare($a, $b) | Should -Not -Be 0
    }

    It 'ordena un tramo corto antes que otro que lo contiene como prefijo' {
        # El separador coteja antes que cualquier imprimible, asi que ('a','z')
        # va antes de ('ab','a') pese a que 'z' sea mayor que 'b'.
        $items = @(
            [pscustomobject]@{ P1 = 'ab'; P2 = 'a' },
            [pscustomobject]@{ P1 = 'a';  P2 = 'z' }
        )
        $ord = Sort-OrdinalBy -Items $items -KeySelector { param($i) Join-OrdinalKey -Parts @($i.P1, $i.P2) }
        $ord[0].P1 | Should -Be 'a'
    }
}

Describe 'Determinismo del autoexec frente a la cultura' {
    BeforeAll {
        $script:Engine = [SyncEngine]::new(
            $script:Log,
            [FallbackCatalog]::new((Join-Path $script:Root 'config/fallbacks.json'), $script:Log),
            [Classifier]::new($script:Log, (Join-Path $script:Root 'config/classification-rules.json'))
        )
        $script:Cs2 = [CS2Location]::new()
        $script:Cs2.SteamId = '1'; $script:Cs2.GameRoot = 'X'; $script:Cs2.LocalCfgPath = 'X'
        $script:Steam = [SteamLocation]::new()
        $script:Steam.SteamRoot = 'X'

        function Get-AutoexecEnCultura {
            param([string] $Cultura)
            return (Invoke-EnCultura -Cultura $Cultura -Bloque {
                $lista = [System.Collections.Generic.List[Setting]]::new()
                foreach ($nombre in @('cl_aa_crosshair', 'cl_ab_crosshair', 'cl_zz_crosshair',
                                      'cl_aardvark_crosshair', 'snd_aa_volume', 'snd_zz_volume')) {
                    $s = [Setting]::new($nombre, '1')
                    $s.Type = [SettingType]::Float
                    $lista.Add($s)
                }
                $cfg = $script:Engine.Build($lista, $script:Cs2, $script:Steam, @())
                $tmp = [System.IO.Path]::GetTempFileName()
                try {
                    [AutoexecExporter]::new().Export($cfg, $tmp, $script:Log)
                    return (Get-Content -LiteralPath $tmp -Raw)
                } finally {
                    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
                }
            })
        }
    }

    It 'genera el mismo archivo byte a byte en culturas distintas' {
        # Antes de la ordenacion ordinal, en da-DK las convars con "aa" saltaban
        # detras de las que empiezan por z y el archivo salia distinto.
        $referencia = Get-AutoexecEnCultura -Cultura 'en-US'
        foreach ($cultura in @('da-DK', 'tr-TR', 'sv-SE')) {
            Get-AutoexecEnCultura -Cultura $cultura |
                Should -BeExactly $referencia -Because "en $cultura el autoexec debe ser identico"
        }
    }
}
