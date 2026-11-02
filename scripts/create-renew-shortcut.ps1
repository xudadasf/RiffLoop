# Use a shortcut so Chinese paths work without cmd.exe code-page assumptions.
$ErrorActionPreference = 'Stop'
$entry = Join-Path $PSScriptRoot 'renew-ipad.ps1'
$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell
foreach ($item in @(
    @{Name='RiffLoop 一键续签'; Arguments=''; Description='优先无线续签，失败后尝试 USB；使用原账号覆盖安装当前版本。'},
    @{Name='RiffLoop 无线续签设置'; Arguments=' -SetupWifi'; Description='首次用 USB 信任电脑后，启用 iPad 的无线连接；不重装应用。'}
)) {
$shortcut = $shell.CreateShortcut((Join-Path $desktop ($item.Name+'.lnk')))
$shortcut.TargetPath = (Get-Command pwsh -ErrorAction Stop).Source
$shortcut.Arguments = '-NoProfile -NoExit -ExecutionPolicy Bypass -File "' + $entry + '"' + $item.Arguments
$shortcut.WorkingDirectory = Split-Path $PSScriptRoot -Parent
$shortcut.Description = $item.Description
$shortcut.IconLocation = "$env:LOCALAPPDATA\Sideloadly\Sideloadly.exe,0"
$shortcut.Save()
Write-Host ('已创建桌面入口：'+$item.Name)
}
