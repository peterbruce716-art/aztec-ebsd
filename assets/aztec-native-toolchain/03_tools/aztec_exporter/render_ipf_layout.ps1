param(
    [Parameter(Mandatory = $true)] [string] $CprPath,
    [Parameter(Mandatory = $true)] [string] $OutputBmp,
    [string] $ReferenceBmp = '',
    [string] $AztecRoot = 'C:\Program Files\Oxford Instruments NanoAnalysis\AZtec',
    [string] $NativeIpfExe = '.\03_tools\scripts\AztecNativeIpfConsole.exe',
    [string] $KeyProbeExe = '.\03_tools\scripts\AztecNativeIpfKeyProbeNoDispose.exe',
    [int] $CanvasWidth = 2914,
    [int] $CanvasHeight = 2111,
    [int] $MapTop = 34,
    [int] $MapBottom = 36,
    [int] $MapLeft = 0,
    [int] $LegendWidth = 175,
    [ValidateSet('NearestNeighbor', 'HighQualityBicubic')]
    [string] $Interpolation = 'NearestNeighbor',
    [ValidateSet('GdiPlus', 'Floor', 'NearestCenter', 'PixelCenter', 'EndpointAligned', 'BoundaryFit', 'AxisEdgeAligned')]
    [string] $MappingMode = 'GdiPlus',
    [switch] $StretchToMapViewport
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not ('AztecBitmapMetric' -as [type])) {
    $metricSource = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public sealed class AztecMetric {
    public long Exact { get; set; }
    public long Pixels { get; set; }
    public double Mae { get; set; }
    public double Rmse { get; set; }
}

public sealed class AztecCanvasMetricSet {
    public AztecMetric Map { get; set; }
    public AztecMetric Decoration { get; set; }
    public AztecMetric Full { get; set; }
    public AztecMetric Grid { get; set; }
}

public static class AztecBitmapMetric {
    private static byte[] Bytes(Bitmap image, out int stride) {
        var rect = new Rectangle(0, 0, image.Width, image.Height);
        var data = image.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        try {
            stride = data.Stride;
            var bytes = new byte[Math.Abs(stride) * image.Height];
            Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            return bytes;
        } finally { image.UnlockBits(data); }
    }

    private static AztecMetric NewMetric() { return new AztecMetric(); }

    public static AztecCanvasMetricSet Compare(Bitmap left, Bitmap right, int mapX, int mapY,
        int mapWidth, int mapHeight, int gridWidth, int gridHeight) {
        if (left.Width != right.Width || left.Height != right.Height) throw new ArgumentException("bitmap_dimensions_mismatch");
        if (gridWidth <= 0 || gridHeight <= 0) throw new ArgumentException("invalid_grid_dimensions");
        Bitmap a = null, b = null;
        try {
            var bounds = new Rectangle(0, 0, left.Width, left.Height);
            a = left.Clone(bounds, PixelFormat.Format24bppRgb);
            b = right.Clone(bounds, PixelFormat.Format24bppRgb);
            int strideA, strideB;
            var ba = Bytes(a, out strideA);
            var bb = Bytes(b, out strideB);
            var result = new AztecCanvasMetricSet { Map = NewMetric(), Decoration = NewMetric(), Full = NewMetric(), Grid = NewMetric() };
            double fullSq = 0, mapSq = 0, decorSq = 0, gridSq = 0;
            long fullAbs = 0, mapAbs = 0, decorAbs = 0, gridAbs = 0;
            for (int y = 0; y < left.Height; y++) {
                for (int x = 0; x < left.Width; x++) {
                    int oa = y * strideA + x * 3, ob = y * strideB + x * 3;
                    bool same = true;
                    for (int c = 0; c < 3; c++) {
                        int d = ba[oa + c] - bb[ob + c];
                        if (d != 0) same = false;
                        fullAbs += Math.Abs(d); fullSq += d * d;
                        if (x >= mapX && x < mapX + mapWidth && y >= mapY && y < mapY + mapHeight) {
                            mapAbs += Math.Abs(d); mapSq += d * d;
                        } else { decorAbs += Math.Abs(d); decorSq += d * d; }
                    }
                    result.Full.Pixels++;
                    if (same) result.Full.Exact++;
                    if (x >= mapX && x < mapX + mapWidth && y >= mapY && y < mapY + mapHeight) {
                        result.Map.Pixels++; if (same) result.Map.Exact++;
                    } else { result.Decoration.Pixels++; if (same) result.Decoration.Exact++; }
                }
            }
            for (int row = 0; row < gridHeight; row++) {
                for (int column = 0; column < gridWidth; column++) {
                    int x = (int)Math.Floor(mapX + (column + 0.5) * mapWidth / gridWidth);
                    int y = (int)Math.Floor(mapY + (row + 0.5) * mapHeight / gridHeight);
                    int oa = y * strideA + x * 3, ob = y * strideB + x * 3;
                    bool same = true;
                    for (int c = 0; c < 3; c++) {
                        int d = ba[oa + c] - bb[ob + c];
                        if (d != 0) same = false;
                        gridAbs += Math.Abs(d); gridSq += d * d;
                    }
                    result.Grid.Pixels++; if (same) result.Grid.Exact++;
                }
            }
            result.Full.Mae = (double)fullAbs / (3 * result.Full.Pixels); result.Full.Rmse = Math.Sqrt(fullSq / (3 * result.Full.Pixels));
            result.Map.Mae = (double)mapAbs / (3 * result.Map.Pixels); result.Map.Rmse = Math.Sqrt(mapSq / (3 * result.Map.Pixels));
            result.Decoration.Mae = (double)decorAbs / (3 * result.Decoration.Pixels); result.Decoration.Rmse = Math.Sqrt(decorSq / (3 * result.Decoration.Pixels));
            result.Grid.Mae = (double)gridAbs / (3 * result.Grid.Pixels); result.Grid.Rmse = Math.Sqrt(gridSq / (3 * result.Grid.Pixels));
            return result;
        } finally { if (a != null) a.Dispose(); if (b != null) b.Dispose(); }
    }
}

public static class AztecPointRasterFill {
    sealed class Buffer { public byte[] Bytes; public int Stride; }

    static Buffer Read24(Bitmap source) {
        using (var normalized = new Bitmap(source.Width, source.Height, PixelFormat.Format24bppRgb))
        using (var graphics = Graphics.FromImage(normalized)) {
            graphics.DrawImageUnscaled(source, 0, 0);
            var data = normalized.LockBits(new Rectangle(0, 0, normalized.Width, normalized.Height), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            try {
                if (data.Stride <= 0) throw new ArgumentException("unsupported_source_stride:" + data.Stride);
                var bytes = new byte[data.Stride * normalized.Height];
                Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
                return new Buffer { Bytes = bytes, Stride = data.Stride };
            } finally { normalized.UnlockBits(data); }
        }
    }

    static int MapCoordinate(int pixel, int sourceSize, int destinationSize, string mode, bool vertical) {
        if (mode == "BoundaryFit" || mode == "AxisEdgeAligned") {
            long numerator = vertical ? Math.Max(0, pixel - 1) : (long)pixel + 1L;
            return Math.Min(sourceSize - 1, (int)(numerator * sourceSize / destinationSize));
        }
        if (mode == "NearestCenter" || mode == "PixelCenter")
            return Math.Min(sourceSize - 1, (int)(((2L * pixel + 1) * sourceSize) / (2L * destinationSize)));
        if (mode == "EndpointAligned") {
            if (destinationSize <= 1 || sourceSize <= 1) return 0;
            return Math.Min(sourceSize - 1, (int)((2L * pixel * (sourceSize - 1) + destinationSize - 1) / (2L * (destinationSize - 1))));
        }
        return Math.Min(sourceSize - 1, (int)((long)pixel * sourceSize / destinationSize));
    }

    public static void Fill(Bitmap sourceBitmap, Bitmap targetBitmap, int mapX, int mapY, int mapWidth, int mapHeight, string mappingMode) {
        if (mapX < 0 || mapY < 0 || mapWidth < 1 || mapHeight < 1 ||
            (long)mapX + mapWidth > targetBitmap.Width || (long)mapY + mapHeight > targetBitmap.Height)
            throw new ArgumentException("map_rectangle_out_of_bounds");
        var source = Read24(sourceBitmap);
        var targetData = targetBitmap.LockBits(new Rectangle(0, 0, targetBitmap.Width, targetBitmap.Height), ImageLockMode.ReadWrite, PixelFormat.Format24bppRgb);
        try {
            if (targetData.Stride <= 0) throw new ArgumentException("unsupported_target_stride:" + targetData.Stride);
            var target = new byte[targetData.Stride * targetBitmap.Height];
            Marshal.Copy(targetData.Scan0, target, 0, target.Length);
            for (int y = 0; y < mapHeight; y++) {
                int sourceRow = MapCoordinate(y, sourceBitmap.Height, mapHeight, mappingMode, true);
                for (int x = 0; x < mapWidth; x++) {
                    int sourceColumn = MapCoordinate(x, sourceBitmap.Width, mapWidth, mappingMode, false);
                    int from = sourceRow * source.Stride + sourceColumn * 3;
                    int to = (mapY + y) * targetData.Stride + (mapX + x) * 3;
                    target[to] = source.Bytes[from]; target[to + 1] = source.Bytes[from + 1]; target[to + 2] = source.Bytes[from + 2];
                }
            }
            Marshal.Copy(target, 0, targetData.Scan0, target.Length);
        } finally { targetBitmap.UnlockBits(targetData); }
    }
}
'@
    $drawingAssembly = [Drawing.Bitmap].Assembly.Location
    $drawingPrimitivesAssembly = [Drawing.Rectangle].Assembly.Location
    $references = @($drawingAssembly, $drawingPrimitivesAssembly) + @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -like 'System.Private.Windows.*' } | ForEach-Object Location)
    Add-Type -TypeDefinition $metricSource -ReferencedAssemblies $references
}

