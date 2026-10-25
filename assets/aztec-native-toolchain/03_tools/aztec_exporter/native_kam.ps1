param([string]$CprPath,[string]$OutputDirectory,[string]$AztecRoot)
$ErrorActionPreference='Stop'
[IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null
$scripts=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../scripts'))
$csv=Join-Path $OutputDirectory 'values.csv'
$summary=Join-Path $OutputDirectory 'values.json'
$points=Join-Path $OutputDirectory 'native_pixels.bmp'
$colors=Join-Path $OutputDirectory 'colors.json'
Set-Location -LiteralPath $AztecRoot
Get-ChildItem -LiteralPath $AztecRoot -Filter '*.dll' -File|ForEach-Object {try{[Reflection.Assembly]::LoadFrom($_.FullName)|Out-Null}catch{}}
[Reflection.Assembly]::LoadFrom((Join-Path $AztecRoot 'core.ebsd.dll'))|Out-Null
$limits=Get-Content -LiteralPath $colors -Encoding UTF8 -Raw|ConvertFrom-Json
Add-Type -AssemblyName System.Drawing
$project=[Core.Ebsd.Infrastructure.Project]::new($CprPath)
$bitmap=$null
try {
    $d=$project.Datasets[0];if(-not $d.IsPopulated){$d.PopulateData()}
    $phases=$d.PhaseID.Items
    $bitmap=[Drawing.Bitmap]::new($points)
    $minimum=[Core.Ebsd.ImageProcessing.ColorCoding]::GetColorFromScale($limits.display_min,$limits.display_min,$limits.display_max,[Core.Ebsd.ImageProcessing.ColorScaleType]::HeatMap,$false,$true,5)
    $c=[Drawing.Color]::FromArgb($minimum.R,$minimum.G,$minimum.B)
    $count=0;$recolored=0;$phase0=0
    $reader=[IO.StreamReader]::new($csv,$true)
    try {
        $null=$reader.ReadLine()
        while($null -ne ($line=$reader.ReadLine())){
            $f=$line.Split(',');$i=[int]$f[0]
            if($i -ne $count){throw 'kam_noncontiguous_indices'}
            if([int]$phases[$i] -gt 0 -and $f[2] -eq 'false'){$bitmap.SetPixel(($i % $bitmap.Width),[int][math]::Floor($i/$bitmap.Width),$c);$recolored++}
            if([int]$phases[$i] -eq 0){$phase0++}
            $count++
        }
    }finally{$reader.Dispose()}
    if($count -ne $d.PixelCount -or $bitmap.Width*$bitmap.Height -ne $count){throw 'kam_coverage_mismatch'}
    $bitmap.Save((Join-Path $OutputDirectory 'points.bmp'),[Drawing.Imaging.ImageFormat]::Bmp)
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'display_mask.json'),(@{status='verified_rule_applied';points=$count;phase0=$phase0;indexed_invalid_to_minimum=$recolored;numeric_validity_unchanged=$true;source='native Dataset.PhaseID and native KAM GetValue tuple.Valid';rule='indexed invalid -> native HeatMap minimum; Phase0 stays white';range_policy='observed valid native KAM max rounded upward to 0.01 degree; compatibility display policy, not saved-map Automatic'}|ConvertTo-Json),[Text.UTF8Encoding]::new($true))
}finally{
    # Match the verified NoDispose isolation path: this short-lived process owns
    # all vendor objects and the OS reclaims them at process exit.
    $bitmap=$null;$project=$null
}
