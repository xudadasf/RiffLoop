# Use a shortcut so Chinese paths work without cmd.exe code-page assumptions.
$ErrorActionPreference = 'Stop'
$entry = Join-Path $PSScriptRoot 'renew-ipad.ps1'
$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path $desktop 'RiffLoop 一键续签.lnk'))
$shortcut.TargetPath = (Get-Command pwsh -ErrorAction Stop).Source
$shortcut.Arguments = '-NoProfile -NoExit -ExecutionPolicy Bypass -File "' + $entry + '"'
$shortcut.WorkingDirectory = Split-Path $PSScriptRoot -Parent
$shortcut.Description = 'USB 连接并解锁 iPad 后双击；使用原账号续签当前版本。'
$shortcut.IconLocation = "$env:LOCALAPPDATA\Sideloadly\Sideloadly.exe,0"
$shortcut.Save()
Write-Host '已创建桌面入口：RiffLoop 一键续签'
