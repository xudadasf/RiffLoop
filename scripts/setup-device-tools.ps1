# Installs isolated, per-Windows-account device tooling; never modifies the iPad.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/enter-dev.ps1"
$riffDevicePythonRoot = Join-Path $env:LOCALAPPDATA 'Programs\RiffLoopTools\device-python'
$riffDevicePython = Join-Path $riffDevicePythonRoot 'Scripts\python.exe'
if (-not (Test-Path -LiteralPath $riffDevicePython)) {
    python -m venv $riffDevicePythonRoot
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create the per-account Python environment.' }
}
& $riffDevicePython -m pip install --no-cache-dir 'pymobiledevice3==10.9.0' 'Pillow==12.2.0'
if ($LASTEXITCODE -ne 0) { throw 'Device dependencies failed to install.' }
& $riffDevicePython -m pip check
if ($LASTEXITCODE -ne 0) { throw 'Device dependency verification failed.' }
. "$PSScriptRoot/enter-dev.ps1"
python -c "from PIL import Image; import typing_extensions; import pymobiledevice3; print('Device imports OK')"
if ($LASTEXITCODE -ne 0) { throw 'Device imports failed.' }
