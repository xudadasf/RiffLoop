$ErrorActionPreference = 'Stop'
try {
    $pythonCandidates = @('C:\Python314\python.exe')
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCommand) { $pythonCandidates += $pythonCommand.Source }
    $runtime = $null
    foreach ($candidate in ($pythonCandidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        & $candidate -c 'import tkinter, fitz, cv2, numpy, PIL' 2>$null
        if ($LASTEXITCODE -eq 0) { $runtime = $candidate; break }
    }
    if (-not $runtime) { throw 'Python with tkinter, PyMuPDF, OpenCV, NumPy and Pillow is required.' }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Node.js is required on PATH.' }
    $env:PYTHONUTF8 = '1'
    $env:PYTHONDONTWRITEBYTECODE = '1'
    & $runtime (Join-Path $PSScriptRoot 'desktop_gui.py')
    if ($LASTEXITCODE -ne 0) { throw 'The trial window exited unexpectedly. Run desktop_gui.py in a terminal to inspect the error.' }
} catch {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show($_.Exception.Message, 'RiffLoop PDF trial') | Out-Null
}
