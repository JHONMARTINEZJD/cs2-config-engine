Set-StrictMode -Version Latest
. ./src/Bootstrap.ps1 -Root ./src
$source = '"say \"gg\""'
Write-Host "SOURCE=$source"
$tokens = [Tokenizer]::new($source).Tokenize()
$tokens | ForEach-Object { Write-Host ("{0}:{1}" -f $_.Kind, $_.Text) }