function Quote-ProcessArgument([string] $Value) {
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-NativeProcess([string] $Executable, [string[]] $Arguments) {
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "missing_executable:$Executable" }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [IO.Path]::GetFullPath($Executable)
    $start.Arguments = (($Arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join ' ')
    $start.WorkingDirectory = (Get-Location).Path
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw "process_start_failed:$Executable" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(180000)) { $process.Kill($true); $process.WaitForExit(); throw 'native_ipf_or_key_timeout' }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw "native_process_failed:$Executable;exit=$($process.ExitCode);stderr=$stderr;stdout=$stdout" }
    return [pscustomobject]@{ stdout = $stdout; stderr = $stderr; exit_code = $process.ExitCode }
}

function Get-Rgb([Drawing.Bitmap] $Bitmap, [int] $X, [int] $Y) {
    $c = $Bitmap.GetPixel($X, $Y)
    return @([int]$c.R, [int]$c.G, [int]$c.B)
}

$cpr = (Resolve-Path -LiteralPath $CprPath).Path
$reference = if ($ReferenceBmp) { (Resolve-Path -LiteralPath $ReferenceBmp).Path } else { $null }
$output = [IO.Path]::GetFullPath($OutputBmp)
$nativeIpf = [IO.Path]::GetFullPath($NativeIpfExe)
$keyProbe = [IO.Path]::GetFullPath($KeyProbeExe)
if ($output -eq $cpr -or $output -eq $reference) { throw 'output_must_not_replace_input' }
if (Test-Path -LiteralPath $output) { throw "refusing_existing_output:$output" }
if (-not (Test-Path -LiteralPath ($cpr -replace '\.cpr$', '.crc') -PathType Leaf)) { throw 'matching_crc_not_found' }
$outputDir = [IO.Path]::GetDirectoryName($output)
[IO.Directory]::CreateDirectory($outputDir) | Out-Null
$work = Join-Path $outputDir ([IO.Path]::GetFileNameWithoutExtension($output) + '_native_inputs')
if (Test-Path -LiteralPath $work) { throw "refusing_existing_work_directory:$work" }
[IO.Directory]::CreateDirectory($work) | Out-Null
$pointBmp = Join-Path $work 'ipf_points.bmp'
$pointJson = Join-Path $work 'ipf_points.json'
$keyDir = Join-Path $work 'keys'
$keyJson = Join-Path $keyDir 'keys.json'
$nativeRun = Invoke-NativeProcess $nativeIpf @($AztecRoot, $cpr, $pointBmp, $pointJson)
$keyRun = Invoke-NativeProcess $keyProbe @($AztecRoot, $cpr, $keyJson, $keyDir)
$pointReport = Get-Content -Raw -Encoding UTF8 -LiteralPath $pointJson | ConvertFrom-Json
$keyReport = Get-Content -Raw -Encoding UTF8 -LiteralPath $keyJson | ConvertFrom-Json
if ($pointReport.status -ne 'ok' -or $keyReport.status -ne 'native_ipf_key_read') { throw 'native_input_generation_failed' }
if ($pointReport.source_cpr_sha256 -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $cpr).Hash) { throw 'cpr_hash_mismatch' }

