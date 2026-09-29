<#
.SYNOPSIS
    Ordenacion determinista e independiente de la cultura del sistema.
.DESCRIPTION
    `Sort-Object` compara cadenas segun la cultura activa, asi que el mismo
    conjunto de datos puede ordenarse distinto en dos maquinas. No es teorico:
    en danes la secuencia "aa" se coteja como "a-anillo" y va DESPUES de la z,
    de modo que `cl_aa_test` acaba detras de `cl_zz`. Cualquier artefacto
    generado a partir de ese orden (el autoexec, los exportadores, los reportes)
    deja de ser byte a byte identico entre maquinas, rompiendo la promesa de
    determinismo del motor.

    Estas funciones ordenan por una clave de texto comparada de forma ORDINAL,
    que es pura aritmetica de puntos de codigo y no depende de la cultura, el
    idioma ni la configuracion regional. El orden es ademas estable: ante dos
    claves iguales se conserva el orden de llegada, para que la salida siga
    siendo reproducible.
#>

Set-StrictMode -Version Latest

# Separador de los tramos de una clave compuesta. U+001F (unit separator) no
# aparece en nombres de convar, valores ni rutas, y al ser 0x1F cotejа antes que
# cualquier caracter imprimible, de modo que un tramo corto ordena antes que otro
# mas largo que lo contenga como prefijo.
#
# CUIDADO: las claves que devuelve Join-OrdinalKey SOLO deben compararse de forma
# ordinal. Los operadores de PowerShell (-eq, -ceq) y Should -Be son sensibles a
# la cultura, y la colacion IGNORA U+001F, asi que consideran iguales dos claves
# distintas: "ab<US>c" y "a<US>bc" pasan por ser ambas "abc". Por eso Sort-OrdinalBy
# compara con [System.StringComparer]::Ordinal y no con operadores del lenguaje.
$script:OrdinalKeySeparator = [char]0x1F

<#
.SYNOPSIS
    Une varios tramos en una unica clave de ordenacion.
.DESCRIPTION
    Los tramos nulos se tratan como cadena vacia para que la clave sea siempre
    comparable.
#>
function Join-OrdinalKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # Sin Mandatory a proposito: un parametro obligatorio rechaza un array
        # que contenga elementos nulos, y aqui un tramo nulo es legitimo (se
        # trata como cadena vacia).
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]] $Parts = @()
    )
    if ($null -eq $Parts) { return '' }
    $texto = foreach ($p in $Parts) { if ($null -eq $p) { '' } else { [string]$p } }
    return ($texto -join $script:OrdinalKeySeparator)
}

<#
.SYNOPSIS
    Ordena una coleccion por una clave de texto, de forma ordinal y estable.
.PARAMETER Items
    Elementos a ordenar. Una coleccion vacia devuelve un array vacio.
.PARAMETER KeySelector
    Bloque que recibe el elemento en $_ (y como primer argumento) y devuelve la
    clave de texto por la que ordenar. Usa Join-OrdinalKey para claves
    compuestas.
.PARAMETER Descending
    Invierte el orden manteniendo la estabilidad.
.OUTPUTS
    Array con los elementos ordenados.
#>
function Sort-OrdinalBy {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]] $Items,

        [Parameter(Mandatory)]
        [scriptblock] $KeySelector,

        [switch] $Descending
    )

    if ($null -eq $Items -or $Items.Count -eq 0) { return @() }

    # Se materializa (clave, posicion de llegada, elemento) para poder comparar
    # sin volver a evaluar el selector en cada comparacion.
    $pares = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $item = $Items[$i]
        $clave = [string](& $KeySelector $item)
        $pares.Add([pscustomobject]@{ Clave = $clave; Orden = $i; Valor = $item })
    }

    $signo = if ($Descending) { -1 } else { 1 }
    $comparador = [System.Comparison[object]] {
        param($a, $b)
        $c = [System.StringComparer]::Ordinal.Compare($a.Clave, $b.Clave)
        if ($c -ne 0) { return $signo * $c }
        # Empate: el orden de llegada decide, asi que la ordenacion es estable
        # en los dos sentidos.
        return $a.Orden - $b.Orden
    }.GetNewClosure()

    $pares.Sort($comparador)
    return @($pares | ForEach-Object { $_.Valor })
}
