<#
.SYNOPSIS
    Catalogo granular de categorias (P00..P49) y modulos de alto nivel.
.DESCRIPTION
    Define los codigos, nombres y orden determinista de cada categoria. Es la
    unica fuente del catalogo; agregar una categoria nueva solo requiere anadir
    una entrada aqui (extensible sin tocar el clasificador).
#>

Set-StrictMode -Version Latest

class CategoryMap {
    # Code -> Name, en orden determinista.
    static [System.Collections.Specialized.OrderedDictionary] $Definitions = $(
        $d = [ordered]@{}
        $d['P00'] = 'Sistema'
        $d['P01'] = 'Motor Source 2'
        $d['P02'] = 'Render'
        $d['P03'] = 'Video'
        $d['P04'] = 'Display'
        $d['P05'] = 'Monitor'
        $d['P06'] = 'HDR'
        $d['P07'] = 'NVIDIA Reflex'
        $d['P08'] = 'AMD'
        $d['P09'] = 'Frame Pacing'
        $d['P10'] = 'Input'
        $d['P11'] = 'Mouse'
        $d['P12'] = 'Keyboard'
        $d['P13'] = 'Controller'
        $d['P14'] = 'Sensitivity'
        $d['P15'] = 'Movement'
        $d['P16'] = 'Jump'
        $d['P17'] = 'Crouch'
        $d['P18'] = 'Weapon Switching'
        $d['P19'] = 'Weapon Actions'
        $d['P20'] = 'Reload'
        $d['P21'] = 'Grenades'
        $d['P22'] = 'Buy Binds'
        $d['P23'] = 'Economy'
        $d['P24'] = 'Crosshair'
        $d['P25'] = 'Dynamic Crosshair'
        $d['P26'] = 'Viewmodel'
        $d['P27'] = 'Bob'
        $d['P28'] = 'HUD'
        $d['P29'] = 'Radar'
        $d['P30'] = 'Team UI'
        $d['P31'] = 'Chat'
        $d['P32'] = 'Radio'
        $d['P33'] = 'Voice'
        $d['P34'] = 'Audio'
        $d['P35'] = 'Music'
        $d['P36'] = 'MVP'
        $d['P37'] = 'Spectator'
        $d['P38'] = 'Demo'
        $d['P39'] = 'GOTV'
        $d['P40'] = 'Practice'
        $d['P41'] = 'Network'
        $d['P42'] = 'Telemetry'
        $d['P43'] = 'Performance'
        $d['P44'] = 'Developer'
        $d['P45'] = 'Console'
        $d['P46'] = 'Debug'
        $d['P47'] = 'Experimental'
        $d['P48'] = 'Unknown Commands'
        $d['P49'] = 'Future Commands'
        $d
    )

    <#
        Bloques de alto nivel del autoexec. Cada bloque agrupa categorias
        relacionadas y define el orden de escritura del archivo final.

        Esta es la UNICA fuente del agrupamiento: los exportadores la consultan
        en lugar de mantener su propia lista, de modo que una categoria nueva no
        puede quedarse fuera del autoexec por olvido. AssertComplete() lo
        verifica.
    #>
    static [System.Collections.Specialized.OrderedDictionary] $Blocks = $(
        $b = [ordered]@{}
        $b['1 - Movimiento']                    = @('P15', 'P16', 'P17')
        $b['2 - Armas y utilidades']            = @('P18', 'P19', 'P20', 'P21')
        $b['3 - Compra y economia']             = @('P22', 'P23')
        $b['4 - HUD y radar']                   = @('P28', 'P29', 'P30', 'P31', 'P32')
        $b['5 - Audio']                         = @('P33', 'P34', 'P35', 'P36')
        $b['6 - Crosshair y viewmodel']         = @('P24', 'P25', 'P26', 'P27')
        $b['7 - Input y mouse']                 = @('P10', 'P11', 'P12', 'P13', 'P14')
        $b['8 - Video y rendimiento']           = @('P02', 'P03', 'P04', 'P05', 'P06', 'P07', 'P08', 'P09')
        $b['9 - Sistema y red']                 = @('P00', 'P01', 'P41', 'P42', 'P43', 'P44', 'P45', 'P46', 'P47')
        $b['10 - Espectador, demos y practica'] = @('P37', 'P38', 'P39', 'P40')
        $b['11 - Comandos no reconocidos']      = @('P48', 'P49')
        $b
    )

    static [string] NameFor([string] $code) {
        if ([CategoryMap]::Definitions.Contains($code)) {
            return [CategoryMap]::Definitions[$code]
        }
        return 'Unknown'
    }

    static [int] OrderFor([string] $code) {
        $i = 0
        foreach ($key in [CategoryMap]::Definitions.Keys) {
            if ($key -eq $code) { return $i }
            $i++
        }
        return 9999
    }

    static [string[]] AllCodes() {
        return @([CategoryMap]::Definitions.Keys)
    }

    static [string[]] AllBlocks() {
        return @([CategoryMap]::Blocks.Keys)
    }

    # Codigos de un bloque, en el orden declarado.
    static [string[]] CodesInBlock([string] $block) {
        if ([CategoryMap]::Blocks.Contains($block)) {
            return @([CategoryMap]::Blocks[$block])
        }
        return @()
    }

    # Bloque al que pertenece un codigo, o '' si no esta asignado.
    static [string] BlockFor([string] $code) {
        foreach ($block in [CategoryMap]::Blocks.Keys) {
            if ([CategoryMap]::Blocks[$block] -contains $code) { return $block }
        }
        return ''
    }

    <#
        Verifica que el mapa de bloques cubra exactamente el catalogo: ningun
        codigo sin bloque (se perderia en el autoexec) y ningun codigo repetido
        o inexistente. Devuelve la lista de problemas; vacia significa correcto.
    #>
    static [string[]] AssertComplete() {
        $problems = [System.Collections.Generic.List[string]]::new()
        $seen     = [System.Collections.Generic.Dictionary[string, int]]::new()

        foreach ($block in [CategoryMap]::Blocks.Keys) {
            foreach ($code in [CategoryMap]::Blocks[$block]) {
                if (-not [CategoryMap]::Definitions.Contains($code)) {
                    $problems.Add("El bloque '$block' referencia un codigo inexistente: $code")
                    continue
                }
                if ($seen.ContainsKey($code)) {
                    $problems.Add("El codigo $code esta asignado a mas de un bloque.")
                    continue
                }
                $seen[$code] = 1
            }
        }
        foreach ($code in [CategoryMap]::Definitions.Keys) {
            if (-not $seen.ContainsKey($code)) {
                $problems.Add("El codigo $code ($([CategoryMap]::Definitions[$code])) no pertenece a ningun bloque.")
            }
        }
        return $problems.ToArray()
    }
}
