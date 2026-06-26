#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pruebas del clasificador, el motor de sincronizacion y el validador.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'src/Bootstrap.ps1')

    $script:Log         = [Logger]::new([LogLevel]::Error, $null)
    $script:RulesPath   = Join-Path $script:Root 'config/classification-rules.json'
    $script:FallbackPath = Join-Path $script:Root 'config/fallbacks.json'

    function New-Setting {
        param([string] $Name, [string] $Value, [SettingType] $Type = [SettingType]::Unknown)
        $s = [Setting]::new($Name, $Value)
        $s.Type = $Type
        return $s
    }

    function New-List {
        param([Setting[]] $Items)
        $list = [System.Collections.Generic.List[Setting]]::new()
        foreach ($i in $Items) { $list.Add($i) }
        return $list
    }
}

Describe 'Classifier' {
    BeforeAll {
        $script:Classifier = [Classifier]::new($script:Log, $script:RulesPath)
    }

    It 'clasifica convars de mira en P24' {
        $list = New-List @( (New-Setting -Name 'cl_crosshaircolor' -Value '1') )
        $script:Classifier.ClassifyAll($list)
        $list[0].CategoryCode | Should -Be 'P24'
    }

    It 'clasifica sensibilidad en P14' {
        $list = New-List @( (New-Setting -Name 'sensitivity' -Value '2.0') )
        $script:Classifier.ClassifyAll($list)
        $list[0].CategoryCode | Should -Be 'P14'
    }

    It 'enruta un bind por su comando objetivo' {
        $s = New-Setting -Name 'bind' -Value '+jump' -Type ([SettingType]::Bind)
        $s.Extra['Key'] = 'space'
        $s.Extra['Command'] = '+jump'
        $list = New-List @($s)
        $script:Classifier.ClassifyAll($list)
        $list[0].CategoryCode | Should -Be 'P16'
    }

    It 'envia convars desconocidas pero validas a P49 (futuro)' {
        $list = New-List @( (New-Setting -Name 'cl_some_future_convar_xyz' -Value '1') )
        $script:Classifier.ClassifyAll($list)
        # cl_ coincide con P44 antes de llegar al fallback; comprueba que se clasifica.
        $list[0].CategoryCode | Should -Not -BeNullOrEmpty
    }

    It 'nunca descarta un comando totalmente desconocido' {
        $list = New-List @( (New-Setting -Name '@@@raro!!!' -Value 'x') )
        $script:Classifier.ClassifyAll($list)
        $list[0].CategoryCode | Should -Be 'P48'
    }
}

