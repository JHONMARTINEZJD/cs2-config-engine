#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pruebas del camino de vuelta: Restore/Apply con rollback (A2) y de la
    rehidratacion completa de un Setting desde su forma serializada.
.DESCRIPTION
    Cubren el preview que no escribe nada, el apply a la carpeta de salida, el
    apply sobre los archivos vivos con su backup previo, el rollback cuando una
    escritura falla a mitad, los errores accionables (snapshot inexistente, sin
    inventario, inventario corrupto), el doble permiso que exige tocar los
    archivos del jugador y el filtro del preview a los cambios de `value`.

    Los escenarios se construyen con el SnapshotManager y el ReportGenerator
    reales (no con fixtures a mano) para que el emparejamiento entre Manifest.json
    y las copias de raw/ se pruebe tal como lo escribe el motor.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'src/Bootstrap.ps1')

    $script:Log    = [Logger]::new([LogLevel]::Error, $null)
    $script:Report = [ReportGenerator]::new($script:Log)

    $script:StateA1 = "// estado A`n" + '"sensitivity" "2.5"' + "`n"
    $script:StateA2 = "// estado A`n" + 'bind "space" "+jump"' + "`n"
    $script:StateB1 = "// estado B`n" + '"sensitivity" "1.1"' + "`n"
    $script:StateB2 = "// estado B`n" + 'bind "space" "+lookatweapon"' + "`n"

    function New-RestoreSetting {
        param(
            [string] $Name,
            [string] $Value,
            [string] $Type     = 'Unknown',
            [string] $Category = 'P48',
            [string] $Key      = '',
            [string] $State    = 'Synced'
        )
        $s = [Setting]::new($Name, $Value)
        $s.Type         = [SettingType]$Type
        $s.State        = [SettingState]$State
        $s.CategoryCode = $Category
        if ($Key) { $s.Extra['Key'] = $Key; $s.Extra['Command'] = $Value }
        $s.Metadata.Hash = Get-StringHash -Text ('{0}={1}' -f $Name, $Value)
        return $s
    }

    # Agrupa como lo hace SyncEngine: categorias en el orden del catalogo.
    function New-RestoreConfig {
        param([Setting[]] $Settings)
        $cfg   = [GameConfig]::new()
        $byCat = [ordered]@{}
        foreach ($s in $Settings) {
            if (-not $byCat.Contains($s.CategoryCode)) {
                $byCat[$s.CategoryCode] = [System.Collections.Generic.List[Setting]]::new()
            }
            $byCat[$s.CategoryCode].Add($s)
        }
        foreach ($code in @($byCat.Keys | Sort-Object { [CategoryMap]::OrderFor($_) })) {
            $cat = [ConfigCategory]::new($code, [CategoryMap]::NameFor($code), [CategoryMap]::OrderFor($code))
            foreach ($s in $byCat[$code]) { $cat.Add($s) }
            $cfg.Categories.Add($cat)
        }
        return $cfg
    }

    function New-RestoreDiscoveredFile {
        param([string] $Path)
        $d = [DiscoveredFile]::new()
        $d.Path = $Path
        $d.Name = Split-Path -Leaf $Path
        $d.Kind = if ($Path -like '*.vcfg') { 'vcfg' } else { 'cfg' }
        $d.Size = (Get-Item -LiteralPath $Path).Length
        $d.Hash = Get-FileHashSafe -Path $Path
        return $d
    }

    # Ajustes del snapshot (estado A) y de la config viva de hoy (estado B).
    # cl_crosshairsize solo cambia de State: es el caso que el preview debe
    # ocultar porque no afecta al valor que lee el juego.
    $script:SettingsA = @(
        (New-RestoreSetting -Name 'sensitivity'      -Value '2.5'   -Type 'Float'   -Category 'P14')
        (New-RestoreSetting -Name 'cl_crosshairsize' -Value '2'     -Type 'Integer' -Category 'P24')
        (New-RestoreSetting -Name 'bind'             -Value '+jump' -Type 'Bind'    -Category 'P16' -Key 'space')
        (New-RestoreSetting -Name 'cl_radar_scale'   -Value '0.4'   -Type 'Float'   -Category 'P29')
    )
    $script:SettingsB = @(
        (New-RestoreSetting -Name 'sensitivity'      -Value '1.1'           -Type 'Float'   -Category 'P14')
        (New-RestoreSetting -Name 'cl_crosshairsize' -Value '2'             -Type 'Integer' -Category 'P24' -State 'Duplicated')
        (New-RestoreSetting -Name 'bind'             -Value '+lookatweapon' -Type 'Bind'    -Category 'P16' -Key 'space')
        (New-RestoreSetting -Name 'volume'           -Value '0.9'           -Type 'Float'   -Category 'P34')
    )

    <#
        Crea un escenario completo: dos archivos vivos en el estado A, un
        snapshot real tomado de ellos y los mismos archivos ya movidos al estado
        B (el jugador siguio jugando). $SecondDir permite dejar el segundo
        archivo en una carpeta aparte para poder sabotearla en la prueba de
        rollback.
    #>
    function New-RestoreScenario {
        param([string] $Name, [string] $SecondDir = 'live')

        $root    = Join-Path $TestDrive $Name
        $liveDir = Join-Path $root 'live'
        $secDir  = Join-Path $root $SecondDir
        New-Item -ItemType Directory -Path $liveDir -Force | Out-Null
        New-Item -ItemType Directory -Path $secDir  -Force | Out-Null

        $f1 = Join-Path $liveDir 'cs2_user_convars.vcfg'
        $f2 = Join-Path $secDir  'config.cfg'
        [System.IO.File]::WriteAllText($f1, $script:StateA1)
        [System.IO.File]::WriteAllText($f2, $script:StateA2)

        $files = @((New-RestoreDiscoveredFile -Path $f1), (New-RestoreDiscoveredFile -Path $f2))
        $out   = Join-Path $root 'output'
        $cfgA  = New-RestoreConfig $script:SettingsA
        $snap  = [SnapshotManager]::new($script:Log, (Join-Path $out 'backups'), 10).Create($cfgA, $files)
        $script:Report.GenerateAll($cfgA, $snap, $files,
            [System.Collections.Generic.List[ValidationIssue]]::new(), $null, '')

        [System.IO.File]::WriteAllText($f1, $script:StateB1)
        [System.IO.File]::WriteAllText($f2, $script:StateB2)

        return [pscustomobject]@{
            Root   = $root
            Out    = $out
            SnapId = $snap.Id
            F1     = $f1
            F2     = $f2
            SecDir = $secDir
            Live   = New-RestoreConfig $script:SettingsB
            Engine = [RestoreEngine]::new($script:Log, (Join-Path $out 'backups'), $out)
        }
    }
}

