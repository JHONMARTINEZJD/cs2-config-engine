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
        # Antes la regla catch-all (cl_|sv_|developer|hud_) de P44 absorbia toda
        # convar cl_/sv_ sin clasificar y P49 era inalcanzable en la practica.
        foreach ($name in @('cl_some_future_convar_xyz', 'sv_convar_inventada_2027')) {
            $list = New-List @( (New-Setting -Name $name -Value '1') )
            $script:Classifier.ClassifyAll($list)
            $list[0].CategoryCode | Should -Be 'P49' -Because "$name no coincide con ninguna regla"
        }
    }

    It 'nunca descarta un comando totalmente desconocido' {
        $list = New-List @( (New-Setting -Name '@@@raro!!!' -Value 'x') )
        $script:Classifier.ClassifyAll($list)
        $list[0].CategoryCode | Should -Be 'P48'
    }

    It 'trata como basura (P48) una clave con mayusculas' {
        # Las convars de CS2 son minusculas. Una clave como esta viene de un .vdf
        # que no es config de consola y no debe emitirse activa al autoexec.
        $list = New-List @( (New-Setting -Name 'JugadorNombre' -Value 'Pepe') )
        $script:Classifier.ClassifyAll($list)
        $list[0].CategoryCode | Should -Be 'P48'
    }

    It 'clasifica una muestra representativa en su categoria correcta' {
        $expected = [ordered]@{
            'cl_use_opens_buy_menu'       = 'P22'
            'cl_teammate_colors_show'     = 'P30'
            'cl_righthand'                = 'P26'
            'cl_bobamt_vert'              = 'P27'
            'joy_pitchsensitivity'        = 'P13'
            'vid_config_x'                = 'P04'
            'spec_replay_autostart'       = 'P37'
            'demo_index'                  = 'P38'
            'tv_delay'                    = 'P39'
            'mm_dedicated_search_maxping' = 'P41'
            'rate'                        = 'P41'
            'cl_showfps'                  = 'P43'
            'fps_max'                     = 'P09'
            'snd_musicvolume'             = 'P35'
            'cl_clanid'                   = 'P00'
            'cl_hud_healthammo_style'     = 'P28'
        }
        foreach ($entry in $expected.GetEnumerator()) {
            $list = New-List @( (New-Setting -Name $entry.Key -Value '1') )
            $script:Classifier.ClassifyAll($list)
            $list[0].CategoryCode | Should -Be $entry.Value -Because "$($entry.Key) deberia ir a $($entry.Value)"
        }
    }

    It 'enruta un bind sin comando conocido al fallback de input' {
        $s = New-Setting -Name 'bind' -Value 'comando_que_nadie_conoce' -Type ([SettingType]::Bind)
        $s.Extra['Key'] = 'p'
        $s.Extra['Command'] = 'comando_que_nadie_conoce'
        $list = New-List @($s)
        $script:Classifier.ClassifyAll($list)
        $list[0].CategoryCode | Should -Be 'P10'
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

    It 'conserva el tipo declarado en el catalogo al aplicar un fallback' {
        # Antes todo fallback entraba como Unknown, tirando el tipo del catalogo
        # y contaminando los conteos por tipo del snapshot.
        $cfg = $script:Engine.Build((New-List @()), $script:Cs2, $script:Steam, @())
        $fpsMax = @(@($cfg.AllSettings()) | Where-Object Name -eq 'fps_max')[0]
        $fpsMax.Priority | Should -Be ([SettingPriority]::Fallback)
        $fpsMax.Type     | Should -Be ([SettingType]::Integer)
        $fpsMax.Type     | Should -Not -Be ([SettingType]::Unknown)
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
    BeforeAll {
        function New-Category {
            param([string] $Code, [string] $Name, [Setting[]] $Settings)
            $cat = [ConfigCategory]::new($Code, $Name, 0)
            foreach ($s in $Settings) { $cat.Add($s) }
            return $cat
        }
        function Export-ToString {
            param([GameConfig] $Config)
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                [AutoexecExporter]::new().Export($Config, $tmp, $script:Log)
                return (Get-Content -LiteralPath $tmp -Raw)
            } finally {
                Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
            }
        }
    }

    It 'exporta un autoexec limpio sin bloque de metadatos extensos' {
        $cfg = [GameConfig]::new()
        $cfg.SteamId = '123456'
        $s = [Setting]::new('cl_forwardspeed', '400')
        $s.Type = [SettingType]::Integer
        $cfg.Categories.Add((New-Category -Code 'P15' -Name 'Movement' -Settings @($s)))

        $content = Export-ToString -Config $cfg
        $content | Should -Match 'cl_forwardspeed "400"'
        $content | Should -Match '// CS2 Autoexec'
        $content | Should -Match '// Bloque 1 - Movimiento'
        $content | Should -Not -Match '// Variable:'
        $content | Should -Not -Match 'Valor actual:'
    }

    It 'no deja fuera ninguna categoria del catalogo' {
        # Una categoria sin bloque asignado desapareceria del autoexec: antes se
        # perdian Bob, Spectator, Demo, GOTV y Practice.
        $cfg = [GameConfig]::new()
        foreach ($code in [CategoryMap]::AllCodes()) {
            $s = [Setting]::new(('convar_de_{0}' -f $code.ToLowerInvariant()), '1')
            $s.Type = [SettingType]::Integer
            $cfg.Categories.Add((New-Category -Code $code -Name ([CategoryMap]::NameFor($code)) -Settings @($s)))
        }

        $content = Export-ToString -Config $cfg
        foreach ($code in [CategoryMap]::AllCodes()) {
            $content | Should -Match ('convar_de_{0}' -f $code.ToLowerInvariant())
        }
    }

    It 'imprime el encabezado de cada bloque una sola vez' {
        # P33/P34/P35 son tres categorias del mismo bloque de audio.
        $cfg = [GameConfig]::new()
        foreach ($pair in @(@('P33', 'voice_enable'), @('P34', 'volume'), @('P35', 'snd_musicvolume'))) {
            $s = [Setting]::new($pair[1], '1')
            $s.Type = [SettingType]::Bool
            $cfg.Categories.Add((New-Category -Code $pair[0] -Name ([CategoryMap]::NameFor($pair[0])) -Settings @($s)))
        }

        $content = Export-ToString -Config $cfg
        @([regex]::Matches($content, '(?m)^// Bloque 5 - Audio$')).Count | Should -Be 1
    }

    It 'comenta obsoletas, duplicados y no reconocidos, pero los conserva' {
        $obsoleta = [Setting]::new('mat_queue_mode', '2')
        $obsoleta.Type  = [SettingType]::Integer
        $obsoleta.State = [SettingState]::Obsolete

        $duplicado = [Setting]::new('cl_forwardspeed', '999')
        $duplicado.Type  = [SettingType]::Integer
        $duplicado.State = [SettingState]::Duplicated

        $basura = [Setting]::new('ClaveDeUnVdfCualquiera', 'x')
        $basura.Type = [SettingType]::String

        $cfg = [GameConfig]::new()
        $cfg.Categories.Add((New-Category -Code 'P03' -Name 'Video' -Settings @($obsoleta)))
        $cfg.Categories.Add((New-Category -Code 'P15' -Name 'Movement' -Settings @($duplicado)))
        $cfg.Categories.Add((New-Category -Code 'P48' -Name 'Unknown Commands' -Settings @($basura)))

        $content = Export-ToString -Config $cfg
        $content | Should -Match '(?m)^// mat_queue_mode "2"\s+// obsoleta'
        $content | Should -Match '(?m)^// cl_forwardspeed "999"\s+// duplicado'
        $content | Should -Match '(?m)^// ClaveDeUnVdfCualquiera "x"\s+// no reconocido'
        # Ninguna de las tres debe quedar como comando activo.
        $content | Should -Not -Match '(?m)^mat_queue_mode'
        $content | Should -Not -Match '(?m)^cl_forwardspeed "999"'
        $content | Should -Not -Match '(?m)^ClaveDeUnVdfCualquiera'
    }

    It 'emite activas las posibles convars futuras (P49)' {
        # Tienen forma de convar valida: comentarlas romperia config real.
        $s = [Setting]::new('cl_convar_que_aun_no_clasificamos', '1')
        $s.Type = [SettingType]::Bool
        $cfg = [GameConfig]::new()
        $cfg.Categories.Add((New-Category -Code 'P49' -Name 'Future Commands' -Settings @($s)))

        $content = Export-ToString -Config $cfg
        $content | Should -Match '(?m)^cl_convar_que_aun_no_clasificamos "1"'
    }

    It 'es determinista: no incluye marcas de tiempo' {
        $s = [Setting]::new('cl_forwardspeed', '400')
        $s.Type = [SettingType]::Integer
        $cfg = [GameConfig]::new()
        $cfg.Categories.Add((New-Category -Code 'P15' -Name 'Movement' -Settings @($s)))

        (Export-ToString -Config $cfg) | Should -Be (Export-ToString -Config $cfg)
    }
}

