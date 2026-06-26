#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pruebas unitarias del tokenizer y de los parsers (VDF/VCFG/CFG).
#>

BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $root 'src/Bootstrap.ps1')
    $script:Log = [Logger]::new([LogLevel]::Error, $null)

    function New-TempFile {
        param([string] $Content, [string] $Extension)
        $path = [System.IO.Path]::Combine(
            [System.IO.Path]::GetTempPath(),
            ("cs2_{0}{1}" -f ([guid]::NewGuid().ToString('N')), $Extension))
        Set-Content -LiteralPath $path -Value $Content -Encoding utf8
        return $path
    }

    function New-DiscoveredFile {
        param([string] $Path, [string] $Kind)
        $df = [DiscoveredFile]::new()
        $df.Path = $Path
        $df.Name = Split-Path -Leaf $Path
        $df.Kind = $Kind
        $df.Size = (Get-Item -LiteralPath $Path).Length
        $df.Hash = 'test'
        return $df
    }
}

Describe 'Tokenizer' {
    It 'tokeniza cadenas entrecomilladas conservando espacios internos' {
        $tokens = [Tokenizer]::new('"sensitivity" "2.5 raw"').Tokenize()
        $strings = @($tokens | Where-Object { $_.Kind -eq [TokenKind]::String })
        $strings.Count | Should -Be 2
        $strings[0].Text | Should -Be 'sensitivity'
        $strings[1].Text | Should -Be '2.5 raw'
        $strings[1].Quoted | Should -BeTrue
    }

    It 'ignora comentarios de linea y de bloque' {
        $src = "cl_foo 1 // comentario`n/* bloque */ cl_bar 2"
        $tokens = [Tokenizer]::new($src).Tokenize()
        $comments = @($tokens | Where-Object { $_.Kind -eq [TokenKind]::Comment })
        $comments.Count | Should -Be 2
    }

    It 'procesa escapes dentro de cadenas' {
        $tokens = [Tokenizer]::new('"say \"gg\""').Tokenize()
        (@($tokens | Where-Object { $_.Kind -eq [TokenKind]::String })[0].Text) |
            Should -Be 'say "gg"'
    }

    It 'reconoce llaves de bloque' {
        $tokens = [Tokenizer]::new('"k" { "a" "b" }').Tokenize()
        (@($tokens | Where-Object { $_.Kind -eq [TokenKind]::OpenBrace }).Count)  | Should -Be 1
        (@($tokens | Where-Object { $_.Kind -eq [TokenKind]::CloseBrace }).Count) | Should -Be 1
    }
}

Describe 'VdfParser + VcfgParser' {
    It 'extrae convars de un .vcfg anidado' {
        $vcfg = @'
"cs2_user_convars.vcfg"
{
    "convars"
    {
        "sensitivity" "2.5"
        "fps_max" "400"
        "cl_radar_scale" "0.4"
    }
}
'@
        $path = New-TempFile -Content $vcfg -Extension '.vcfg'
        try {
            $file = New-DiscoveredFile -Path $path -Kind 'vcfg'
            $settings = [VcfgParser]::new().Parse($file, $script:Log)
            $names = $settings.Name
            $names | Should -Contain 'sensitivity'
            $names | Should -Contain 'fps_max'
            ($settings | Where-Object Name -eq 'fps_max').Value | Should -Be '400'
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    It 'interpreta nodos dentro de contexto bind como Bind' {
        $vcfg = @'
"cs2_user_keys.vcfg"
{
    "keyboard"
    {
        "bindings"
        {
            "w" "+forward"
            "space" "+jump"
        }
    }
}
'@
        $path = New-TempFile -Content $vcfg -Extension '.vcfg'
        try {
            $file = New-DiscoveredFile -Path $path -Kind 'vcfg'
            $settings = [VcfgParser]::new().Parse($file, $script:Log)
            $binds = @($settings | Where-Object { $_.Type -eq [SettingType]::Bind })
            $binds.Count | Should -Be 2
            ($binds | Where-Object { $_.Extra['Key'] -eq 'w' }).Extra['Command'] |
                Should -Be '+forward'
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    It 'no falla con un archivo malformado (tolerancia)' {
        $bad = '"a" "b" { "c" '   # llave sin cerrar
        $path = New-TempFile -Content $bad -Extension '.vcfg'
        try {
            $file = New-DiscoveredFile -Path $path -Kind 'vcfg'
            { [VcfgParser]::new().Parse($file, $script:Log) } | Should -Not -Throw
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }
}

Describe 'CfgParser' {
    It 'distingue convars, binds y alias' {
        $cfg = @'
// autoexec de prueba
sensitivity "2.0"
fps_max 400
bind "w" "+forward"
alias "+jumpthrow" "+jump;-attack"
'@
        $path = New-TempFile -Content $cfg -Extension '.cfg'
        try {
            $file = New-DiscoveredFile -Path $path -Kind 'cfg'
            $settings = [CfgParser]::new().Parse($file, $script:Log)

            (@($settings | Where-Object { $_.Type -eq [SettingType]::Bind }).Count)  | Should -Be 1
            (@($settings | Where-Object { $_.Type -eq [SettingType]::Alias }).Count) | Should -Be 1

            $sens = $settings | Where-Object Name -eq 'sensitivity'
            $sens.Value | Should -Be '2.0'

            $bind = $settings | Where-Object { $_.Type -eq [SettingType]::Bind }
            $bind.Extra['Key']     | Should -Be 'w'
            $bind.Extra['Command'] | Should -Be '+forward'
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    It 'infiere tipos numericos y booleanos' {
        $cfg = "cl_bool 1`ncl_int 64`ncl_float 0.45`ncl_str hola"
        $path = New-TempFile -Content $cfg -Extension '.cfg'
        try {
            $file = New-DiscoveredFile -Path $path -Kind 'cfg'
            $settings = [CfgParser]::new().Parse($file, $script:Log)
            ($settings | Where-Object Name -eq 'cl_bool').Type  | Should -Be ([SettingType]::Bool)
            ($settings | Where-Object Name -eq 'cl_int').Type   | Should -Be ([SettingType]::Integer)
            ($settings | Where-Object Name -eq 'cl_float').Type | Should -Be ([SettingType]::Float)
            ($settings | Where-Object Name -eq 'cl_str').Type   | Should -Be ([SettingType]::String)
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }
}
