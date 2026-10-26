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
$frameworkRoot=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319'
$wpfRoot=Join-Path $frameworkRoot 'WPF'
$automation=@(Get-ChildItem -LiteralPath (Join-Path $env:WINDIR 'Microsoft.Net/assembly/GAC_MSIL/System.Management.Automation') -Recurse -File -Filter 'System.Management.Automation.dll' -ErrorAction SilentlyContinue | Select-Object -First 1)
if($automation.Count -ne 1){throw 'framework_automation_assembly_missing'}
$refs=@($automation[0].FullName,(Join-Path $wpfRoot 'PresentationFramework.dll'),(Join-Path $wpfRoot 'PresentationCore.dll'),(Join-Path $wpfRoot 'WindowsBase.dll'),(Join-Path $frameworkRoot 'System.Xaml.dll'))
foreach($ref in $refs){if(-not [IO.File]::Exists($ref)){throw ('framework_reference_missing:'+ $ref)}}
$worker=Join-Path $PSScriptRoot 'StaFullMapWorker.exe'
& $compiler /nologo /target:exe /platform:x64 $( $refs | ForEach-Object { '/reference:' + $_ } ) "/out:$worker" (Join-Path $PSScriptRoot 'StaFullMapWorker.cs')
if($LASTEXITCODE -ne 0){throw 'build_failed:StaFullMapWorker'}