Describe 'Setting.FromHashtable' {
    It 'rehidrata todos los campos que escribe ToHashtable' {
        $s = [Setting]::new('bind', '+jump')
        $s.Type         = [SettingType]::Bind
        $s.Priority     = [SettingPriority]::Fallback
        $s.State        = [SettingState]::Duplicated
        $s.CategoryCode = 'P16'
        $s.Extra['Key']     = 'space'
        $s.Extra['Command'] = '+jump'
        $s.Metadata.SourceFile   = 'C:\cfg\user_keys.vcfg'
        $s.Metadata.SourceLine   = 42
        $s.Metadata.RawLine      = '"space" "+jump"'
        $s.Metadata.Description  = 'salto'
        $s.Metadata.DefaultValue = '+jump'
        $s.Metadata.Hash         = 'abc123'
        $s.Metadata.CapturedAt   = [datetime]::Parse('2026-01-02T03:04:05Z').ToUniversalTime()

        $r = [Setting]::FromHashtable($s.ToHashtable())

        $r.Name                   | Should -Be 'bind'
        $r.Value                  | Should -Be '+jump'
        $r.Type                   | Should -Be ([SettingType]::Bind)
        $r.Priority               | Should -Be ([SettingPriority]::Fallback)
        $r.State                  | Should -Be ([SettingState]::Duplicated)
        $r.CategoryCode           | Should -Be 'P16'
        $r.Extra['Key']           | Should -Be 'space'
        $r.Extra['Command']       | Should -Be '+jump'
        $r.Metadata.SourceFile    | Should -Be 'C:\cfg\user_keys.vcfg'
        $r.Metadata.SourceLine    | Should -Be 42
        $r.Metadata.RawLine       | Should -Be '"space" "+jump"'
        $r.Metadata.Description   | Should -Be 'salto'
        $r.Metadata.DefaultValue  | Should -Be '+jump'
        $r.Metadata.Hash          | Should -Be 'abc123'
        $r.Metadata.CapturedAt    | Should -Be ([datetime]::Parse('2026-01-02T03:04:05Z').ToUniversalTime())
        # Lo que de verdad importa: la clave la sigue calculando Setting::Key().
        $r.Key()                  | Should -Be 'bind::space'
    }

    It 'sobrevive al viaje por JSON, que es como llega el inventario' {
        $s = [Setting]::new('quickswitch', 'slot1; slot3')
        $s.Type = [SettingType]::Alias
        $s.Extra['Body'] = 'slot1; slot3'
        $json = ($s.ToHashtable() | ConvertTo-Json -Depth 8) | ConvertFrom-Json

        $r = [Setting]::FromHashtable($json)
        $r.Type          | Should -Be ([SettingType]::Alias)
        $r.Extra['Body'] | Should -Be 'slot1; slot3'
        $r.Key()         | Should -Be 'alias::quickswitch'
    }

    It 'degrada a valores neutros cualquier campo ausente o con basura' {
        $r = [Setting]::FromHashtable(@{
            name = 'x'; type = 'NoExiste'; priority = '??'; state = ''
            sourceLine = 'no-es-un-numero'; capturedAt = 'no-es-una-fecha'; extra = 'basura'
        })

        $r.Value                 | Should -Be ''
        $r.Type                  | Should -Be ([SettingType]::Unknown)
        $r.Priority              | Should -Be ([SettingPriority]::LiveConfig)
        $r.State                 | Should -Be ([SettingState]::Unknown)
        $r.CategoryCode          | Should -Be 'P48'
        $r.Metadata.SourceLine   | Should -Be -1
        $r.Extra.Count           | Should -Be 0
        # Ni la hora actual ni una excepcion: un valor neutro y determinista.
        $r.Metadata.CapturedAt   | Should -Be ([datetime]::MinValue)
    }

    It 'descarta un ajuste sin nombre porque no tendria clave posible' {
        [Setting]::FromHashtable(@{ value = '1' }) | Should -BeNullOrEmpty
        [Setting]::FromHashtable($null)            | Should -BeNullOrEmpty
    }
}

