# Dot-source from any checkout: . ./scripts/enter-dev.ps1
$ErrorActionPreference = 'Stop'
$riffToolDirs = @(
    'D:\Git\cmd', 'D:\Program\nodejs', 'C:\Python314',
    'C:\Program Files\PowerShell\7',
    "$env:LOCALAPPDATA\Programs\RiffLoopTools\gh\bin",
    "$env:LOCALAPPDATA\Programs\RiffLoopTools\device-python\Scripts"
)
foreach ($riffToolDir in $riffToolDirs) {
    if (Test-Path -LiteralPath $riffToolDir) {
        $env:Path = "$riffToolDir;" + (($env:Path.Split(';') | Where-Object { $_ -ne $riffToolDir }) -join ';')
    }
}
Set-Location -LiteralPath (Split-Path $PSScriptRoot -Parent)