Describe 'Validator - alias circulares' {
    BeforeAll {
        function New-AliasConfig {
            param([System.Collections.Specialized.OrderedDictionary] $Definitions)
            $cfg = [GameConfig]::new()
            $cat = [ConfigCategory]::new('P00', 'Sistema', 0)
            foreach ($entry in $Definitions.GetEnumerator()) {
                $s = [Setting]::new($entry.Key, $entry.Value)
                $s.Type = [SettingType]::Alias
                $s.Extra['Body'] = $entry.Value
                $cat.Add($s)
            }
            $cfg.Categories.Add($cat)
            return $cfg
        }
        function Get-Cycles {
            param([GameConfig] $Config)
            $issues = [Validator]::new($script:Log).Validate($Config)
            # Quien llama envuelve en @() para que un resultado vacio siga
            # siendo un array; aqui un ,@() lo anidaria y Count daria 1.
            return @($issues | Where-Object { $_.Code -eq 'CIRCULAR_ALIAS' })
        }
    }

    It 'no reporta ciclo en un grafo en diamante' {
        # top -> a, b -> base alcanza 'base' por dos caminos sin ciclo alguno.
        $cfg = New-AliasConfig -Definitions ([ordered]@{
            base = 'echo hola'; a = 'base'; b = 'base'; top = 'a;b'
        })
        @(Get-Cycles -Config $cfg).Count | Should -Be 0
    }

    It 'no reporta ciclo en una cadena lineal' {
        $cfg = New-AliasConfig -Definitions ([ordered]@{ a = 'b'; b = 'c'; c = 'echo fin' })
        @(Get-Cycles -Config $cfg).Count | Should -Be 0
    }

    It 'no reporta ciclo en un jumpthrow tipico' {
        $cfg = New-AliasConfig -Definitions ([ordered]@{
            '+jumpthrow' = '+jump;-attack'; '-jumpthrow' = '-jump'
        })
        @(Get-Cycles -Config $cfg).Count | Should -Be 0
    }

    It 'detecta un ciclo real de dos alias' {
        $cfg = New-AliasConfig -Definitions ([ordered]@{ a = 'b'; b = 'a' })
        $cycles = @(Get-Cycles -Config $cfg)
        $cycles.Count | Should -Be 1
        $cycles[0].Severity | Should -Be ([IssueSeverity]::Error)
        $cycles[0].Message  | Should -Match 'a -> b -> a'
    }

    It 'detecta la autorreferencia' {
        $cfg = New-AliasConfig -Definitions ([ordered]@{ a = 'a' })
        @(Get-Cycles -Config $cfg).Count | Should -Be 1
    }

    It 'detecta un ciclo de tres alias' {
        $cfg = New-AliasConfig -Definitions ([ordered]@{ a = 'b'; b = 'c'; c = 'a' })
        @(Get-Cycles -Config $cfg).Count | Should -Be 1
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

    It 'asigna cada codigo del catalogo a exactamente un bloque' {
        # Si esta falla, la categoria huerfana desaparece del autoexec.
        [CategoryMap]::AssertComplete() | Should -BeNullOrEmpty
    }

    It 'expone el bloque de un codigo concreto' {
        [CategoryMap]::BlockFor('P37') | Should -Match 'Espectador'
        [CategoryMap]::BlockFor('P99') | Should -BeNullOrEmpty
    }
}
