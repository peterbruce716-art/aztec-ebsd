param([Parameter(Mandatory=$true)][string]$InputPath,[Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$api=(Resolve-Path (Join-Path $PSScriptRoot '../aztec_exporter/AZtecBmpExporter.dll')).Path
Add-Type -Path $api
Add-Type -ReferencedAssemblies $api -TypeDefinition @'
public static class NativeDllVerification {
 public static AZtecBmpExporter.ExportResult Run(string input, string output) {
  return AZtecBmpExporter.AZtecBmpApi.Export(input, output, "ALL");
 }
}
'@
$result=[NativeDllVerification]::Run((Resolve-Path -LiteralPath $InputPath).Path,[IO.Path]::GetFullPath($OutputDirectory))
if($result.ExitCode -ne 0 -or $result.Status -ne 'completed' -or $result.ImageStatuses.Count -ne 3){throw 'dll_native_export_failed'}
$rejected=$false
try{[NativeDllVerification]::Run((Resolve-Path -LiteralPath $InputPath).Path,[IO.Path]::GetFullPath($OutputDirectory))|Out-Null}catch{if($_.Exception.ToString().Contains('output_path_must_be_new')){$rejected=$true}else{throw}}
if(-not $rejected){throw 'dll_existing_output_not_rejected'}
$report=@{exit_code=$result.ExitCode;status=$result.Status;validation_level=$result.ValidationLevel;image_statuses=$result.ImageStatuses;image_paths=$result.ImagePaths;existing_output_rejected=$rejected;api_sha256=(Get-FileHash -LiteralPath $api).Hash}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'dll_verification.json'),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
$report|ConvertTo-Json -Depth 5
