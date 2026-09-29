#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pruebas del diff semantico por setting entre snapshots (A1).
.DESCRIPTION
    Cubren alta, baja, cambio de valor, ausencia de cambios, ausencia de snapshot
    anterior, inventario ausente/corrupto/incoherente, identidad por clave estable
    (binds y alias), duplicados y determinismo del JSON.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'src/Bootstrap.ps1')

    $script:Log    = [Logger]::new([LogLevel]::Error, $null)
    $script:Engine = [ConfigDiffEngine]::new($script:Log)
    $script:Report = [ReportGenerator]::new($script:Log)

    function New-DiffSetting {
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
        if ($Key) { $s.Extra['Key'] = $Key }
        $s.Metadata.Hash = Get-StringHash -Text ('{0}={1}' -f $Name, $Value)
        return $s
    }

    # Agrupa como lo hace SyncEngine: categorias en el orden del catalogo.
    function New-DiffConfig {
        param([Setting[]] $Settings)
        $cfg   = [GameConfig]::new()
        $byCat = @{}
        foreach ($s in $Settings) {
            if (-not $byCat.ContainsKey($s.CategoryCode)) {
                $byCat[$s.CategoryCode] = [System.Collections.Generic.List[Setting]]::new()
            }
            $byCat[$s.CategoryCode].Add($s)
        }
        foreach ($code in ($byCat.Keys | Sort-Object { [CategoryMap]::OrderFor($_) })) {
            $cat = [ConfigCategory]::new($code, [CategoryMap]::NameFor($code), [CategoryMap]::OrderFor($code))
            foreach ($s in $byCat[$code]) { $cat.Add($s) }
            $cfg.Categories.Add($cat)
        }
        return $cfg
    }

    function Save-DiffInventory {
        param([GameConfig] $Cfg, [string] $Path)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $script:Report.WriteInventory($Cfg, $Path)
        return $Path
    }

    function New-DiffSnapshot {
        param([string] $Id, [string] $Path, [string] $Hash = 'hash-actual')
        $snap = [Snapshot]::new()
        $snap.Id          = $Id
        $snap.Path        = $Path
        $snap.Timestamp   = [datetime]::Parse('2026-01-02T10:00:00Z')
        $snap.Hash        = $Hash
        $snap.TotalSize   = 1234
        $snap.BindCount   = 2
        $snap.ConvarCount = 3
        $snap.AliasCount  = 1
        return $snap
    }

    # Estado base: 5 claves distintas, una de cada forma relevante.
    $script:BaseSettings = @(
        (New-DiffSetting -Name 'sensitivity'      -Value '2.0'           -Type 'Float'   -Category 'P14')
        (New-DiffSetting -Name 'cl_crosshairsize' -Value '2'             -Type 'Integer' -Category 'P24')
        (New-DiffSetting -Name 'cl_radar_scale'   -Value '0.4'           -Type 'Float'   -Category 'P29')
        (New-DiffSetting -Name 'bind'             -Value '+jump'         -Type 'Bind'    -Category 'P16' -Key 'space')
        (New-DiffSetting -Name 'quickswitch'      -Value 'slot1; slot3'  -Type 'Alias'   -Category 'P18')
    )
}

