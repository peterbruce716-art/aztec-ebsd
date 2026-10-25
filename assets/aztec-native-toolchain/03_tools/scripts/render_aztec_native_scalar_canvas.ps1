param(
    [Parameter(Mandatory = $true)] [ValidateSet('KAM', 'GOS')] [string] $Metric,
    [Parameter(Mandatory = $true)] [string] $PointBmp,
    [Parameter(Mandatory = $true)] [string] $OutputBmp,
    [Parameter(Mandatory = $true)] [double] $DisplayMin,
    [Parameter(Mandatory = $true)] [double] $DisplayMax,
    [string] $AztecRoot = 'C:\Program Files\Oxford Instruments NanoAnalysis\AZtec',
    [int] $CanvasWidth = 2914,
    [int] $CanvasHeight = 2111,
    [int] $MapX = 1,
    [int] $MapY = 34,
    [int] $MapWidth = 2733,
    [int] $MapHeight = 2041,
    [ValidateSet('Floor', 'NearestCenter', 'PixelCenter', 'EndpointAligned', 'BoundaryFit', 'AxisEdgeAligned')]
    [string] $MappingMode = 'Floor'
)

$ErrorActionPreference = 'Stop'
if ($DisplayMax -le $DisplayMin) { throw 'display_range_must_be_positive' }
if ($CanvasWidth -lt 1 -or $CanvasHeight -lt 1 -or $MapX -lt 0 -or $MapY -lt 0 -or $MapWidth -lt 1 -or $MapHeight -lt 1 -or
    ([long]$MapX + $MapWidth) -gt $CanvasWidth -or ([long]$MapY + $MapHeight) -gt $CanvasHeight) {
    throw 'map_rect_out_of_bounds'
}
$pointPath = (Resolve-Path -LiteralPath $PointBmp).Path
$outputPath = [IO.Path]::GetFullPath($OutputBmp)
$reportPath = [IO.Path]::ChangeExtension($outputPath, '.json')
if ([IO.File]::Exists($outputPath) -or [IO.File]::Exists($reportPath)) { throw 'refusing_existing_output' }
if (-not (Test-Path -LiteralPath (Join-Path $AztecRoot 'core.ebsd.dll') -PathType Leaf)) { throw "aztec_core_missing:$AztecRoot" }
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputPath)) | Out-Null

