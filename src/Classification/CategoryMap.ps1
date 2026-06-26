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
}