$mapWidth = $CanvasWidth - $LegendWidth
$mapHeight = $CanvasHeight - $MapTop - $MapBottom
$aspect = ($pointReport.width * $keyReport.step_x_micron) / ($pointReport.height * $keyReport.step_y_micron)
if ($aspect -le 0 -or $mapWidth -le 0 -or $mapHeight -le 0) { throw 'invalid_map_geometry' }
if ($StretchToMapViewport) {
    if ($MapLeft -lt 0 -or $MapLeft -ge $mapWidth) { throw 'map_left_out_of_bounds' }
    $contentWidth = $mapWidth - $MapLeft
    $contentHeight = $mapHeight
    $contentX = $MapLeft
    $contentY = $MapTop
} else {
    if ($aspect -lt ($mapWidth / $mapHeight)) {
        $contentWidth = [math]::Max(1, [int][math]::Round($mapHeight * $aspect))
        $contentHeight = $mapHeight
    } else {
        $contentWidth = $mapWidth
        $contentHeight = [math]::Max(1, [int][math]::Round($mapWidth / $aspect))
    }
    $contentX = [int][math]::Floor(($mapWidth - $contentWidth) / 2)
    $contentY = $MapTop + [int][math]::Floor(($mapHeight - $contentHeight) / 2)
}
$panelX = $mapWidth
$canvas = [Drawing.Bitmap]::new($CanvasWidth, $CanvasHeight, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
$graphics = [Drawing.Graphics]::FromImage($canvas)
$points = $null
$referenceImage = $null
$brush = $null
$pen = $null
$headerFont = $null
$bodyFont = $null
$smallFont = $null
try {
    $graphics.Clear([Drawing.Color]::White)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::None
    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::$Interpolation
    $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
    $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
    $points = [Drawing.Bitmap]::new($pointBmp)
    if ($MappingMode -eq 'GdiPlus') {
        $destination = [Drawing.Rectangle]::new($contentX, $contentY, $contentWidth, $contentHeight)
        $graphics.DrawImage($points, $destination, [Drawing.Rectangle]::new(0, 0, $points.Width, $points.Height), [Drawing.GraphicsUnit]::Pixel)
    } else {
        [AztecPointRasterFill]::Fill($points, $canvas, $contentX, $contentY, $contentWidth, $contentHeight, $MappingMode)
    }
    $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceOver
    $brush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(30, 30, 30))
    $pen = [Drawing.Pen]::new([Drawing.Color]::FromArgb(120, 120, 120), 1)
    $headerFont = [Drawing.Font]::new('Segoe UI', 9, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    $bodyFont = [Drawing.Font]::new('Segoe UI', 9, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    $smallFont = [Drawing.Font]::new('Segoe UI', 7, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)

    $graphics.DrawLine($pen, 0, $MapTop - 1, $CanvasWidth - 1, $MapTop - 1)
    $graphics.DrawLine($pen, $panelX, 0, $panelX, $CanvasHeight - $MapBottom - 1)
    $graphics.DrawLine($pen, 0, $CanvasHeight - $MapBottom, $CanvasWidth - 1, $CanvasHeight - $MapBottom)
    $header = 'IPF'
    $headerSize = $graphics.MeasureString($header, $headerFont)
    $graphics.DrawString($header, $headerFont, $brush, [single](($mapWidth - $headerSize.Width) / 2), 10)

    $legendTitle = 'IPF Coloring || Z0'
    $titleSize = $graphics.MeasureString($legendTitle, $bodyFont)
    $graphics.DrawString($legendTitle, $bodyFont, $brush, [single]($panelX + ($LegendWidth - $titleSize.Width) / 2), 3)
    $phaseCount = $keyReport.phases.Count
    $legendTop = $MapTop + 10
    $legendHeight = $CanvasHeight - $MapBottom - $legendTop
    $entryHeight = [single]($legendHeight / [math]::Max(1, $phaseCount))
    foreach ($phase in $keyReport.phases) {
        $entryTop = $legendTop + [single](($phase.phase_id - 1) * $entryHeight)
        $name = [string]$phase.name
        $nameSize = $graphics.MeasureString($name, $smallFont)
        $graphics.DrawString($name, $smallFont, $brush, [single]($panelX + ($LegendWidth - $nameSize.Width) / 2), $entryTop)
        $keyBitmap = [Drawing.Bitmap]::new([string]$phase.bmp_path)
        try {
            $maxKeyHeight = [single][math]::Min(58, $entryHeight * 0.48)
            $keyScale = $maxKeyHeight / $keyBitmap.Height
            $keyDrawWidth = [single]($keyBitmap.Width * $keyScale)
            $keyDrawHeight = [single]($keyBitmap.Height * $keyScale)
            if ($keyDrawWidth -gt ($LegendWidth - 10)) {
                $keyScale = ($LegendWidth - 10) / $keyBitmap.Width
                $keyDrawWidth = [single]($keyBitmap.Width * $keyScale)
                $keyDrawHeight = [single]($keyBitmap.Height * $keyScale)
            }
            $keyLeft = [single]($panelX + ($LegendWidth - $keyDrawWidth) / 2)
            $keyTop = $entryTop + 12
            $graphics.DrawImage($keyBitmap, [Drawing.RectangleF]::new($keyLeft, $keyTop, $keyDrawWidth, $keyDrawHeight))
            foreach ($polygon in $phase.outline_polygons) {
                $poly = [Drawing.PointF[]]@($polygon | ForEach-Object {
                    [Drawing.PointF]::new($keyLeft + [single]($_[0] * $keyScale), $keyTop + [single]($_[1] * $keyScale))
                })
                if ($poly.Length -gt 2) { $graphics.DrawPolygon($pen, $poly) }
            }
            foreach ($annotation in $phase.annotations) {
                $position = ([string]$annotation.Position2D).Split(',')
                if ($position.Count -ne 2) { continue }
                $ax = $keyLeft + [single]([double]::Parse($position[0], [Globalization.CultureInfo]::InvariantCulture) * $keyScale)
                $ay = $keyTop + [single]([double]::Parse($position[1], [Globalization.CultureInfo]::InvariantCulture) * $keyScale)
                $textSize = $graphics.MeasureString([string]$annotation.Text, $smallFont)
                switch ([string]$annotation.Offset) {
                    'Top' { $ax -= $textSize.Width / 2; $ay -= $textSize.Height }
                    'Bottom' { $ax -= $textSize.Width / 2 }
                    'BottomRight' { }
                    default { $ax -= $textSize.Width / 2; $ay -= $textSize.Height / 2 }
                }
                $graphics.DrawString([string]$annotation.Text, $smallFont, $brush, $ax, $ay)
            }
        } finally { $keyBitmap.Dispose() }
        $graphics.DrawLine($pen, $panelX + 7, [single]($entryTop + $entryHeight - 2), $CanvasWidth - 7, [single]($entryTop + $entryHeight - 2))
    }
    $footer = 'Map: ' + $pointReport.width + 'x' + $pointReport.height + '    Step size: ' + $keyReport.step_x_micron + ' µm'
    $graphics.DrawString($footer, $smallFont, $brush, 6, [single]($CanvasHeight - $MapBottom + 7))
    $graphics.Flush()
    $canvas.Save($output, [Drawing.Imaging.ImageFormat]::Bmp)

    $metrics = $null
    if ($reference) {
        $referenceImage = [Drawing.Bitmap]::new($reference)
        if ($referenceImage.Width -ne $CanvasWidth -or $referenceImage.Height -ne $CanvasHeight) { throw 'reference_canvas_size_mismatch' }
        $metrics = [AztecBitmapMetric]::Compare($canvas, $referenceImage, $contentX, $contentY, $contentWidth, $contentHeight, $points.Width, $points.Height)
    }
    $reportPath = [IO.Path]::ChangeExtension($output, '.json')
    $report = [ordered]@{
        status = 'independent_aztec_ipf_canvas_created'
        cpr = $cpr
        cpr_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $cpr).Hash
        crc_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath ($cpr -replace '\.cpr$', '.crc')).Hash
        output_bmp = $output
        output_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $output).Hash
        reference_bmp = $reference
        reference_sha256 = if ($reference) { (Get-FileHash -Algorithm SHA256 -LiteralPath $reference).Hash } else { $null }
        grid = [ordered]@{ width = $pointReport.width; height = $pointReport.height; step_x_micron = $keyReport.step_x_micron; step_y_micron = $keyReport.step_y_micron }
        canvas = [ordered]@{ width = $CanvasWidth; height = $CanvasHeight; map_rect = @{ x = $contentX; y = $contentY; width = $contentWidth; height = $contentHeight }; legend_width = $LegendWidth; phase_count = $phaseCount }
        ipf_color_source = 'AZtec Core.Ebsd.Calculations.IPFColorCoding.GetColor; unchanged native point BMP'
        legend_source = 'AZtec Core.Ebsd.Calculations.IPFColorKey.Pixels, Outline2D, Annotations2D'
        interpolation = $Interpolation
        mapping_mode = $MappingMode
        pixel_to_grid = switch ($MappingMode) {
            'GdiPlus' { 'GDI+ DrawImage with the selected interpolation mode' }
            'Floor' { 'floor(destinationIndex*sourceSize/destinationSize)' }
            'NearestCenter' { 'floor((2*destinationIndex+1)*sourceSize/(2*destinationSize))' }
            'PixelCenter' { 'floor((destinationIndex+0.5)*sourceSize/destinationSize)' }
            'EndpointAligned' { 'round(destinationIndex*(sourceSize-1)/(destinationSize-1)); ties upward' }
            'BoundaryFit' { 'X=floor((destinationIndex+1)*sourceSize/destinationSize); Y=floor(max(destinationIndex-1,0)*sourceSize/destinationSize)' }
            'AxisEdgeAligned' { 'X=floor((destinationIndex+1)*sourceSize/destinationSize); Y=floor(max(destinationIndex-1,0)*sourceSize/destinationSize)' }
        }
        geometry_mode = if ($StretchToMapViewport) { 'stretch_to_map_viewport' } else { 'fit_physical_aspect' }
        gui_started = $false
        mtex_used = $false
        pillow_used = $false
        same_cpr_map_body = if ($metrics) { [ordered]@{ pixels_exact=$metrics.Map.Exact; pixels=$metrics.Map.Pixels; exact_fraction=($metrics.Map.Exact/[double]$metrics.Map.Pixels); rgb_mae=$metrics.Map.Mae; rgb_rmse=$metrics.Map.Rmse } } else { $null }
        comparison_status = if ($reference) { 'measured' } else { 'not_requested_no_reference_dependency' }
    }
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($true))
    $report | ConvertTo-Json -Depth 5
}
finally {
    if ($null -ne $referenceImage) { $referenceImage.Dispose() }
    if ($null -ne $points) { $points.Dispose() }
    if ($null -ne $graphics) { $graphics.Dispose() }
    if ($null -ne $canvas) { $canvas.Dispose() }
    foreach ($resource in @($brush, $pen, $headerFont, $bodyFont, $smallFont)) { if ($null -ne $resource) { $resource.Dispose() } }
}
