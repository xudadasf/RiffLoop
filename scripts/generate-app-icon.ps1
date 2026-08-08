Add-Type -AssemblyName System.Drawing

$outputPath = Join-Path $PSScriptRoot '..\RiffLoop\Assets.xcassets\AppIcon.appiconset\AppIcon.png'
$bitmap = New-Object System.Drawing.Bitmap 1024, 1024, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

try {
    $bounds = New-Object System.Drawing.Rectangle 0, 0, 1024, 1024
    $background = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $bounds,
        [System.Drawing.Color]::FromArgb(8, 12, 22),
        [System.Drawing.Color]::FromArgb(20, 42, 65),
        45
    )
    $graphics.FillRectangle($background, $bounds)

    $loopPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(39, 216, 187)), 72
    $loopPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $loopPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawArc($loopPen, 190, 190, 644, 644, -65, 292)

    $arrowBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(39, 216, 187))
    $arrow = [System.Drawing.Point[]]@(
        (New-Object System.Drawing.Point 206, 338),
        (New-Object System.Drawing.Point 112, 343),
        (New-Object System.Drawing.Point 178, 431)
    )
    $graphics.FillPolygon($arrowBrush, $arrow)

    $beatBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(246, 248, 252))
    $accentBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 153, 60))
    $graphics.FillRectangle($accentBrush, 352, 385, 70, 254)
    $graphics.FillRectangle($beatBrush, 452, 443, 70, 196)
    $graphics.FillRectangle($beatBrush, 552, 413, 70, 226)
    $graphics.FillRectangle($beatBrush, 652, 472, 70, 167)

    $bitmap.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
    $graphics.Dispose()
    $bitmap.Dispose()
    if ($background) { $background.Dispose() }
    if ($loopPen) { $loopPen.Dispose() }
    if ($arrowBrush) { $arrowBrush.Dispose() }
    if ($beatBrush) { $beatBrush.Dispose() }
    if ($accentBrush) { $accentBrush.Dispose() }
}

Write-Output $outputPath