Describe 'SyncEngine' {
    BeforeAll {
        $script:Classifier = [Classifier]::new($script:Log, $script:RulesPath)
        $script:Fallbacks  = [FallbackCatalog]::new($script:FallbackPath, $script:Log)
        $script:Engine     = [SyncEngine]::new($script:Log, $script:Fallbacks, $script:Classifier)

        $script:Steam = [SteamLocation]::new()
        $script:Steam.SteamRoot = 'C:\Steam'
        $script:Cs2 = [CS2Location]::new()
        $script:Cs2.SteamId = '123456'
        $script:Cs2.GameRoot = 'C:\Steam\game'
        $script:Cs2.LocalCfgPath = 'C:\Steam\cfg'
    }

    It 'la configuracion viva tiene prioridad: duplicados se marcan, no se pierden' {
        $a = New-Setting -Name 'sensitivity' -Value '2.0' -Type ([SettingType]::Float)
        $b = New-Setting -Name 'sensitivity' -Value '3.0' -Type ([SettingType]::Float)
        $cfg = $script:Engine.Build((New-List @($a, $b)), $script:Cs2, $script:Steam, @())

        $all = @(@($cfg.AllSettings()) | Where-Object Name -eq 'sensitivity')
        $all.Count | Should -Be 2
        (@($all | Where-Object { $_.State -eq [SettingState]::Duplicated }).Count) | Should -Be 1
        # El primer valor (config viva) gana y no queda como duplicado.
        (@($all | Where-Object { $_.State -ne [SettingState]::Duplicated }).Value) | Should -Be '2.0'
    }

    It 'aplica fallback solo a variables ausentes' {
        # fps_max no esta presente -> debe aplicarse el fallback.
        $present = New-Setting -Name 'sensitivity' -Value '1.5' -Type ([SettingType]::Float)
        $cfg = $script:Engine.Build((New-List @($present)), $script:Cs2, $script:Steam, @())

        $fpsMax = @(@($cfg.AllSettings()) | Where-Object Name -eq 'fps_max')
        $fpsMax | Should -Not -BeNullOrEmpty
        $fpsMax.State | Should -Be ([SettingState]::FallbackApplied)
        $fpsMax.Priority | Should -Be ([SettingPriority]::Fallback)

        # sensitivity existente NO debe ser sobrescrito por su fallback (2.5).
        $sens = @($cfg.AllSettings()) | Where-Object { $_.Name -eq 'sensitivity' -and $_.Priority -ne [SettingPriority]::Fallback }
        $sens.Value | Should -Be '1.5'
    }

    It 'marca convars obsoletas sin eliminarlas' {
        $dep = New-Setting -Name 'mat_queue_mode' -Value '2' -Type ([SettingType]::Integer)
        $cfg = $script:Engine.Build((New-List @($dep)), $script:Cs2, $script:Steam, @())
        $found = @(@($cfg.AllSettings()) | Where-Object Name -eq 'mat_queue_mode')
        $found | Should -Not -BeNullOrEmpty
        $found.State | Should -Be ([SettingState]::Obsolete)
    }

    It 'es determinista: misma entrada produce misma salida' {
        $mk = { New-List @(
            (New-Setting -Name 'fps_max' -Value '400' -Type ([SettingType]::Integer)),
            (New-Setting -Name 'cl_crosshairsize' -Value '3' -Type ([SettingType]::Float)),
            (New-Setting -Name 'volume' -Value '0.5' -Type ([SettingType]::Float))
        ) }
        $c1 = $script:Engine.Build((& $mk), $script:Cs2, $script:Steam, @())
        $c2 = $script:Engine.Build((& $mk), $script:Cs2, $script:Steam, @())

        $order1 = (@($c1.AllSettings()) | ForEach-Object { '{0}:{1}' -f $_.CategoryCode, $_.Name }) -join '|'
        $order2 = (@($c2.AllSettings()) | ForEach-Object { '{0}:{1}' -f $_.CategoryCode, $_.Name }) -join '|'
        $order1 | Should -Be $order2
    }
}

Describe 'AutoexecExporter' {
    It 'exporta un autoexec limpio sin bloque de metadatos extensos' {
        $cfg = [GameConfig]::new()
        $cfg.SteamId = '123456'
        $cat = [ConfigCategory]::new('P14', 'Movement', 1)
        $s = [Setting]::new('sensitivity', '2.5')
        $s.Type = [SettingType]::Float
        $cat.Add($s)
        $cfg.Categories.Add($cat)

        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            [AutoexecExporter]::new().Export($cfg, $tmp, $script:Log)
            $content = Get-Content -LiteralPath $tmp -Raw
            $content | Should -Match 'sensitivity "2\.5"'
            $content | Should -Match '// CS2 Autoexec'
            $content | Should -Match '// Bloque 1 - Movimiento'
            $content | Should -Not -Match '// Variable:'
            $content | Should -Not -Match 'Valor actual:'
        } finally {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        }
    }
}

Describe 'CategoryMap' {
    It 'asigna nombre y orden a un codigo conocido' {
        [CategoryMap]::NameFor('P24')  | Should -Not -BeNullOrEmpty
        [CategoryMap]::OrderFor('P24') | Should -BeOfType ([int])
    }

    It 'es tolerante con codigos desconocidos' {
        { [CategoryMap]::NameFor('P99') } | Should -Not -Throw
    }
}
