param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Core'){throw 'requires_powershell_core'}
$request=Get-Content -LiteralPath $RequestPath -Encoding UTF8 -Raw|ConvertFrom-Json
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$scripts=Join-Path $root '03_tools/scripts'
$nativeShell=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
$aztec='C:\Program Files\Oxford Instruments NanoAnalysis\AZtec'
$out=[IO.Path]::GetFullPath([string]$request.output)
$source=[IO.Path]::GetFullPath([string]$request.input)
$crc=[IO.Path]::ChangeExtension($source,'.crc')
$templateConfig=@{}
$templatePath=[string]$request.template
if(Test-Path -LiteralPath $out){throw 'output_path_must_be_new'}
if($out.StartsWith('\\') -or $source.StartsWith('\\')){throw 'local_paths_only'}
$staProbe="if (`$PSVersionTable.PSEdition -ne 'Desktop') { exit 21 }; if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) { exit 22 }; exit 0"
$staProbeEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($staProbe))
$staProbeProcess=Start-Process -FilePath $nativeShell -ArgumentList @('-NoProfile','-STA','-EncodedCommand',$staProbeEncoded) -WindowStyle Hidden -PassThru -Wait
if($staProbeProcess.ExitCode -ne 0){throw ('framework_sta_preflight_failed:exit=' + $staProbeProcess.ExitCode + ';expected=Desktop|STA')}
[IO.Directory]::CreateDirectory($out)|Out-Null
# Atomic ownership prevents concurrent CLI calls from sharing this job directory.
$ownership=[IO.File]::Open((Join-Path $out '.owner'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
$utf8=[Text.UTF8Encoding]::new($true)
function JsonNew($path,$obj){$s=[IO.File]::Open($path,[IO.FileMode]::CreateNew);$w=[IO.StreamWriter]::new($s,$utf8);try{$w.Write(($obj|ConvertTo-Json -Depth 18))}finally{$w.Dispose()}}
function Sha($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
function Log($message){[IO.File]::AppendAllText((Join-Path $out 'render.log'),([DateTime]::UtcNow.ToString('o')+' '+$message+[Environment]::NewLine),$utf8)}
$manifest=[ordered]@{schema_version=1;status='running';input=$source;crc=$crc;started_utc=[DateTime]::UtcNow.ToString('o');runtime=@{host_framework='.NET Framework 4.8';host_architecture='x64';native_process='Windows PowerShell 5.1 -STA';dll_isolation='child_process';network_mode='disabled';http_enabled=$false;gui_enabled=$false};native_data_status='pending';renderer='frozen_compatible_canvas';NativeFullMapFidelity='not_accepted';template=$(if($templatePath -in 'frozen-v1','native-v1'){$templatePath}else{@{path=$templatePath;sha256=(Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash}});custom_display_ranges=$templateConfig;gui_started=$false;mtex_used=$false;pillow_used=$false;reference_pixels_used=$false;outputs=@();errors=@();commands=@();limitations=@('AxisEdgeAligned is a validated compatibility rule, not proven internal viewport metadata.','2-degree gray boundaries, native stroke/antialiasing and saved full-map layout remain unverified.','Same-schema same-length CPR/CRC swaps have no inherent pair identity; supply expected_crc_sha256 from a trusted source for provenance validation.','CPR/CRC must already be cleaned and saved; no cleanup is performed.')}
function Invoke-Stage([string]$Name,[string]$Executable,[string[]]$Arguments){
    $prefix=Join-Path $out ('work/'+$Name)
    $frameworkSta=($Executable -match '(?i)\\WindowsPowerShell\\v1\.0\\powershell\.exe$' -and
       @($Arguments).Count -eq 4 -and $Arguments[0] -eq '-NoProfile' -and
       $Arguments[1] -eq '-STA' -and $Arguments[2] -eq '-EncodedCommand')
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$Executable;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    if(-not $frameworkSta){
        foreach($a in $Arguments){$info.ArgumentList.Add($a)}
    }
    $entry=[ordered]@{stage=$Name;executable=$Executable;arguments=$Arguments;timeout_seconds=$request.timeout_seconds;started_utc=[DateTime]::UtcNow.ToString('o');launcher=$(if($frameworkSta){'Start-Process'}else{'ProcessStartInfo'})}
    $p=$null;$ot=$null;$et=$null;Log ('start '+$Name)
    try{
        if($frameworkSta){
            $stdoutPath=$prefix+'.stdout.log';$stderrPath=$prefix+'.stderr.log'
            $p=Start-Process -FilePath $Executable -ArgumentList @($Arguments) -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        }else{
            $p=[Diagnostics.Process]::new();$p.StartInfo=$info
            if(-not $p.Start()){throw 'process_start_failed'}
            $ot=$p.StandardOutput.ReadToEndAsync();$et=$p.StandardError.ReadToEndAsync()
        }
        if(-not $p.WaitForExit([int]$request.timeout_seconds*1000)){$p.Kill($true);$p.WaitForExit();$entry.timed_out=$true;throw ('stage_timeout:'+ $Name)}
        $entry.exit_code=$p.ExitCode
        if($p.ExitCode -ne 0){throw ('stage_failed:'+ $Name+';exit='+$p.ExitCode+';see='+$prefix+'.stderr.log')}
    }finally{
        if($ot){[IO.File]::WriteAllText(($prefix+'.stdout.log'),$ot.GetAwaiter().GetResult(),$utf8);[IO.File]::WriteAllText(($prefix+'.stderr.log'),$et.GetAwaiter().GetResult(),$utf8);$entry.exit_code=$p.ExitCode}
        $entry.finished_utc=[DateTime]::UtcNow.ToString('o');$manifest.commands+=@($entry);if($null -ne $p){$p.Dispose()}
    }
    Log ('complete '+$Name)
}
function Native([string]$Name,[string]$Script,[hashtable]$Parameters){
    # Keep the encoded child wrapper; the worker's current-thread STA check is
    # authoritative because launch flags do not guarantee its apartment.
    $payload=@{script=$Script;parameters=$Parameters}|ConvertTo-Json -Depth 6 -Compress
    $b=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $hash='function global:Get-FileHash {param([string]$LiteralPath,[string]$Algorithm="SHA256");$h=[Security.Cryptography.SHA256]::Create();$s=[IO.File]::OpenRead($LiteralPath);try{[pscustomobject]@{Hash=([BitConverter]::ToString($h.ComputeHash($s))).Replace("-","")}}finally{$s.Dispose();$h.Dispose()}};'
    $code="`$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false);$hash `$r=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b'))|ConvertFrom-Json);`$a=@{};foreach(`$v in `$r.parameters.PSObject.Properties){`$a[`$v.Name]=`$v.Value}; & `$r.script @a"
    Invoke-Stage $Name $nativeShell @('-NoProfile','-STA','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))
}
function NativeMapWithRetry([string]$Name,[string]$Script,[hashtable]$Parameters){
    # WPF bitmap creation can fail transiently in the vendor worker before any
    # pixels are emitted. Each retry gets a fresh output directory and a fresh
    # Windows PowerShell STA process; failed attempts remain available for audit.
    $baseOutput=[IO.Path]::GetFullPath([string]$Parameters.OutputDirectory)
    $parent=[IO.Path]::GetDirectoryName($baseOutput)
    $leaf=[IO.Path]::GetFileName($baseOutput)
    $attemptLimit=3
    $lastError=$null
    $attempts=[Collections.Generic.List[object]]::new()
    for($attempt=1;$attempt -le $attemptLimit;$attempt++){
        if($attempt -gt 1){Start-Sleep -Milliseconds 750}
        $attemptOutput=if($attempt -eq 1){$baseOutput}else{Join-Path $parent ($leaf+'_retry'+$attempt)}
        $attemptParameters=@{}
        foreach($key in $Parameters.Keys){$attemptParameters[$key]=$Parameters[$key]}
        $attemptParameters.OutputDirectory=$attemptOutput
        try{
            Native ($Name+'_attempt'+$attempt) $Script $attemptParameters | Out-Null
            $attempts.Add([pscustomobject]@{attempt=$attempt;output_directory=$attemptOutput;status='completed'})
            return [pscustomobject]@{OutputDirectory=$attemptOutput;Attempts=$attempt;AttemptLog=@($attempts)}
        }catch{
            $lastError=$_.Exception
            $prefix=Join-Path $out ('work/'+$Name+'_attempt'+$attempt)
            $diagnosticErrors=[Collections.Generic.List[object]]::new()
            $stderr='';$workerError='';$workerStage='';$workerStatus='';$errorSource='invocation'
            try{
                if([IO.File]::Exists(($prefix+'.stderr.log'))){$stderr=[IO.File]::ReadAllText(($prefix+'.stderr.log'))}
            }catch{$diagnosticErrors.Add(@{path=($prefix+'.stderr.log');error=$_.Exception.Message})}
            # The worker catches native exceptions and writes them to its report
            # and stdout before exiting 1; stderr can legitimately be empty.
            foreach($diagnosticPath in @((Join-Path $attemptOutput 'report.json'),($prefix+'.stdout.log'))){
                if($workerError -and $workerStage -and $workerStatus){break}
                try{
                    if(-not [IO.File]::Exists($diagnosticPath)){continue}
                    $diagnosticText=[IO.File]::ReadAllText($diagnosticPath)
                    if(-not $diagnosticText.Trim()){continue}
                    $workerReport=$diagnosticText|ConvertFrom-Json -ErrorAction Stop
                    if(-not $workerError -and $workerReport.error){
                        $workerError=[string]$workerReport.error
                        $errorSource=if($diagnosticPath.EndsWith('.stdout.log')){'worker_stdout'}else{'worker_report'}
                    }
                    if(-not $workerStage){$workerStage=[string]$workerReport.stage}
                    if(-not $workerStatus){$workerStatus=[string]$workerReport.status}
                }catch{$diagnosticErrors.Add(@{path=$diagnosticPath;error=$_.Exception.Message})}
            }
            $rawError=if($workerError){$workerError}elseif($stderr){$errorSource='stderr';$stderr}else{$lastError.Message}
            $detail=($workerStatus+' '+$workerStage+' '+$rawError+' '+$stderr+' '+$lastError.Message)
            $nonRetryable=($detail -match '(?i)requires_Windows_PowerShell_Framework_STA_child_process|apartment|\bSTA\b|(?:input|source).*(?:chang|verification_failed|hash_mismatch)|saved_bitmap_disagrees_with_native_pixels|(?:pixel|bitmap).*(?:mismatch|disagree)|verify_saved_native_pixels')
            $transient=(-not $nonRetryable -and $detail -match '(?i)RegisterClassEx|WriteableBitmap|System\.Windows\.Media\.Geometry')
            $attempts.Add([pscustomobject]@{attempt=$attempt;output_directory=$attemptOutput;status='failed';transient=$transient;stage=$workerStage;worker_status=$workerStatus;raw_error=$rawError;error_source=$errorSource;error=$lastError.Message;diagnostic_errors=@($diagnosticErrors)})
            if(-not $transient -or $attempt -eq $attemptLimit){
                throw ('native_map_attempt_failed:'+($attempts|ConvertTo-Json -Compress -Depth 6))
            }
        }
    }
    throw ('native_map_attempt_failed:'+($attempts|ConvertTo-Json -Compress -Depth 6))
}
function ReadJson($p){Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json}
function ScalarCanvas($type,$point,$min,$max){
    Native ('render_'+$type) (Join-Path $scripts 'render_aztec_native_scalar_canvas.ps1') @{Metric=$type;PointBmp=$point;OutputBmp=(Join-Path $out ($type+'.bmp'));DisplayMin=$min;DisplayMax=$max;CanvasWidth=$cw;CanvasHeight=$ch;MapX=1;MapY=34;MapWidth=2733;MapHeight=$mh;MappingMode='AxisEdgeAligned'}
}
try{
    if($templatePath -and $templatePath -notin 'frozen-v1','native-v1'){
        if(-not [IO.File]::Exists($templatePath)){throw 'template_not_found'}
        $templateObject=Get-Content -LiteralPath $templatePath -Encoding UTF8 -Raw|ConvertFrom-Json
        foreach($property in $templateObject.PSObject.Properties){
            $metric=$property.Name.ToLowerInvariant()
            if($metric -notin 'kam','gos'){throw ('unsupported_template_field:'+ $property.Name)}
            $section=$property.Value
            $sectionNames=@($section.PSObject.Properties.Name)
            if(($sectionNames|Sort-Object) -join ',' -ne 'max,min'){throw ('template_requires_min_max:'+ $metric)}
            $minimum=[double]$section.min;$maximum=[double]$section.max
            if([double]::IsNaN($minimum) -or [double]::IsInfinity($minimum) -or [double]::IsNaN($maximum) -or [double]::IsInfinity($maximum) -or $minimum -ge $maximum){throw ('invalid_template_range:'+ $metric)}
            $templateConfig[$metric]=@($minimum,$maximum)
        }
        $manifest.custom_display_ranges=$templateConfig
    }
    if(-not [IO.File]::Exists($source)){throw 'input_cpr_not_found'}
    if([IO.Path]::GetExtension($source) -ine '.cpr'){throw 'input_must_be_cpr'}
    if(-not [IO.File]::Exists($crc)){throw 'companion_crc_not_found'}
    if($out.StartsWith('\\') -or $source.StartsWith('\\')){throw 'local_paths_only'}
    if([int]$request.timeout_seconds -lt 10 -or [int]$request.timeout_seconds -gt 900){throw 'invalid_timeout'}
    $types=@($request.types|ForEach-Object {([string]$_).ToUpperInvariant()}|Select-Object -Unique)
    if(-not $types.Count -or @($types|Where-Object {$_ -notin 'IPF','KAM','GOS'}).Count){throw 'unsupported_image_type'}
    $header=[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($source))
    $meta=@{};foreach($m in [regex]::Matches($header,'(?m)^(xCells|yCells|NoOfPoints|GridDistX|GridDistY)=([^\r\n]+)')){$meta[$m.Groups[1].Value]=$m.Groups[2].Value}
    $w=[int]$meta.xCells;$h=[int]$meta.yCells
    if($w -lt 2 -or $h -lt 2 -or [long]$w*$h -ne [long]$meta.NoOfPoints -or [long]$w*$h -gt 10000000){throw 'unsupported_regular_grid'}
    # This deployed profile accepts the already validated nine-field CPR schema only.
    $fields=@([regex]::Matches($header,'(?m)^Field\d+=(\d+)\r?$')|ForEach-Object {$_.Groups[1].Value})
    if(($fields -join ',') -ne '3,4,5,6,7,8,10,11,12'){throw 'unsupported_crc_field_schema'}
    if(([IO.FileInfo]::new($crc)).Length -ne [long]$w*$h*25){throw 'cpr_crc_record_length_mismatch'}
    $before=@{cpr=Sha $source;crc=Sha $crc}
    if($request.expected_crc_sha256 -and $before.crc -ine [string]$request.expected_crc_sha256){throw 'crc_provenance_hash_mismatch'}
    [IO.Directory]::CreateDirectory((Join-Path $out 'work'))|Out-Null
    Log 'validated_input'
    $manifest.input_hashes=$before;$manifest.requested_types=$types
    $manifest.native_components=@(Get-Item -LiteralPath (Join-Path $aztec 'core.ebsd.dll')|ForEach-Object {@{path=$_.FullName;version=$_.VersionInfo.FileVersion;sha256=Sha $_.FullName}})
    if($templatePath -ne 'frozen-v1'){
        $worker=Join-Path $PSScriptRoot 'native_map.ps1'
        $manifest.renderer='aztec_crystal_native_map_export'
        $manifest.native_components+=@(Get-Item -LiteralPath (Join-Path $aztec 'AZtecCrystal.exe')|ForEach-Object {@{path=$_.FullName;version=$_.VersionInfo.FileVersion;sha256=Sha $_.FullName}})
        $manifest.production_sources=@(Get-Item -LiteralPath $worker,$PSCommandPath,(Join-Path $PSScriptRoot 'AZtecBmpExporter.exe')|ForEach-Object {@{path=$_.FullName;sha256=Sha $_.FullName}})
        $apiAssembly=Join-Path $PSScriptRoot 'AZtecBmpExporter.dll'
        if([IO.File]::Exists($apiAssembly)){$manifest.production_sources+=@(@{path=$apiAssembly;sha256=Sha $apiAssembly})}
        $manifest.grid=@{width=$w;height=$h;points=$w*$h;step_x_micron=[double]$meta.GridDistX;step_y_micron=[double]$meta.GridDistY}
        $manifest.display_semantics=@{map_and_legend='AZtecCrystal MapExport';ui_culture='zh-CN';pixel_width=2734;scale_bar=$false;range='native Automatic unless explicitly supplied';ipf='unique saved BC + IPF + grain-boundaries map required'}
        $manifest.limitations=@('Uses the installed AZtec Crystal version; no public stable SDK contract is assumed.','Full-map fidelity still requires per-sample comparison; invoking native code alone does not prove equality.','IPF requires one unambiguous saved BC/IPF/grain-boundaries map.','CPR/CRC must already be cleaned and saved; no cleanup is performed.','Same-schema same-length CPR/CRC swaps have no inherent pair identity; supply expected_crc_sha256 for provenance validation.','Native map workers retry transient WPF bitmap initialization failures in fresh STA child processes; failed attempt directories are retained.')
        foreach($type in $types){
            try{
                $nativeOut=Join-Path $out ('work/native_'+$type)
                $parameters=@{CprPath=$source;OutputDirectory=$nativeOut;Metric=$type;PixelWidth=2734;AztecRoot=$aztec}
                $rangeKey=$type.ToLowerInvariant()
                if($templateConfig.ContainsKey($rangeKey)){
                    $parameters.DisplayMin=[double]$templateConfig[$rangeKey][0]
                    $parameters.DisplayMax=[double]$templateConfig[$rangeKey][1]
                }
                $nativeAttempt=NativeMapWithRetry ('native_map_'+$type) $worker $parameters
                $nativeOut=[string]$nativeAttempt.OutputDirectory
                $nativeAttempts=[int]$nativeAttempt.Attempts
                $reportPath=Join-Path $nativeOut 'report.json'
                $report=ReadJson $reportPath
                if($report.status -ne 'native_map_exported'){throw 'native_map_report_not_completed'}
                $nativeImage=Join-Path $nativeOut ($type+'.bmp')
                if([IO.Path]::GetFullPath([string]$report.output) -ne [IO.Path]::GetFullPath($nativeImage)){throw 'native_map_report_output_mismatch'}
                $nativeInfo=[IO.FileInfo]::new($nativeImage)
                if($report.bytes -ne $nativeInfo.Length){throw 'native_map_report_bytes_mismatch'}
                if([int]$report.width -le 0 -or [int]$report.height -le 0){throw 'native_map_report_geometry_invalid'}
                if($report.saved_pixels_match_native -ne $true -or
                   $report.native_pixel_snapshot.sha256 -notmatch '\A[0-9A-F]{64}\z' -or
                   $report.native_pixel_snapshot.sha256 -ne $report.saved_pixel_snapshot.sha256 -or
                   $report.saved_pixel_snapshot.width -ne $report.width -or
                   $report.saved_pixel_snapshot.height -ne $report.height){throw 'native_map_pixel_snapshot_mismatch'}
                if((Sha $nativeImage) -ne $report.sha256){throw 'native_map_output_hash_mismatch'}
                if($report.before.cpr -ne $before.cpr -or $report.before.crc -ne $before.crc -or $report.after.cpr -ne $before.cpr -or $report.after.crc -ne $before.crc){throw 'native_map_input_hash_mismatch'}
                $target=Join-Path $out ($type+'.bmp')
                [IO.File]::Copy($nativeImage,$target,$false)
                $targetInfo=[IO.FileInfo]::new($target)
                if($targetInfo.Length -ne $nativeInfo.Length){throw 'copied_output_bytes_mismatch'}
                $targetSha=Sha $target
                if($targetSha -ne $report.sha256){throw 'copied_output_hash_mismatch'}
                $manifest.outputs+=@(@{type=$type;path=$target;sha256=$targetSha;pixel_sha256=$report.saved_pixel_snapshot.sha256;pixel_format=$report.saved_pixel_snapshot.format;bytes=$targetInfo.Length;status='completed';width=$report.width;height=$report.height;native_report=$reportPath;native_report_sha256=Sha $reportPath;native_attempts=$nativeAttempts;native_attempt_log=$nativeAttempt.AttemptLog;limits=$report.limits_for_drawing})
                Log ('output_complete '+$type)
            }catch{
                $manifest.outputs+=@(@{type=$type;status='failed';error=$_.Exception.Message})
                $manifest.errors+=@(@{stage=$type;error=$_.Exception.Message})
                Log ('output_failed '+$type+' '+$_.Exception.Message)
            }
        }
    }else{
    $productionSources=@(Get-ChildItem -LiteralPath $PSScriptRoot -File|Where-Object {$_.Extension -in '.ps1','.cs','.exe'})+@(Get-Item -LiteralPath (Join-Path $scripts 'AztecNativeIpfConsole.exe'),(Join-Path $scripts 'AztecNativeIpfKeyProbeNoDispose.exe'),(Join-Path $scripts 'export_aztec_native_gos_pixels.ps1'),(Join-Path $scripts 'AztecNativeGosPixelAudit.cs'),(Join-Path $scripts 'export_aztec_native_kam_gos.ps1'),(Join-Path $scripts 'export_aztec_native_scalar_bmp.ps1'),(Join-Path $scripts 'render_aztec_native_scalar_canvas.ps1'),(Join-Path $root 'aztec_bmp_compare/p46_ipf_overlay/IpfOverlayRenderer.cs'),(Join-Path $root 'aztec_bmp_compare/p46_ipf_overlay/export_native_bc.ps1'),(Join-Path $root 'aztec_bmp_compare/p46_ipf_overlay/NativeBcAudit.cs'))
    $manifest.production_sources=@($productionSources|ForEach-Object {@{path=$_.FullName;sha256=Sha $_.FullName}})
    $manifest.display_semantics=@{scalar_scale='AZtec HeatMap';gradient=$true;steps=5;inverted=$false;GOS='Phase0, invalid grain or null native GetPixel -> white';KAM='indexed tuple-invalid -> native minimum color; Phase0 -> white; numeric Valid is unchanged';IPF='Phase0 uses native BC gray alone';scale_bar='Map/step text; no native physical-length scale bar recovered'}
    $keydir=Join-Path $out 'work/metadata_keys'
    $keyjson=Join-Path $keydir 'keys.json'
    Invoke-Stage 'native_metadata' (Join-Path $scripts 'AztecNativeIpfKeyProbeNoDispose.exe') @($aztec,$source,$keyjson,$keydir)
    $nativeMetadata=ReadJson $keyjson
    if($nativeMetadata.grid -ne ($w.ToString()+'x'+$h.ToString()) -or $nativeMetadata.step_x_micron -ne [double]$meta.GridDistX -or $nativeMetadata.step_y_micron -ne [double]$meta.GridDistY){throw 'native_grid_disagrees_with_cpr_header'}
    $manifest.phases=@($nativeMetadata.phases|Select-Object phase_id,name,laue_group)
    $aspect=([double]::Parse($meta.GridDistX,[Globalization.CultureInfo]::InvariantCulture)*$w)/([double]::Parse($meta.GridDistY,[Globalization.CultureInfo]::InvariantCulture)*$h)
    if(-not [double]::IsFinite($aspect) -or $aspect -le 0){throw 'invalid_physical_aspect'}
    $cw=2914;$mh=[int][math]::Round(2733/$aspect);$ch=$mh+70
    if($ch -gt 16000 -or $mh -lt 100){throw 'unsupported_canvas_aspect'}
    $manifest.grid=@{width=$w;height=$h;points=$w*$h;step_x_micron=[double]$meta.GridDistX;step_y_micron=[double]$meta.GridDistY}
    $manifest.canvas=@{width=$cw;height=$ch;map_rect=@{x=1;y=34;width=2733;height=$mh};layout_source='deterministic physical-aspect compatibility; no reference read';mapping='AxisEdgeAligned'}
    $manifest.calculation=@{KAM=@{kernel='Square 3x3';only_periphery=$true;max_angle_degrees=5;range_policy='frozen-v1: max(4.92, ceil(native valid maximum * 100)/100); custom template overrides'};GOS=@{parameter='Mean';boundary_degrees=10;range_policy='native newly populated layer Automatic LimitsForDrawing'};IPF=@{direction='Z0';color='native IPFColorCoding.GetColor';bc='native Automatic GetPixel';mix='floor_half';gb='same_phase_valid;shared-next;black1px;noAA'}}
    $gos=Join-Path $out 'work/gos';$gosReady=$false
    if('GOS' -in $types -or 'IPF' -in $types){
        try{
            $gosParameters=@{CprPath=$source;AztecRoot=$aztec;BoundaryThresholdAngleDegree=10;GosParameter='Mean';ProductionOutputDirectory=$gos;SummaryOnly=$true}
            if($templateConfig.ContainsKey('gos')){
                $gosParameters.DisplayMin=[double]$templateConfig.gos[0]
                $gosParameters.DisplayMax=[double]$templateConfig.gos[1]
                $manifest.calculation.GOS.range_policy='native UserDefined LimitsForDrawing from template; float/GetPixel retained'
            }
            Native 'native_gos' (Join-Path $PSScriptRoot 'native_gos.ps1') $gosParameters
            $gosReady=$true
        }
        catch{$manifest.errors+=@(@{stage='native_gos';error=$_.Exception.Message});Log $_.Exception.Message}
    }
    foreach($type in $types){
        try{
            switch($type){
                IPF {
                    if(-not $gosReady){throw 'ipf_topology_dependency_failed'}
                    $layout=Join-Path $out 'work/layout.bmp'
                    Invoke-Stage 'ipf_layout' (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile','-File',(Join-Path $PSScriptRoot 'render_ipf_layout.ps1'),'-CprPath',$source,'-OutputBmp',$layout,'-NativeIpfExe',(Join-Path $scripts 'AztecNativeIpfConsole.exe'),'-KeyProbeExe',(Join-Path $scripts 'AztecNativeIpfKeyProbeNoDispose.exe'),'-CanvasWidth',"$cw",'-CanvasHeight',"$ch",'-LegendWidth','179','-MappingMode','AxisEdgeAligned')
                    $key=ReadJson (Join-Path $out 'work/layout_native_inputs/keys/keys.json')
                    $pointReport=ReadJson (Join-Path $out 'work/layout_native_inputs/ipf_points.json')
                    if($pointReport.width -ne $w -or $pointReport.height -ne $h -or $key.step_x_micron -ne [double]$meta.GridDistX -or $key.step_y_micron -ne [double]$meta.GridDistY){throw 'native_grid_disagrees_with_cpr_header'}
                    $manifest.phases=@($key.phases|Select-Object phase_id,name,laue_group)
                    $bc=Join-Path $out 'work/bc';[IO.Directory]::CreateDirectory($bc)|Out-Null
                    Native 'native_bc' (Join-Path $root 'aztec_bmp_compare/p46_ipf_overlay/export_native_bc.ps1') @{NativeChild=$true;CprPath=$source;OutputDirectory=$bc;AztecRoot=$aztec}
                    Add-Type -AssemblyName System.Drawing
                    $refs=@([Drawing.Bitmap].Assembly.Location,[Drawing.Rectangle].Assembly.Location,(Join-Path $PSHOME 'ref/System.Collections.dll'))+@([AppDomain]::CurrentDomain.GetAssemblies()|Where-Object {$_.GetName().Name -like 'System.Private.Windows.*'}|ForEach-Object Location)
                    Add-Type -Path (Join-Path $root 'aztec_bmp_compare/p46_ipf_overlay/IpfOverlayRenderer.cs') -ReferencedAssemblies $refs
                    $s=[P46IpfRenderer]::Load((Join-Path $out 'work/layout_native_inputs/ipf_points.bmp'),(Join-Path $gos 'point_audit.csv'),(Join-Path $bc 'bc_sources.csv'),$w,$h)
                    $image=[P46IpfRenderer]::Render($s,[P46IpfRenderer+PixelImage]::new($layout),1,34,2733,$mh,'bc_gb','floor_half','same_phase_valid','next')
                    $image.Save((Join-Path $out 'IPF.bmp'))
                    $manifest.ipf_native_report=$pointReport
                    $manifest.bc_limits=(ReadJson (Join-Path $bc 'bc_native.json')).actual_limits_for_drawing
                }
                KAM {
                    $kam=Join-Path $out 'work/kam'
                    [IO.Directory]::CreateDirectory($kam)|Out-Null
                    Native 'native_kam_values' (Join-Path $scripts 'export_aztec_native_kam_gos.ps1') @{CprPath=$source;OutputJson=(Join-Path $kam 'values.json');OutputCsv=(Join-Path $kam 'values.csv');SummaryOnly=$true;AztecRoot=$aztec}
                    $kamColorParameters=@{CprPath=$source;InputCsv=(Join-Path $kam 'values.csv');Metric='KAM';OutputBmp=(Join-Path $kam 'native_pixels.bmp');OutputReport=(Join-Path $kam 'colors.json');AztecRoot=$aztec}
                    # A user KAM template must reach the native point-color stage.  The
                    # canvas renderer only copies point RGB values, so passing a custom
                    # range only to ScalarCanvas changes the legend but not the map.
                    # Keep frozen-v1 on the original automatic range to preserve its
                    # accepted byte-for-byte output.
                    if($templateConfig.ContainsKey('kam')){
                        $kamColorParameters.DisplayMin=[double]$templateConfig.kam[0]
                        $kamColorParameters.DisplayMax=[double]$templateConfig.kam[1]
                    }
                    Native 'native_kam_colors' (Join-Path $scripts 'export_aztec_native_scalar_bmp.ps1') $kamColorParameters
                    Native 'native_kam' (Join-Path $PSScriptRoot 'native_kam.ps1') @{CprPath=$source;OutputDirectory=$kam;AztecRoot=$aztec}
                    $colors=ReadJson (Join-Path $kam 'colors.json')
                    $kamMin=[double]$colors.display_min;$kamMax=[double]$colors.display_max
                    # Preserve the P4.7 frozen compatible-map scale while allowing larger observed maxima.
                    if($templatePath -eq 'frozen-v1'){$kamMax=[math]::Max(4.92,$kamMax)}
                    if($templateConfig.ContainsKey('kam')){$kamMin=$templateConfig.kam[0];$kamMax=$templateConfig.kam[1]}
                    $kamPointBmp=Join-Path $kam 'points.bmp'
                    ScalarCanvas KAM $kamPointBmp $kamMin $kamMax
                    $manifest.kam_limits=@($kamMin,$kamMax)
                }
                GOS {
                    if(-not $gosReady){throw 'gos_native_dependency_failed'}
                    $g=ReadJson (Join-Path $gos 'native_pixel_audit.json')
                    $gosMin=[double]$g.limits_for_drawing[0];$gosMax=[double]$g.limits_for_drawing[1]
                    if($templateConfig.ContainsKey('gos') -and ($gosMin -ne $templateConfig.gos[0] -or $gosMax -ne $templateConfig.gos[1])){throw 'gos_template_native_range_mismatch'}
                    ScalarCanvas GOS (Join-Path $gos 'GOS_calibrated_pixels.bmp') $gosMin $gosMax
                    $manifest.gos_limits=@($gosMin,$gosMax);$manifest.grains=$g.counts
                }
            }
            $p=Join-Path $out ($type+'.bmp');$manifest.outputs+=@(@{type=$type;path=$p;sha256=Sha $p;bytes=([IO.FileInfo]::new($p)).Length;status='completed'});Log ('output_complete '+$type)
        }catch{$manifest.outputs+=@(@{type=$type;status='failed';error=$_.Exception.Message});$manifest.errors+=@(@{stage=$type;error=$_.Exception.Message});Log ('output_failed '+$type+' '+$_.Exception.Message)}
    }
    }
    $after=@{cpr=Sha $source;crc=Sha $crc};$manifest.input_hashes_after=$after
    if($before.cpr -ne $after.cpr -or $before.crc -ne $after.crc){throw 'input_hash_changed'}
    $ok=@($manifest.outputs|Where-Object status -eq 'completed').Count
    $manifest.status=if($ok -eq $types.Count){'completed'}elseif($ok -gt 0){'partial_failed'}else{'failed'}
    $manifest.native_data_status='see_per_type_results'
    $manifest.native_artifacts=@(Get-ChildItem -LiteralPath (Join-Path $out 'work') -File -Recurse | Where-Object {$_.Extension -in '.bmp','.csv','.json'} | ForEach-Object {@{path=$_.FullName;sha256=Sha $_.FullName;bytes=$_.Length}})
}catch{
    $manifest.status='failed';$manifest.errors+=@(@{stage='validation_or_pipeline';error=$_.Exception.Message})
    if(-not [IO.Directory]::Exists($out)){[IO.Directory]::CreateDirectory($out)|Out-Null}
    if(-not [IO.File]::Exists((Join-Path $out 'render_manifest.json'))){Log ('failed '+$_.Exception.Message)}
}finally{
    $manifest.finished_utc=[DateTime]::UtcNow.ToString('o')
    if(-not [IO.File]::Exists((Join-Path $out 'render_manifest.json'))){JsonNew (Join-Path $out 'render_manifest.json') $manifest}
    $ownership.Dispose()
}
$manifest|ConvertTo-Json -Depth 5
if($manifest.status -eq 'completed'){exit 0}elseif($manifest.status -eq 'partial_failed'){exit 2}else{exit 1}
