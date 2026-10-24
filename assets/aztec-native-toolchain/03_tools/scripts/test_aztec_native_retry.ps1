param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if(-not $OutputDirectory){$OutputDirectory=Join-Path ([IO.Path]::GetTempPath()) ('aztec-ebsd-native-retry_'+[Guid]::NewGuid().ToString('N'))}
$testRoot=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $testRoot){throw 'test_output_must_be_new'}
[IO.Directory]::CreateDirectory($testRoot)|Out-Null
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root '03_tools/aztec_exporter/export.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'production_script_parse_failed'}
$fn=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'NativeMapWithRetry'},$true)
if($null -eq $fn){throw 'retry_function_missing'}
Invoke-Expression $fn.Extent.Text
function Assert($condition,[string]$message){if(-not $condition){throw $message}}
function Start-Sleep {param([int]$Milliseconds)}
function Native([string]$Name,[string]$Script,[hashtable]$Parameters){
    $script:calls++
    if($script:scenario -eq 'caught_bitmap' -and $script:calls -eq 2){return}
    [IO.Directory]::CreateDirectory($Parameters.OutputDirectory)|Out-Null
    $worker=@{status='failed';stage='native_map_bitmap';error='System.TypeInitializationException: WriteableBitmap initialization failed'}
    switch($script:scenario){
        'nontransient' {$worker.error='native_scalar_values_not_ready';$worker.stage='populate_native_layers'}
        'sta' {$worker.error='native_map_requires_Windows_PowerShell_Framework_STA_child_process; WriteableBitmap'}
        'input_changed' {$worker.status='input_changed'}
        'pixel_mismatch' {$worker.stage='verify_saved_native_pixels';$worker.error='saved_bitmap_disagrees_with_native_pixels; WriteableBitmap'}
        'damaged_report' {$worker.error='unused'}
    }
    $prefix=Join-Path $out ('work/'+$Name)
    [IO.File]::WriteAllText(($prefix+'.stderr.log'),'')
    [IO.File]::WriteAllText(($prefix+'.stdout.log'),$(if($script:scenario -eq 'stdout_bitmap'){$worker|ConvertTo-Json -Compress}else{''}))
    if($script:scenario -eq 'damaged_report'){
        [IO.File]::WriteAllText((Join-Path $Parameters.OutputDirectory 'report.json'),'{invalid json')
    }elseif($script:scenario -ne 'stdout_bitmap'){
        [IO.File]::WriteAllText((Join-Path $Parameters.OutputDirectory 'report.json'),($worker|ConvertTo-Json -Compress))
    }
    throw ('stage_failed:'+ $Name+';exit=1;original_mock_failure')
}
$results=[Collections.Generic.List[object]]::new()
foreach($case in 'caught_bitmap','nontransient','max_three','damaged_report','stdout_bitmap','sta','input_changed','pixel_mismatch'){
    $script:scenario=$case;$script:calls=0
    $out=Join-Path $testRoot $case
    [IO.Directory]::CreateDirectory((Join-Path $out 'work'))|Out-Null
    $caught=$null;$result=$null
    try{$result=NativeMapWithRetry 'native_map_KAM' 'unused' @{OutputDirectory=(Join-Path $out 'work/native_KAM')}}catch{$caught=$_.Exception.Message}
    try{
        if($case -eq 'caught_bitmap'){
            Assert ($null -eq $caught) ('expected recovery: '+$caught)
            Assert ($script:calls -eq 2 -and $result.Attempts -eq 2) 'expected second-attempt success'
            Assert ($result.OutputDirectory.EndsWith('native_KAM_retry2')) 'expected fresh retry directory'
            Assert ($result.AttemptLog[0].stage -eq 'native_map_bitmap' -and $result.AttemptLog[0].raw_error -match 'WriteableBitmap') 'missing worker failure evidence'
        }else{
            Assert ($caught -like 'native_map_attempt_failed:*') ('original stage failure masked: '+$caught)
            $log=@($caught.Substring('native_map_attempt_failed:'.Length)|ConvertFrom-Json)
            $expected=if($case -in 'max_three','stdout_bitmap'){3}else{1}
            Assert ($script:calls -eq $expected -and $log.Count -eq $expected) ('unexpected attempt count: '+$script:calls)
            Assert ($log[0].error -match 'original_mock_failure') 'original invocation error lost'
            if($case -eq 'damaged_report'){Assert ($log[0].diagnostic_errors.Count -gt 0) 'missing damaged-report diagnostic'}
            if($case -in 'max_three','stdout_bitmap'){Assert ($log[0].raw_error -match 'WriteableBitmap' -and $log[0].stage -eq 'native_map_bitmap') 'missing worker failure details'}
        }
        $results.Add(@{name=$case;passed=$true;calls=$script:calls})
    }catch{$results.Add(@{name=$case;passed=$false;calls=$script:calls;error=$_.Exception.Message})}
}
$failed=@($results|Where-Object {-not $_.passed})
$report=@{status=$(if($failed.Count){'fail'}else{'pass'});checks=$results;failed=$failed.Count;output_directory=$testRoot}
[IO.File]::WriteAllText((Join-Path $testRoot 'test_report.json'),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
$report|ConvertTo-Json -Depth 8
if($failed.Count){exit 1}