Describe 'ConfigDiffEngine' {
    BeforeEach {
        $script:BaseConfig   = New-DiffConfig $script:BaseSettings
        $script:BaseInventory = Save-DiffInventory -Cfg $script:BaseConfig `
            -Path (Join-Path $TestDrive 'backups/20260101-100000/Inventory.json')
    }

    Context 'altas' {
        It 'reporta una convar nueva como anadida y no como cambio' {
            $cur = New-DiffConfig (@($script:BaseSettings) + @(
                (New-DiffSetting -Name 'volume' -Value '0.5' -Type 'Float' -Category 'P34')))
            $d = $script:Engine.Compare($cur, 'cur', '20260101-100000', $script:BaseInventory)

            $d.HasBaseline     | Should -BeTrue
            $d.Baseline        | Should -Be 'inventory'
            $d.Added.Count     | Should -Be 1
            $d.Removed.Count   | Should -Be 0
            $d.Modified.Count  | Should -Be 0
            $d.Unchanged       | Should -Be 5
            $d.Added[0]['key']          | Should -Be 'volume'
            $d.Added[0]['value']        | Should -Be '0.5'
            $d.Added[0]['category']     | Should -Be 'P34'
            $d.Added[0]['categoryName'] | Should -Be 'Audio'
        }

        It 'identifica un bind nuevo por su tecla, no por el nombre bind' {
            $cur = New-DiffConfig (@($script:BaseSettings) + @(
                (New-DiffSetting -Name 'bind' -Value '+duck' -Type 'Bind' -Category 'P17' -Key 'ctrl')))
            $d = $script:Engine.Compare($cur, 'cur', '20260101-100000', $script:BaseInventory)

            $d.Added.Count    | Should -Be 1
            $d.Modified.Count | Should -Be 0
            $d.Added[0]['key'] | Should -Be 'bind::ctrl'
        }
    }

    Context 'bajas' {
        It 'reporta la clave que desaparece conservando el valor que se pierde' {
            $cur = New-DiffConfig (@($script:BaseSettings) | Where-Object { $_.Name -ne 'cl_radar_scale' })
            $d = $script:Engine.Compare($cur, 'cur', '20260101-100000', $script:BaseInventory)

            $d.Removed.Count | Should -Be 1
            $d.Added.Count   | Should -Be 0
            $d.Removed[0]['key']   | Should -Be 'cl_radar_scale'
            $d.Removed[0]['value'] | Should -Be '0.4'
        }

        It 'reporta la baja de un alias por su clave alias::<nombre>' {
            $cur = New-DiffConfig (@($script:BaseSettings) | Where-Object { $_.Type -ne [SettingType]::Alias })
            $d = $script:Engine.Compare($cur, 'cur', '20260101-100000', $script:BaseInventory)

            $d.Removed.Count     | Should -Be 1
            $d.Removed[0]['key'] | Should -Be 'alias::quickswitch'
        }
    }

    Context 'cambios de valor' {
        It 'reporta antes y despues de una convar modificada' {
            $cur = New-DiffConfig @(
                (New-DiffSetting -Name 'sensitivity'      -Value '2.0'          -Type 'Float'   -Category 'P14')
                (New-DiffSetting -Name 'cl_crosshairsize' -Value '3'            -Type 'Integer' -Category 'P24')
                (New-DiffSetting -Name 'cl_radar_scale'   -Value '0.4'          -Type 'Float'   -Category 'P29')
                (New-DiffSetting -Name 'bind'             -Value '+jump'        -Type 'Bind'    -Category 'P16' -Key 'space')
                (New-DiffSetting -Name 'quickswitch'      -Value 'slot1; slot3' -Type 'Alias'   -Category 'P18')
            )
            $d = $script:Engine.Compare($cur, 'cur', '20260101-100000', $script:BaseInventory)

            $d.Modified.Count | Should -Be 1
            $d.Added.Count    | Should -Be 0
            $d.Removed.Count  | Should -Be 0
            $d.Unchanged      | Should -Be 4
            $m = $d.Modified[0]
            $m['key']           | Should -Be 'cl_crosshairsize'
            $m['previousValue'] | Should -Be '2'
            $m['currentValue']  | Should -Be '3'
            @($m['fields'])     | Should -Be @('value')
            $m['categoryName']  | Should -Be 'Crosshair'
        }

        It 'rebindear la misma tecla es un cambio, no una alta mas una baja' {
            $cur = New-DiffConfig @(
                (New-DiffSetting -Name 'sensitivity'      -Value '2.0'          -Type 'Float'   -Category 'P14')
                (New-DiffSetting -Name 'cl_crosshairsize' -Value '2'            -Type 'Integer' -Category 'P24')
                (New-DiffSetting -Name 'cl_radar_scale'   -Value '0.4'          -Type 'Float'   -Category 'P29')
                (New-DiffSetting -Name 'bind'             -Value '+attack'      -Type 'Bind'    -Category 'P19' -Key 'space')
                (New-DiffSetting -Name 'quickswitch'      -Value 'slot1; slot3' -Type 'Alias'   -Category 'P18')
            )
            $d = $script:Engine.Compare($cur, 'cur', '20260101-100000', $script:BaseInventory)

            $d.Added.Count    | Should -Be 0
            $d.Removed.Count  | Should -Be 0
            $d.Modified.Count | Should -Be 1
            $m = $d.Modified[0]
            $m['key']              | Should -Be 'bind::space'
            $m['previousValue']    | Should -Be '+jump'
            $m['currentValue']     | Should -Be '+attack'
            $m['previousCategory'] | Should -Be 'P16'
            $m['category']         | Should -Be 'P19'
            @($m['fields'])        | Should -Be @('value', 'category')
        }

        It 'un duplicado nuevo se refleja como cambio de occurrences sin perder el valor vigente' {
            $cur = New-DiffConfig (@($script:BaseSettings) + @(
                (New-DiffSetting -Name 'cl_crosshairsize' -Value '1' -Type 'Integer' -Category 'P24' -State 'Duplicated')))
            $d = $script:Engine.Compare($cur, 'cur', '20260101-100000', $script:BaseInventory)

            $d.Added.Count    | Should -Be 0
            $d.Modified.Count | Should -Be 1
            $m = $d.Modified[0]
            $m['key']                 | Should -Be 'cl_crosshairsize'
            @($m['fields'])           | Should -Be @('occurrences')
            $m['currentValue']        | Should -Be '2'
            $m['currentOccurrences']  | Should -Be 2
            $m['previousOccurrences'] | Should -Be 1
        }
    }

    Context 'sin cambios' {
        It 'no reporta deltas cuando la config es identica' {
            $d = $script:Engine.Compare($script:BaseConfig, 'cur', '20260101-100000', $script:BaseInventory)

            $d.HasBaseline     | Should -BeTrue
            $d.TotalChanges()  | Should -Be 0
            $d.Unchanged       | Should -Be 5
            $d.PreviousTotal   | Should -Be 5
            $d.CurrentTotal    | Should -Be 5
            @($d.ByCategory()).Count | Should -Be 0
        }
    }

    Context 'sin snapshot anterior' {
        It 'degrada a "sin base de comparacion" sin advertencia ni deltas inventados' {
            $d = $script:Engine.Compare($script:BaseConfig, 'cur', '', '')

            $d.HasBaseline      | Should -BeFalse
            $d.Baseline         | Should -Be 'none'
            $d.BaselineWarning  | Should -Be ''
            $d.PreviousTotal    | Should -Be 0
            $d.CurrentTotal     | Should -Be 5
            $d.TotalChanges()   | Should -Be 0
        }
    }

    Context 'inventario anterior no utilizable' {
        It 'no aborta y avisa cuando el inventario esta truncado' {
            $path = Join-Path $TestDrive 'truncado.json'
            [System.IO.File]::WriteAllText($path, (Get-Content -LiteralPath $script:BaseInventory -Raw).Substring(0, 120))
            $d = $script:Engine.Compare($script:BaseConfig, 'cur', '20260101-100000', $path)

            $d.HasBaseline     | Should -BeFalse
            $d.Baseline        | Should -Be 'none'
            $d.BaselineWarning | Should -Not -BeNullOrEmpty
            $d.TotalChanges()  | Should -Be 0
        }

        It 'no aborta y avisa cuando el inventario no existe (snapshot rotado)' {
            $d = $script:Engine.Compare($script:BaseConfig, 'cur', '20260101-100000',
                                        (Join-Path $TestDrive 'no-existe/Inventory.json'))
            $d.HasBaseline     | Should -BeFalse
            $d.BaselineWarning | Should -Not -BeNullOrEmpty
        }

        It 'no aborta y avisa cuando el inventario esta vacio' {
            $path = Join-Path $TestDrive 'vacio.json'
            [System.IO.File]::WriteAllText($path, '')
            $d = $script:Engine.Compare($script:BaseConfig, 'cur', '20260101-100000', $path)

            $d.HasBaseline     | Should -BeFalse
            $d.BaselineWarning | Should -Not -BeNullOrEmpty
        }

        It 'no aborta y avisa cuando el JSON es valido pero no tiene la forma esperada' {
            $path = Join-Path $TestDrive 'sinforma.json'
            [System.IO.File]::WriteAllText($path, '{ "cosa": 1 }')
            $d = $script:Engine.Compare($script:BaseConfig, 'cur', '20260101-100000', $path)

            $d.HasBaseline     | Should -BeFalse
            $d.BaselineWarning | Should -Not -BeNullOrEmpty
        }

        It 'detecta un inventario incoherente (declara ajustes que no contiene)' {
            $path = Join-Path $TestDrive 'incoherente.json'
            [System.IO.File]::WriteAllText($path, '{ "total": 42, "categories": [] }')
            $d = $script:Engine.Compare($script:BaseConfig, 'cur', '20260101-100000', $path)

            $d.HasBaseline     | Should -BeFalse
            $d.BaselineWarning | Should -Match '42'
        }
    }

    Context 'determinismo' {
        It 'produce el mismo JSON byte a byte para el mismo par de snapshots' {
            $cur = New-DiffConfig (@($script:BaseSettings) + @(
                (New-DiffSetting -Name 'volume' -Value '0.5' -Type 'Float' -Category 'P34')))
            $a = $script:Engine.Compare($cur, 'cur', '20260101-100000', $script:BaseInventory).ToHashtable() | ConvertTo-Json -Depth 12
            $b = $script:Engine.Compare($cur, 'cur', '20260101-100000', $script:BaseInventory).ToHashtable() | ConvertTo-Json -Depth 12
            $a | Should -BeExactly $b
        }

        It 'no depende del orden en que lleguen los settings' {
            $settings = @($script:BaseSettings) + @(
                (New-DiffSetting -Name 'volume' -Value '0.5' -Type 'Float' -Category 'P34'))
            $a = $script:Engine.Compare((New-DiffConfig $settings), 'cur', '20260101-100000',
                    $script:BaseInventory).ToHashtable() | ConvertTo-Json -Depth 12
            $b = $script:Engine.Compare((New-DiffConfig @($settings[4,1,5,0,3,2])), 'cur', '20260101-100000',
                    $script:BaseInventory).ToHashtable() | ConvertTo-Json -Depth 12
            $a | Should -BeExactly $b
        }

        It 'no introduce marcas de tiempo en el diff' {
            $json = $script:Engine.Compare($script:BaseConfig, 'cur', '20260101-100000',
                        $script:BaseInventory).ToHashtable() | ConvertTo-Json -Depth 12
            $json | Should -Not -Match '\d{4}-\d{2}-\d{2}T'
        }

        It 'ordena las entradas por orden de categoria y luego por clave' {
            $cur = New-DiffConfig (@($script:BaseSettings) + @(
                (New-DiffSetting -Name 'volume'       -Value '0.5' -Type 'Float' -Category 'P34')
                (New-DiffSetting -Name 'bind'         -Value '+duck' -Type 'Bind' -Category 'P17' -Key 'ctrl')
                (New-DiffSetting -Name 'cl_radar_icon_scale_friendly' -Value '1' -Type 'Float' -Category 'P29')))
            $d = $script:Engine.Compare($cur, 'cur', '20260101-100000', $script:BaseInventory)

            @($d.Added | ForEach-Object { $_['category'] }) | Should -Be @('P17', 'P29', 'P34')
        }
    }
}

Describe 'ReportGenerator: ConfigDiff.json' {
    BeforeEach {
        $script:BaseConfig    = New-DiffConfig $script:BaseSettings
        $script:BaseInventory = Save-DiffInventory -Cfg $script:BaseConfig `
            -Path (Join-Path $TestDrive 'rg/backups/20260101-100000/Inventory.json')
        $script:SnapDir = Join-Path $TestDrive ('rg/snap-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:SnapDir -Force | Out-Null
        $script:Snap    = New-DiffSnapshot -Id '20260102-100000' -Path $script:SnapDir
        $script:Issues  = [System.Collections.Generic.List[ValidationIssue]]::new()
        $script:PrevState = [pscustomobject]@{
            id = '20260101-100000'; timestamp = '2026-01-01T10:00:00Z'; hash = 'hash-anterior'
            totalSize = 1000; bindCount = 1; convarCount = 3; aliasCount = 1
        }
        $script:CurConfig = New-DiffConfig (@($script:BaseSettings) + @(
            (New-DiffSetting -Name 'volume' -Value '0.5' -Type 'Float' -Category 'P34')))
    }

    It 'conserva las claves que ya publicaba antes de A1' {
        $script:Report.GenerateAll($script:CurConfig, $script:Snap, @(), $script:Issues,
                                   $script:PrevState, $script:BaseInventory)
        $json = Get-Content -LiteralPath (Join-Path $script:SnapDir 'ConfigDiff.json') -Raw | ConvertFrom-Json

        $json.previousSnapshot   | Should -Be '20260101-100000'
        $json.currentSnapshot    | Should -Be '20260102-100000'
        $json.changed            | Should -BeTrue
        $json.previousHash       | Should -Be 'hash-anterior'
        $json.currentHash        | Should -Be 'hash-actual'
        $json.deltas.bindCount   | Should -Be 1
        $json.deltas.convarCount | Should -Be 0
        $json.deltas.aliasCount  | Should -Be 0
    }

    It 'anade el nodo settingDiff con el resumen y las listas' {
        $script:Report.GenerateAll($script:CurConfig, $script:Snap, @(), $script:Issues,
                                   $script:PrevState, $script:BaseInventory)
        $json = Get-Content -LiteralPath (Join-Path $script:SnapDir 'ConfigDiff.json') -Raw | ConvertFrom-Json

        $json.settingDiff.baseline           | Should -Be 'inventory'
        $json.settingDiff.baselineWarning    | Should -BeNullOrEmpty
        $json.settingDiff.previousTotal      | Should -Be 5
        $json.settingDiff.currentTotal       | Should -Be 6
        $json.settingDiff.summary.added      | Should -Be 1
        $json.settingDiff.summary.removed    | Should -Be 0
        $json.settingDiff.summary.modified   | Should -Be 0
        $json.settingDiff.summary.unchanged  | Should -Be 5
        @($json.settingDiff.added)[0].key    | Should -Be 'volume'
    }

    It 'marca el diff como sin base cuando no hay snapshot anterior' {
        $script:Report.GenerateAll($script:CurConfig, $script:Snap, @(), $script:Issues, $null, '')
        $json = Get-Content -LiteralPath (Join-Path $script:SnapDir 'ConfigDiff.json') -Raw | ConvertFrom-Json

        $json.previousSnapshot     | Should -BeNullOrEmpty
        $json.settingDiff.baseline | Should -Be 'none'
        @($json.settingDiff.added).Count | Should -Be 0
    }
}

Describe 'ReportGenerator: BackupReport.md' {
    BeforeEach {
        $script:BaseConfig    = New-DiffConfig $script:BaseSettings
        $script:BaseInventory = Save-DiffInventory -Cfg $script:BaseConfig `
            -Path (Join-Path $TestDrive 'md/backups/20260101-100000/Inventory.json')
        $script:SnapDir = Join-Path $TestDrive ('md/snap-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:SnapDir -Force | Out-Null
        $script:Snap   = New-DiffSnapshot -Id '20260102-100000' -Path $script:SnapDir
        $script:Issues = [System.Collections.Generic.List[ValidationIssue]]::new()
        $script:PrevState = [pscustomobject]@{
            id = '20260101-100000'; timestamp = '2026-01-01T10:00:00Z'; hash = 'hash-anterior'
            totalSize = 1000; bindCount = 1; convarCount = 3; aliasCount = 1
        }
    }

    It 'resume altas, bajas y cambios y tabula las cambiadas con antes y despues' {
        $cur = New-DiffConfig @(
            (New-DiffSetting -Name 'sensitivity'      -Value '2.0'          -Type 'Float'   -Category 'P14')
            (New-DiffSetting -Name 'cl_crosshairsize' -Value '3'            -Type 'Integer' -Category 'P24')
            (New-DiffSetting -Name 'bind'             -Value '+jump'        -Type 'Bind'    -Category 'P16' -Key 'space')
            (New-DiffSetting -Name 'quickswitch'      -Value 'slot1; slot3' -Type 'Alias'   -Category 'P18')
            (New-DiffSetting -Name 'volume'           -Value '0.5'          -Type 'Float'   -Category 'P34')
        )
        $script:Report.GenerateAll($cur, $script:Snap, @(), $script:Issues, $script:PrevState, $script:BaseInventory)
        $md = Get-Content -LiteralPath (Join-Path $script:SnapDir 'BackupReport.md') -Raw

        $md | Should -Match '## Cambios frente al snapshot anterior'
        $md | Should -Match 'Anadidas: \*\*1\*\* \| Eliminadas: \*\*1\*\* \| Cambiadas: \*\*1\*\* \| Sin cambios: \*\*3\*\*'
        $md | Should -Match '### Cambiadas'
        $md | Should -Match 'cl_crosshairsize.*\| `2` \| `3` \|'
        $md | Should -Match '### Anadidas'
        $md | Should -Match '### Eliminadas'
    }

    It 'dice con claridad que no hay base cuando es el primer snapshot' {
        $script:Report.GenerateAll($script:BaseConfig, $script:Snap, @(), $script:Issues, $null, '')
        $md = Get-Content -LiteralPath (Join-Path $script:SnapDir 'BackupReport.md') -Raw

        $md | Should -Match 'Sin base de comparacion'
        $md | Should -Match 'primer snapshot registrado'
        $md | Should -Not -Match '### Cambiadas'
        $md | Should -Not -Match '### Anadidas'
    }

    It 'dice con claridad que el inventario anterior no se pudo usar' {
        $bad = Join-Path $TestDrive 'md/corrupto.json'
        [System.IO.File]::WriteAllText($bad, '{ "categories": [ { "code": "P24", "sett')
        $script:Report.GenerateAll($script:BaseConfig, $script:Snap, @(), $script:Issues, $script:PrevState, $bad)
        $md = Get-Content -LiteralPath (Join-Path $script:SnapDir 'BackupReport.md') -Raw

        $md | Should -Match 'Sin base de comparacion'
        $md | Should -Match '20260101-100000'
        $md | Should -Not -Match '### Cambiadas'
    }

    It 'declara que la config es identica cuando no hubo ningun cambio' {
        $script:Report.GenerateAll($script:BaseConfig, $script:Snap, @(), $script:Issues,
                                   $script:PrevState, $script:BaseInventory)
        $md = Get-Content -LiteralPath (Join-Path $script:SnapDir 'BackupReport.md') -Raw

        $md | Should -Match 'identica a la del snapshot anterior'
        $md | Should -Not -Match '### Cambiadas'
    }
}

Describe 'SnapshotManager: ruta del inventario anterior' {
    BeforeAll {
        $script:Mgr = [SnapshotManager]::new($script:Log, (Join-Path $TestDrive 'sm/backups'), 10)
    }

    It 'devuelve cadena vacia cuando no hay snapshot anterior' {
        $script:Mgr.GetInventoryPath('') | Should -Be ''
    }

    It 'compone la ruta del Inventory.json del snapshot indicado' {
        $expected = Join-Path (Join-Path (Join-Path $TestDrive 'sm/backups') '20260101-100000') 'Inventory.json'
        $script:Mgr.GetInventoryPath('20260101-100000') | Should -Be $expected
    }
}

Describe 'ConfigDiffEngine: la categoria viene del contenedor' {
    It 'no reporta cambio de categoria fantasma cuando Setting.CategoryCode no se relleno' {
        # Setting::CategoryCode vale P48 por defecto y solo lo rellena SyncEngine.
        # Un GameConfig armado de otra forma (fixtures, o el preview de un restore
        # construido desde un inventario) llevaba a reportar un cambio de categoria
        # que nunca ocurrio, y a contaminar 'fields' de los cambios reales.
        $anterior = [GameConfig]::new()
        $catAnt = [ConfigCategory]::new('P24', 'Crosshair', 0)
        $sAnt = [Setting]::new('cl_crosshairgap', '-1')
        $sAnt.Type = [SettingType]::Float
        $catAnt.Add($sAnt)          # CategoryCode se queda en P48 a proposito
        $anterior.Categories.Add($catAnt)

        $invPath = Join-Path $TestDrive 'huerfano/Inventory.json'
        $null = Save-DiffInventory -Cfg $anterior -Path $invPath

        # Mismo estado exacto: no debe haber ningun cambio.
        $actual = [GameConfig]::new()
        $catAct = [ConfigCategory]::new('P24', 'Crosshair', 0)
        $sAct = [Setting]::new('cl_crosshairgap', '-1')
        $sAct.Type = [SettingType]::Float
        $catAct.Add($sAct)
        $actual.Categories.Add($catAct)

        $d = [ConfigDiffEngine]::new($script:Log).Compare($actual, 'cur', 'prev', $invPath)
        $d.Baseline           | Should -Be 'inventory'
        $d.Modified.Count     | Should -Be 0
        $d.Added.Count        | Should -Be 0
        $d.Removed.Count      | Should -Be 0
        $d.Unchanged          | Should -Be 1
    }
}
