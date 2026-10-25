param([switch]$IncludeDll)
$ErrorActionPreference='Stop'
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$source=Join-Path $PSScriptRoot 'AZtecBmpExporter.cs'
$output=Join-Path $PSScriptRoot 'AZtecBmpExporter.exe'
& $compiler /nologo /target:exe /platform:x64 /reference:System.Web.Extensions.dll "/out:$output" $source
if($LASTEXITCODE -ne 0){throw 'build_failed:AZtecBmpExporter'}
if($IncludeDll){
    $apiSource=Join-Path $PSScriptRoot 'AZtecBmpApi.cs'
    $apiOutput=Join-Path $PSScriptRoot 'AZtecBmpExporter.dll'
    & $compiler /nologo /target:library /platform:x64 /reference:System.Web.Extensions.dll "/out:$apiOutput" $apiSource
    if($LASTEXITCODE -ne 0){throw 'build_failed:AZtecBmpApi'}
}