Describe 'RestoreEngine' {
    Context 'preview' {
        It 'no escribe absolutamente nada en modo solo-mostrar' {
            $sc = New-RestoreScenario -Name 'preview'
            $plan = $sc.Engine.Plan($sc.SnapId, $sc.Live, [RestoreTarget]::Output, $false)

            $plan.Applied    | Should -BeFalse
            $plan.RolledBack | Should -BeFalse
            $plan.BackupPath | Should -Be ''
            (Test-Path -LiteralPath (Join-Path $sc.Out 'restore')) | Should -BeFalse
            [System.IO.File]::ReadAllText($sc.F1) | Should -Be $script:StateB1
            [System.IO.File]::ReadAllText($sc.F2) | Should -Be $script:StateB2
            $plan.Render() | Should -BeLike '*SOLO-MOSTRAR*'
        }

        It 'planifica los dos archivos del snapshot con su destino en la salida' {
            $sc = New-RestoreScenario -Name 'preview-files'
            $plan = $sc.Engine.Plan($sc.SnapId, $sc.Live, [RestoreTarget]::Output, $false)

            $plan.Files.Count | Should -Be 2
            $plan.WriteCount() | Should -Be 2
            @($plan.Files | ForEach-Object { $_.Name }) | Should -Be @('cs2_user_convars.vcfg', 'config.cfg')
            foreach ($f in $plan.Files) {
                $f.TargetPath   | Should -BeLike "*restore*$($sc.SnapId)*files*"
                $f.OriginalPath | Should -Not -BeNullOrEmpty
                $f.Status       | Should -Be 'create'
            }
            $plan.Warnings.Count | Should -Be 0
        }

        It 'invierte el diff: la base es la config viva y el objetivo el snapshot' {
            $sc = New-RestoreScenario -Name 'preview-diff'
            $plan = $sc.Engine.Plan($sc.SnapId, $sc.Live, [RestoreTarget]::Output, $false)

            $plan.Diff.HasBaseline | Should -BeTrue
            $plan.Diff.Baseline    | Should -Be 'config'
            # sensitivity vuelve de 1.1 a 2.5: el "antes" es lo que hay vivo.
            $sens = @($plan.Diff.Modified | Where-Object { $_['key'] -eq 'sensitivity' })[0]
            $sens['previousValue'] | Should -Be '1.1'
            $sens['currentValue']  | Should -Be '2.5'
            # cl_radar_scale esta en el snapshot y no en la config viva: alta.
            @($plan.Diff.Added  | ForEach-Object { $_['key'] }) | Should -Be @('cl_radar_scale')
            # volume esta vivo y no en el snapshot: se perderia.
            @($plan.Diff.Removed | ForEach-Object { $_['key'] }) | Should -Be @('volume')
        }
    }

    Context 'filtro del preview' {
        It 'muestra solo los cambios de value y cuenta aparte los demas' {
            $sc = New-RestoreScenario -Name 'filtro'
            $plan = $sc.Engine.Plan($sc.SnapId, $sc.Live, [RestoreTarget]::Output, $false)

            # El diff completo ve los tres cambios (A1 no se toca)...
            $plan.Diff.Modified.Count | Should -Be 3
            $solo = @($plan.Diff.Modified | Where-Object { $_['key'] -eq 'cl_crosshairsize' })[0]
            @($solo['fields'])        | Should -Be @('state')

            # ...pero el preview del Apply deja fuera el que no toca el valor.
            @($plan.ValueChanges() | ForEach-Object { $_['key'] }) | Should -Be @('sensitivity', 'bind::space')
            $plan.HiddenChangeCount() | Should -Be 1
            $plan.Render() | Should -Not -BeLike '*cl_crosshairsize*'
            $plan.Render() | Should -BeLike '*omitidas 1*'
        }
    }

    Context 'apply a la carpeta de salida' {
        It 'escribe las copias del snapshot en la salida y no toca la config del jugador' {
            $sc = New-RestoreScenario -Name 'apply-out'
            $plan = $sc.Engine.Plan($sc.SnapId, $sc.Live, [RestoreTarget]::Output, $false)
            $result = $sc.Engine.Apply($plan)

            $result.Applied    | Should -BeTrue
            $result.RolledBack | Should -BeFalse

            $dir = Join-Path (Join-Path (Join-Path $sc.Out 'restore') $sc.SnapId) 'files'
            [System.IO.File]::ReadAllText((Join-Path $dir 'cs2_user_convars.vcfg')) | Should -Be $script:StateA1
            [System.IO.File]::ReadAllText((Join-Path $dir 'config.cfg'))            | Should -Be $script:StateA2

            # Los archivos vivos siguen en el estado B: por defecto no se tocan.
            [System.IO.File]::ReadAllText($sc.F1) | Should -Be $script:StateB1
            [System.IO.File]::ReadAllText($sc.F2) | Should -Be $script:StateB2

            $record = Join-Path (Join-Path (Join-Path $sc.Out 'restore') $sc.SnapId) 'RestorePlan.json'
            Test-Path -LiteralPath $record | Should -BeTrue
            (Get-Content -LiteralPath $record -Raw | ConvertFrom-Json).target | Should -Be 'Output'
        }

        It 'no vuelve a escribir lo que ya coincide con el snapshot' {
            $sc = New-RestoreScenario -Name 'apply-idempotente'
            $sc.Engine.Apply($sc.Engine.Plan($sc.SnapId, $sc.Live, [RestoreTarget]::Output, $false)) | Out-Null

            $second = $sc.Engine.Plan($sc.SnapId, $sc.Live, [RestoreTarget]::Output, $false)
            $second.WriteCount() | Should -Be 0
            @($second.Files | ForEach-Object { $_.Status }) | Should -Be @('identical', 'identical')
        }
    }

    Context 'apply sobre los archivos vivos' {
        It 'exige el permiso explicito antes incluso de planificar' {
            $sc = New-RestoreScenario -Name 'gate'
            { $sc.Engine.Plan($sc.SnapId, $sc.Live, [RestoreTarget]::LiveFiles, $false) } |
                Should -Throw '*AllowLiveFileWrites*'
            (Test-Path -LiteralPath (Join-Path $sc.Out 'restore')) | Should -BeFalse
        }

        It 'devuelve los archivos del jugador al snapshot dejando el estado previo respaldado' {
            $sc = New-RestoreScenario -Name 'apply-live'
            $plan = $sc.Engine.Plan($sc.SnapId, $sc.Live, [RestoreTarget]::LiveFiles, $true)
            @($plan.Files | ForEach-Object { $_.Status }) | Should -Be @('overwrite', 'overwrite')

            $result = $sc.Engine.Apply($plan)

            $result.Applied | Should -BeTrue
            [System.IO.File]::ReadAllText($sc.F1) | Should -Be $script:StateA1
            [System.IO.File]::ReadAllText($sc.F2) | Should -Be $script:StateA2

            # El backup previo existe y contiene el estado que se acaba de tapar.
            $result.BackupPath | Should -Not -BeNullOrEmpty
            $backups = @(Get-ChildItem -LiteralPath $result.BackupPath -File | Sort-Object Name)
            $backups.Count | Should -Be 2
            [System.IO.File]::ReadAllText($backups[0].FullName) | Should -Be $script:StateB1
            [System.IO.File]::ReadAllText($backups[1].FullName) | Should -Be $script:StateB2
        }
    }

    Context 'rollback' {
        It 'deshace las escrituras ya hechas cuando una falla a mitad' {
            # El segundo archivo vive en una carpeta aparte; despues de tomar el
            # snapshot esa carpeta se sustituye por un archivo, asi que su
            # escritura fallara con el primer archivo ya sobreescrito.
            $sc = New-RestoreScenario -Name 'rollback' -SecondDir 'blocked'
            $plan = $sc.Engine.Plan($sc.SnapId, $sc.Live, [RestoreTarget]::LiveFiles, $true)
            $plan.WriteCount() | Should -Be 2

            Remove-Item -LiteralPath $sc.SecDir -Recurse -Force
            [System.IO.File]::WriteAllText($sc.SecDir, 'ya no soy una carpeta')

            { $sc.Engine.Apply($plan) } | Should -Throw '*revertido*'

            $plan.RolledBack | Should -BeTrue
            $plan.Applied    | Should -BeFalse
            # El jugador queda exactamente como estaba.
            [System.IO.File]::ReadAllText($sc.F1) | Should -Be $script:StateB1
            (Test-Path -LiteralPath (Join-Path $sc.SecDir 'config.cfg')) | Should -BeFalse
            [System.IO.File]::ReadAllText($sc.SecDir) | Should -Be 'ya no soy una carpeta'
        }

        It 'aborta sin escribir nada si un destino existe y no es un archivo' {
            $sc = New-RestoreScenario -Name 'precondicion'
            $plan = $sc.Engine.Plan($sc.SnapId, $sc.Live, [RestoreTarget]::LiveFiles, $true)
            Remove-Item -LiteralPath $sc.F1 -Force
            New-Item -ItemType Directory -Path $sc.F1 -Force | Out-Null

            { $sc.Engine.Apply($plan) } | Should -Throw '*no es un archivo*'

            # La fase 0 corta antes de tocar el segundo archivo.
            [System.IO.File]::ReadAllText($sc.F2) | Should -Be $script:StateB2
            $plan.Applied | Should -BeFalse
        }
    }

    Context 'errores accionables' {
        It 'dice que snapshots hay cuando el pedido no existe' {
            $sc = New-RestoreScenario -Name 'inexistente'
            { $sc.Engine.Plan('20990101-000000', $sc.Live, [RestoreTarget]::Output, $false) } |
                Should -Throw "*No existe el snapshot '20990101-000000'*Disponibles: $($sc.SnapId)*"
        }

        It 'resuelve latest al snapshot mas reciente' {
            $sc = New-RestoreScenario -Name 'latest'
            $sc.Engine.ResolveSnapshotId('latest') | Should -Be $sc.SnapId
            $sc.Engine.ResolveSnapshotId('')       | Should -Be $sc.SnapId
        }

        It 'explica que hacer cuando el inventario esta corrupto' {
            $sc = New-RestoreScenario -Name 'corrupto'
            $inv = Join-Path (Join-Path (Join-Path $sc.Out 'backups') $sc.SnapId) 'Inventory.json'
            '{ esto no es json' | Out-File -LiteralPath $inv -Encoding utf8

            { $sc.Engine.Plan($sc.SnapId, $sc.Live, [RestoreTarget]::Output, $false) } |
                Should -Throw '*ilegible o corrupto*Elija otro snapshot*'
            (Test-Path -LiteralPath (Join-Path $sc.Out 'restore')) | Should -BeFalse
        }

        It 'explica que hacer cuando el snapshot no tiene inventario' {
            $sc = New-RestoreScenario -Name 'sin-inventario'
            Remove-Item -LiteralPath (Join-Path (Join-Path (Join-Path $sc.Out 'backups') $sc.SnapId) 'Inventory.json') -Force

            { $sc.Engine.Plan($sc.SnapId, $sc.Live, [RestoreTarget]::Output, $false) } |
                Should -Throw '*no tiene inventario*'
        }

        It 'se niega a restaurar un inventario vacio en lugar de borrar la config' {
            $sc = New-RestoreScenario -Name 'inventario-vacio'
            $inv = Join-Path (Join-Path (Join-Path $sc.Out 'backups') $sc.SnapId) 'Inventory.json'
            '{ "total": 0, "categories": [] }' | Out-File -LiteralPath $inv -Encoding utf8

            { $sc.Engine.Plan($sc.SnapId, $sc.Live, [RestoreTarget]::Output, $false) } |
                Should -Throw '*ningun ajuste utilizable*'
        }

        It 'avisa y no escribe nada si el snapshot no conserva las copias de raw' {
            $sc = New-RestoreScenario -Name 'sin-raw'
            Remove-Item -LiteralPath (Join-Path (Join-Path (Join-Path $sc.Out 'backups') $sc.SnapId) 'raw') -Recurse -Force

            $plan = $sc.Engine.Plan($sc.SnapId, $sc.Live, [RestoreTarget]::Output, $false)
            $plan.Files.Count | Should -Be 0
            @($plan.Warnings) -join ' ' | Should -BeLike '*no conserva copias*'
            # El preview semantico sigue siendo valido: sale del inventario.
            $plan.Diff.HasBaseline | Should -BeTrue
        }
    }
}