Set-Location -LiteralPath $AztecRoot
Get-ChildItem -LiteralPath $AztecRoot -Filter '*.dll' -File | ForEach-Object {
    try { [Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch { }
}
[Reflection.Assembly]::LoadFrom((Join-Path $AztecRoot 'core.ebsd.dll')) | Out-Null
Add-Type -AssemblyName System.Drawing

if (-not ('AztecIndependentScalarCanvas' -as [type])) {
    $source = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class AztecIndependentScalarCanvas {
    sealed class Buffer { public byte[] Bytes; public int Stride; public int Width; public int Height; }

    static Buffer Read24(Bitmap source) {
        using (var normalized = new Bitmap(source.Width, source.Height, PixelFormat.Format24bppRgb))
        using (var graphics = Graphics.FromImage(normalized)) {
            graphics.DrawImageUnscaled(source, 0, 0);
            var data = normalized.LockBits(new Rectangle(0, 0, normalized.Width, normalized.Height), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            try {
                if (data.Stride <= 0) throw new ArgumentException("unsupported_bitmap_stride:" + data.Stride);
                var bytes = new byte[data.Stride * normalized.Height];
                Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
                return new Buffer { Bytes = bytes, Stride = data.Stride, Width = normalized.Width, Height = normalized.Height };
            } finally { normalized.UnlockBits(data); }
        }
    }

    static int MapCoordinate(int destinationIndex, int sourceSize, int destinationSize, string mode, bool vertical) {
        if (mode == "BoundaryFit" || mode == "AxisEdgeAligned") {
            // Horizontal pixels use their right edge; top-down rows use their upper edge.
            long numerator = vertical ? Math.Max(0, destinationIndex - 1) : (long)destinationIndex + 1L;
            return Math.Min(sourceSize - 1, (int)(numerator * sourceSize / destinationSize));
        }
        if (mode == "NearestCenter") {
            return Math.Min(sourceSize - 1, (int)(((2L * destinationIndex + 1) * sourceSize) / (2L * destinationSize)));
        }
        if (mode == "PixelCenter")
            return Math.Min(sourceSize - 1, (int)(((2L * destinationIndex + 1) * sourceSize) / (2L * destinationSize)));
        if (mode == "EndpointAligned") {
            if (destinationSize <= 1 || sourceSize <= 1) return 0;
            return Math.Min(sourceSize - 1, (int)((2L * destinationIndex * (sourceSize - 1) + destinationSize - 1) / (2L * (destinationSize - 1))));
        }
        return Math.Min(sourceSize - 1, (int)((long)destinationIndex * sourceSize / destinationSize));
    }

    static void FillGrid(Bitmap canvas, Bitmap points, int mapX, int mapY, int mapWidth, int mapHeight, string mappingMode) {
        var source = Read24(points);
        var targetData = canvas.LockBits(new Rectangle(0, 0, canvas.Width, canvas.Height), ImageLockMode.ReadWrite, PixelFormat.Format24bppRgb);
        try {
            if (targetData.Stride <= 0) throw new ArgumentException("unsupported_canvas_stride:" + targetData.Stride);
            var target = new byte[targetData.Stride * canvas.Height];
            Marshal.Copy(targetData.Scan0, target, 0, target.Length);
            for (int y = 0; y < mapHeight; y++) {
                int row = MapCoordinate(y, source.Height, mapHeight, mappingMode, true);
                for (int x = 0; x < mapWidth; x++) {
                    int column = MapCoordinate(x, source.Width, mapWidth, mappingMode, false);
                    int from = row * source.Stride + column * 3;
                    int to = (mapY + y) * targetData.Stride + (mapX + x) * 3;
                    target[to] = source.Bytes[from];
                    target[to + 1] = source.Bytes[from + 1];
                    target[to + 2] = source.Bytes[from + 2];
                }
            }
            Marshal.Copy(target, 0, targetData.Scan0, target.Length);
        } finally { canvas.UnlockBits(targetData); }
    }

    public static void Render(Bitmap points, Bitmap canvas, int mapX, int mapY, int mapWidth, int mapHeight, string mappingMode,
        Bitmap scale, string title, string rangeLabel, double displayMin, double displayMax) {
        FillGrid(canvas, points, mapX, mapY, mapWidth, mapHeight, mappingMode);
        using (var graphics = Graphics.FromImage(canvas))
        using (var textBrush = new SolidBrush(Color.FromArgb(35, 45, 55)))
        using (var linePen = new Pen(Color.FromArgb(185, 190, 194), 1))
        using (var headerFont = new Font("Segoe UI", 13, FontStyle.Bold, GraphicsUnit.Pixel))
        using (var labelFont = new Font("Segoe UI", 10, FontStyle.Regular, GraphicsUnit.Pixel))
        using (var smallFont = new Font("Segoe UI", 9, FontStyle.Regular, GraphicsUnit.Pixel)) {
            graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.None;
            graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
            graphics.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.Half;
            graphics.DrawString(title, headerFont, textBrush, 14, 7);
            graphics.DrawLine(linePen, 12, 30, canvas.Width - 12, 30);
            int panelX = mapX + mapWidth + 24;
            graphics.DrawString("AZtec HeatMap", labelFont, textBrush, panelX, mapY + 2);
            int scaleX = panelX;
            int scaleY = mapY + 27;
            int scaleHeight = Math.Min(780, mapHeight - 60);
            int scaleWidth = 24;
            graphics.DrawImage(scale, new Rectangle(scaleX, scaleY, scaleWidth, scaleHeight));
            graphics.DrawRectangle(linePen, scaleX, scaleY, scaleWidth - 1, scaleHeight - 1);
            graphics.DrawString(displayMax.ToString("0.##") + "°", smallFont, textBrush, scaleX + 32, scaleY - 2);
            graphics.DrawString(displayMin.ToString("0.##") + "°", smallFont, textBrush, scaleX + 32, scaleY + scaleHeight - 12);
            graphics.DrawString(rangeLabel, smallFont, textBrush, panelX, scaleY + scaleHeight + 12);
            graphics.DrawLine(linePen, 12, canvas.Height - 27, canvas.Width - 12, canvas.Height - 27);
            graphics.DrawString(points.Width + " x " + points.Height + " EBSD points", smallFont, textBrush, 14, canvas.Height - 21);
        }
    }
}
'@
    $drawingReferences = [Collections.Generic.List[string]]::new()
    $drawingReferences.Add([Drawing.Bitmap].Assembly.Location)
    $drawingReferences.Add([Drawing.Rectangle].Assembly.Location)
    foreach ($assemblyPath in @([AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -like 'System.Private.Windows.*' } |
        ForEach-Object Location)) {
        if (-not $drawingReferences.Contains($assemblyPath)) { $drawingReferences.Add($assemblyPath) }
    }
    Add-Type -TypeDefinition $source -ReferencedAssemblies ([string[]]$drawingReferences.ToArray())
}

$points = $null
$canvas = $null
$scaleBitmap = $null
try {
    $points = [Drawing.Bitmap]::new($pointPath)
    $canvas = [Drawing.Bitmap]::new($CanvasWidth, $CanvasHeight, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [Drawing.Graphics]::FromImage($canvas)
    try { $graphics.Clear([Drawing.Color]::White) } finally { $graphics.Dispose() }
    $scaleBitmap = [Drawing.Bitmap]::new(1, 512, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $scaleType = [Enum]::Parse([Core.Ebsd.ImageProcessing.ColorScaleType], 'HeatMap', $true)
    for ($y = 0; $y -lt $scaleBitmap.Height; $y++) {
        $fraction = 1.0 - ($y / [double]($scaleBitmap.Height - 1))
        $value = $DisplayMin + $fraction * ($DisplayMax - $DisplayMin)
        $color = [Core.Ebsd.ImageProcessing.ColorCoding]::GetColorFromScale($value, $DisplayMin, $DisplayMax, $scaleType, $false, $true, 5)
        $scaleBitmap.SetPixel(0, $y, [Drawing.Color]::FromArgb([int]$color.R, [int]$color.G, [int]$color.B))
    }
    [AztecIndependentScalarCanvas]::Render($points, $canvas, $MapX, $MapY, $MapWidth, $MapHeight, $MappingMode,
        $scaleBitmap, ($Metric + ' | ' + $points.Width + ' x ' + $points.Height), 'degrees', $DisplayMin, $DisplayMax)
    $canvas.Save($outputPath, [Drawing.Imaging.ImageFormat]::Bmp)
    $bytes = [IO.File]::ReadAllBytes($outputPath)
    if ($bytes.Length -lt 54 -or $bytes[0] -ne 0x42 -or $bytes[1] -ne 0x4D) { throw 'bmp_signature_invalid' }
    $report = [ordered]@{
        status = 'independent_native_scalar_canvas_created'
        metric = $Metric
        source_point_bmp = $pointPath
        source_point_bmp_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $pointPath).Hash
        output_bmp = $outputPath
        output_bmp_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $outputPath).Hash
        canvas_size = @($CanvasWidth, $CanvasHeight)
        grid_size = @($points.Width, $points.Height)
        map_rect = @{ x = $MapX; y = $MapY; width = $MapWidth; height = $MapHeight }
        mapping_mode = $MappingMode
        pixel_to_grid = switch ($MappingMode) {
            'Floor' { 'floor(destinationIndex*sourceSize/destinationSize)' }
            'NearestCenter' { 'nearest continuous source grid-point center to destination pixel center; exact rational mapping, ties toward higher index' }
            'PixelCenter' { 'floor((destinationIndex+0.5)*sourceSize/destinationSize)' }
            'EndpointAligned' { 'round(destinationIndex*(sourceSize-1)/(destinationSize-1)); ties upward' }
            'BoundaryFit' { 'X=floor((destinationIndex+1)*sourceSize/destinationSize); Y=floor(max(destinationIndex-1,0)*sourceSize/destinationSize); legacy reference-fit name; ties/clamp at source bounds' }
            'AxisEdgeAligned' { 'X=floor((destinationIndex+1)*sourceSize/destinationSize); Y=floor(max(destinationIndex-1,0)*sourceSize/destinationSize); horizontal right-edge and top-down upper-edge convention; ties/clamp at source bounds' }
        }
        display_min = $DisplayMin
        display_max = $DisplayMax
        scale_source = 'AZtec Core.Ebsd.ImageProcessing.ColorCoding.GetColorFromScale(HeatMap)'
        canvas_background = 'white; created from blank bitmap'
        reference_pixels_used = $false
        boundary_overlay = $false
        gui_started = $false
        mtex_used = $false
        pillow_used = $false
        renderer_classification = 'native point/scalar colors with independent compatible canvas; not AZtec native full-map rendering'
    }
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($true))
    $report | ConvertTo-Json -Depth 6
}
finally {
    if ($null -ne $scaleBitmap) { $scaleBitmap.Dispose() }
    if ($null -ne $points) { $points.Dispose() }
    if ($null -ne $canvas) { $canvas.Dispose() }
}
