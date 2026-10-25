param(
    [Parameter(Mandatory = $true)] [string] $CprPath,
    [string] $AztecRoot = 'C:\Program Files\Oxford Instruments NanoAnalysis\AZtec',
    [string] $OutputCsv,
    [string] $OutputGrainCsv,
    [string] $OutputGrainStatsCsv,
    [string] $OutputBoundaryCsv,
    [string] $OutputValidityCsv,
    [string] $PixelAuditOutputDirectory,
    [string] $PixelAuditLegacyCsv,
    [double] $PixelAuditDisplayMin = 0,
    [double] $PixelAuditDisplayMax = 0,
    [double] $BoundaryThresholdAngleDegree = -1,
    [ValidateSet('Mean', 'Max')] [string] $GosParameter = 'Mean',
    [double] $DisplayMin,
    [double] $DisplayMax,
    [switch] $SummaryOnly,
    [switch] $SummaryBase64
    ,[string] $ProductionOutputDirectory
)

$ErrorActionPreference = 'Stop'
$hasDisplayRange = $PSBoundParameters.ContainsKey('DisplayMin') -or $PSBoundParameters.ContainsKey('DisplayMax')
if ($hasDisplayRange) {
    if (-not $PSBoundParameters.ContainsKey('DisplayMin') -or -not $PSBoundParameters.ContainsKey('DisplayMax')) {
        throw 'display_range_requires_both_min_and_max'
    }
    if ([double]::IsNaN($DisplayMin) -or [double]::IsInfinity($DisplayMin) -or
        [double]::IsNaN($DisplayMax) -or [double]::IsInfinity($DisplayMax) -or $DisplayMin -ge $DisplayMax) {
        throw 'display_range_requires_finite_min_less_than_max'
    }
}
if (-not (Test-Path -LiteralPath $CprPath -PathType Leaf)) { throw "missing_cpr:$CprPath" }
$fullPath = (Resolve-Path -LiteralPath $CprPath).Path
$sourceCrc = [IO.Path]::ChangeExtension($fullPath, '.crc')
if (-not [IO.File]::Exists($sourceCrc)) { throw "source_crc_missing:$sourceCrc" }
Set-Location -LiteralPath $AztecRoot
Get-ChildItem -LiteralPath $AztecRoot -Filter '*.dll' -File | ForEach-Object {
    try { [Reflection.Assembly]::LoadFrom($_.FullName) | Out-Null } catch { }
}
[Reflection.Assembly]::LoadFrom((Join-Path $AztecRoot 'core.ebsd.dll')) | Out-Null
if ($null -eq ('AztecProbe.NoopProgress' -as [type])) {
    Add-Type -TypeDefinition 'namespace AztecProbe { public sealed class NoopProgress : System.IProgress<int> { public void Report(int value) {} } }'
}
$progress = [AztecProbe.NoopProgress]::new()

function Get-MemberReport([Type] $Type) {
    $methods = @($Type.GetMethods([Reflection.BindingFlags]'Public,NonPublic,Instance,DeclaredOnly') |
        Where-Object { $_.Name -match 'value|data|grid|map|pixel|populate|calculate|grain' } |
        ForEach-Object {
            [pscustomobject]@{
                name = $_.Name
                is_public = $_.IsPublic
                is_abstract = $_.IsAbstract
                parameters = @($_.GetParameters() | ForEach-Object { $_.ParameterType.FullName })
                return_type = $_.ReturnType.FullName
            }
        })
    $properties = @($Type.GetProperties([Reflection.BindingFlags]'Public,NonPublic,Instance,DeclaredOnly') |
        ForEach-Object {
            [pscustomobject]@{
                name = $_.Name
                property_type = $_.PropertyType.FullName
                getter_public = ($null -ne $_.GetGetMethod($true) -and $_.GetGetMethod($true).IsPublic)
            }
        })
    [pscustomobject]@{ type = $Type.FullName; methods = $methods; properties = $properties }
}

function Get-Sha256Hex([string] $Path) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        $digest = $algorithm.ComputeHash($stream)
        return ([BitConverter]::ToString($digest)).Replace('-', '')
    } finally {
        $stream.Dispose()
        $algorithm.Dispose()
    }
}

$project = $null
$stage = 'open_project'
try {
    $sourceCprHash = Get-Sha256Hex $fullPath
    $sourceCrcHash = Get-Sha256Hex $sourceCrc
    $project = [Core.Ebsd.Infrastructure.Project]::new($fullPath)
    if ($project.DatasetCount -ne 1) { throw "unexpected_dataset_count:$($project.DatasetCount)" }
    $dataset = $project.Datasets[0]
    if (-not $dataset.IsPopulated) { $dataset.PopulateData() }

    $boundaryMap = [Core.Ebsd.Grains.BoundaryMap]::new($dataset)
    $boundarySettings = $boundaryMap.Settings
    $boundarySettingsType = $boundaryMap.GetType().Assembly.GetType('Core.Ebsd.Grains.BoundaryMapSettings', $false)
    $boundarySettingsApi = if ($null -ne $boundarySettingsType) {
        [pscustomobject]@{
            type = $boundarySettingsType.FullName
            constructors = @($boundarySettingsType.GetConstructors([Reflection.BindingFlags]'Public,NonPublic,Instance') | ForEach-Object { @($_.GetParameters() | ForEach-Object { $_.ParameterType.FullName }) })
            properties = @($boundarySettingsType.GetProperties([Reflection.BindingFlags]'Public,NonPublic,Instance,Static') | ForEach-Object {
                [pscustomobject]@{ name = $_.Name; type = $_.PropertyType.FullName; getter_public = ($null -ne $_.GetGetMethod($true) -and $_.GetGetMethod($true).IsPublic); setter_public = ($null -ne $_.GetSetMethod($true) -and $_.GetSetMethod($true).IsPublic) }
            })
            methods = @($boundarySettingsType.GetMethods([Reflection.BindingFlags]'Public,NonPublic,Instance,Static,DeclaredOnly') | ForEach-Object {
                [pscustomobject]@{ name = $_.Name; public = $_.IsPublic; parameters = @($_.GetParameters() | ForEach-Object { $_.ParameterType.FullName }); return_type = $_.ReturnType.FullName }
            })
        }
    } else { $null }
    $datasetRelevantProperties = @($dataset.GetType().GetProperties([Reflection.BindingFlags]'Public,NonPublic,Instance') | Where-Object { $_.Name -match 'grain|boundar|map|setting' } | ForEach-Object { [pscustomobject]@{ name = $_.Name; type = $_.PropertyType.FullName } })
    $boundarySettingsReport = [pscustomobject]@{
        type = if ($null -ne $boundarySettings) { $boundarySettings.GetType().FullName } else { $null }
        values = if ($null -ne $boundarySettings) {
            @($boundarySettings.GetType().GetProperties([Reflection.BindingFlags]'Public,NonPublic,Instance') | ForEach-Object {
                $getter = $_.GetGetMethod($true)
                if ($null -ne $getter -and $getter.GetParameters().Count -eq 0) {
                    try { [pscustomobject]@{ name = $_.Name; value = $getter.Invoke($boundarySettings, $null) } } catch { }
                }
            })
        } else { @() }
    }

    $stage = 'populate_grain_sizing'
    $grainSizing = $dataset.GrainSizing
    if ($null -eq $grainSizing) { throw 'dataset_grain_sizing_null' }
    $grainSizingApi = @($grainSizing.GetType().GetProperties([Reflection.BindingFlags]'Public,NonPublic,Instance') | ForEach-Object {
        $getter = $_.GetGetMethod($true)
        if ($null -ne $getter -and $getter.GetParameters().Count -eq 0) {
            try {
                $propertyValue = $getter.Invoke($grainSizing, $null)
                [pscustomobject]@{ name = $_.Name; type = $_.PropertyType.FullName; value = if ($propertyValue -is [string] -or $propertyValue -is [ValueType]) { $propertyValue } elseif ($null -eq $propertyValue) { $null } else { $propertyValue.GetType().FullName } }
            } catch { }
        }
    })
    $grainSettings = $grainSizing.Settings
    $boundarySettings = $grainSettings.BoundaryMapSettings
    if ($null -eq $boundarySettings) { throw 'grain_sizing_boundary_settings_null' }
    if ($BoundaryThresholdAngleDegree -ge 0) {
        $thresholdProperty = $boundarySettings.GetType().GetProperty('ThresholdAngleDegree')
        if ($null -eq $thresholdProperty -or $null -eq $thresholdProperty.GetSetMethod($false)) {
            throw 'boundary_threshold_has_no_public_setter'
        }
        $thresholdProperty.SetValue($boundarySettings, [double]$BoundaryThresholdAngleDegree, $null)
        $appliedThreshold = [double]$thresholdProperty.GetValue($boundarySettings, $null)
        if ([Math]::Abs($appliedThreshold - $BoundaryThresholdAngleDegree) -gt 1e-9) {
            throw "boundary_threshold_readback_mismatch:requested=$BoundaryThresholdAngleDegree;actual=$appliedThreshold"
        }
    }
    $boundarySettingsReport = [pscustomobject]@{
        type = $boundarySettings.GetType().FullName
        values = @($boundarySettings.GetType().GetProperties([Reflection.BindingFlags]'Public,NonPublic,Instance') | ForEach-Object {
            $getter = $_.GetGetMethod($true)
            if ($null -ne $getter -and $getter.GetParameters().Count -eq 0) {
                try { [pscustomobject]@{ name = $_.Name; value = $getter.Invoke($boundarySettings, $null) } } catch { }
            }
        })
    }
    $grainSettingsValues = @($grainSettings.GetType().GetProperties([Reflection.BindingFlags]'Public,NonPublic,Instance') | ForEach-Object {
        $getter = $_.GetGetMethod($true)
        if ($null -ne $getter -and $getter.GetParameters().Count -eq 0) {
            try {
                $propertyValue = $getter.Invoke($grainSettings, $null)
                [pscustomobject]@{ name = $_.Name; type = $_.PropertyType.FullName; value = if ($null -eq $propertyValue) { $null } elseif ($propertyValue -is [string] -or $propertyValue -is [ValueType]) { $propertyValue.ToString() } else { $propertyValue.GetType().FullName } }
            } catch { }
        }
    })
    $grainSettingsInfo = @($grainSizing.SettingsInfo | ForEach-Object { [pscustomobject]@{ key = $_.Key; value = $_.Value } })
    $grainSizingMethods = @($grainSizing.GetType().GetMethods([Reflection.BindingFlags]'Public,NonPublic,Instance,DeclaredOnly') | ForEach-Object {
        [pscustomobject]@{ name = $_.Name; public = $_.IsPublic; parameters = @($_.GetParameters() | ForEach-Object { [pscustomobject]@{ name = $_.Name; type = $_.ParameterType.FullName } }); return_type = $_.ReturnType.FullName }
    })
    $userGrainDisplay = [Core.Ebsd.Infrastructure.UserSettings]::GrainSizingDisplaySettings
    $userGrainDisplayValues = @($userGrainDisplay.GetType().GetProperties([Reflection.BindingFlags]'Public,NonPublic,Instance') | ForEach-Object {
        $getter = $_.GetGetMethod($true)
        if ($null -ne $getter -and $getter.GetParameters().Count -eq 0) {
            try { [pscustomobject]@{ name = $_.Name; type = $_.PropertyType.FullName; value = $getter.Invoke($userGrainDisplay, $null) } } catch { }
        }
    })
    $grainMap = $grainSizing.GrainMap
    $grainList = $grainSizing.GrainList
    $grainMapType = if ($null -ne $grainMap) { $grainMap.GetType().FullName } else { $null }
    $grainListType = if ($null -ne $grainList) { $grainList.GetType().FullName } else { $null }
    $grainMapPopulatedBefore = if ($null -ne $grainMap) { $grainMap.IsPopulated } else { $null }
    $grainCountBefore = if ($null -ne $grainList) { $grainList.Count } else { 0 }
    $stage = 'populate_native_boundary_map'
    $boundaryMapCancellation = [Threading.CancellationTokenSource]::new()
    $boundaryMap.Populate($boundarySettings, $progress, $boundaryMapCancellation)
    $boundaryMapPopulated = $boundaryMap.IsPopulated
    $boundaryRight = @($boundaryMap.BoundaryRight)
    $boundaryBottom = @($boundaryMap.BoundaryBottom)
    if ($boundaryRight.Count -ne $dataset.PixelCount -or $boundaryBottom.Count -ne $dataset.PixelCount) {
        throw "boundary_map_data_count_mismatch:expected=$($dataset.PixelCount);right=$($boundaryRight.Count);bottom=$($boundaryBottom.Count)"
    }
    if (@($boundaryRight | Where-Object { $_ -notin 0, 1 }).Count -gt 0 -or
        @($boundaryBottom | Where-Object { $_ -notin 0, 1 }).Count -gt 0) {
        throw 'boundary_map_data_not_binary'
    }
    if ($BoundaryThresholdAngleDegree -ge 0 -and
        (@($boundaryRight | Where-Object { $_ -eq 1 }).Count -eq $dataset.PixelCount -or
         @($boundaryBottom | Where-Object { $_ -eq 1 }).Count -eq $dataset.PixelCount)) {
        throw 'boundary_threshold_probe_returned_all_edges'
    }
    $boundaryCsvExport = $null
    if (-not [string]::IsNullOrWhiteSpace($OutputBoundaryCsv)) {
        $boundaryCsvPath = [IO.Path]::GetFullPath($OutputBoundaryCsv)
        if ($boundaryCsvPath -eq $fullPath -or $boundaryCsvPath -eq $sourceCrc) { throw "boundary_output_must_not_replace_source:$boundaryCsvPath" }
        $boundaryCsvDirectory = [IO.Path]::GetDirectoryName($boundaryCsvPath)
        if (-not [IO.Directory]::Exists($boundaryCsvDirectory)) { [IO.Directory]::CreateDirectory($boundaryCsvDirectory) | Out-Null }
        $boundaryWriter = [IO.StreamWriter]::new($boundaryCsvPath, $false, [Text.UTF8Encoding]::new($true))
        try {
            $boundaryWriter.WriteLine('Index,BoundaryRight,BoundaryBottom')
            for ($recordIndex = 0; $recordIndex -lt $dataset.PixelCount; $recordIndex++) {
                $boundaryWriter.WriteLine($recordIndex.ToString([Globalization.CultureInfo]::InvariantCulture) + ',' +
                    [string]$boundaryRight[$recordIndex] + ',' + [string]$boundaryBottom[$recordIndex])
            }
        } finally { $boundaryWriter.Dispose() }
        $boundaryCsvExport = [pscustomobject]@{
            path = $boundaryCsvPath
            rows = $dataset.PixelCount
            right_boundary_count = @($boundaryRight | Where-Object { $_ -eq 1 }).Count
            bottom_boundary_count = @($boundaryBottom | Where-Object { $_ -eq 1 }).Count
            format = 'AZtec BoundaryMap.BoundaryRight/BoundaryBottom; CPR dataset index, x-fastest'
            sha256 = Get-Sha256Hex $boundaryCsvPath
        }
    }

    $stage = 'populate_native_grain_map'
    $grainMapCancellation = [Threading.CancellationTokenSource]::new()
    $grainMap.Populate($boundaryMap, $progress, $grainMapCancellation)
    $grainMapPopulatedAfter = $grainMap.IsPopulated
    $grainMapData = @($grainMap.Data)
    $grainCountAfter = if ($null -ne $grainList) { $grainList.Count } else { 0 }

    $stage = 'populate_native_grain_sizing'
    $grainSizing.Populate()
    $grainMapPopulatedAfter = if ($null -ne $grainMap) { $grainMap.IsPopulated } else { $null }
    # GrainList is materialized by GrainSizing.Populate(); do not retain the
    # pre-populate collection reference because the native object can replace it.
    $grainList = $grainSizing.GrainList
    $grainListType = if ($null -ne $grainList) { $grainList.GetType().FullName } else { $null }
    $grainCountAfter = if ($null -ne $grainList) { $grainList.Count } else { 0 }
    $grainMapData = if ($null -ne $grainMap) { @($grainMap.Data) } else { @() }
    $grainMapDataType = if ($null -ne $grainMap.Data) { $grainMap.Data.GetType().FullName } else { $null }
    # In this standalone host the map layer may finish materializing the
    # native crystallite list during its own PopulateSync call below. Keep
    # this pre-layer observation, but validate the list after that boundary.
    $grainCountAfterPreLayer = $grainCountAfter
    $grainStatsCsv = $null
    $grainCsvExport = $null
    if (-not [string]::IsNullOrWhiteSpace($OutputGrainCsv)) {
        if ($grainMapData.Count -ne $dataset.PixelCount) {
            throw "grain_map_data_count_mismatch:expected=$($dataset.PixelCount);actual=$($grainMapData.Count)"
        }
        $grainCsvPath = [IO.Path]::GetFullPath($OutputGrainCsv)
        if ($grainCsvPath -eq $fullPath -or $grainCsvPath -eq $sourceCrc) { throw "grain_output_must_not_replace_source:$grainCsvPath" }
        $grainCsvDirectory = [IO.Path]::GetDirectoryName($grainCsvPath)
        if (-not [IO.Directory]::Exists($grainCsvDirectory)) { [IO.Directory]::CreateDirectory($grainCsvDirectory) | Out-Null }
        $grainWriter = [IO.StreamWriter]::new($grainCsvPath, $false, [Text.UTF8Encoding]::new($true))
        try {
            $grainWriter.WriteLine('Index,GrainId')
            for ($recordIndex = 0; $recordIndex -lt $grainMapData.Count; $recordIndex++) {
                $grainId = [Convert]::ToString($grainMapData[$recordIndex], [Globalization.CultureInfo]::InvariantCulture)
                $grainWriter.WriteLine($recordIndex.ToString([Globalization.CultureInfo]::InvariantCulture) + ',' + $grainId)
            }
        } finally { $grainWriter.Dispose() }
        $grainCsvExport = [pscustomobject]@{
            path = $grainCsvPath
            rows = $grainMapData.Count
            unique_id_count = @($grainMapData | Sort-Object -Unique).Count
            format = 'AZtec GrainMap.Data; CPR dataset index, x-fastest'
            sha256 = Get-Sha256Hex $grainCsvPath
        }
    }

    $boundaryRuntimeProperties = @($boundaryMap.GetType().GetProperties([Reflection.BindingFlags]'Public,Instance') | ForEach-Object {
        $property = $_
        $getter = $property.GetGetMethod($false)
        $row = [ordered]@{ name = $property.Name; type = $property.PropertyType.FullName; readable = ($null -ne $getter) }
        if ($null -ne $getter -and $getter.GetParameters().Count -eq 0) {
            try {
                $value = $property.GetValue($boundaryMap, $null)
                $row.value_type = if ($null -ne $value) { $value.GetType().FullName } else { $null }
                $row.count = if ($null -ne $value -and $null -ne $value.PSObject.Properties['Count']) { [int]$value.Count } else { $null }
                if ($null -ne $value -and $null -ne $value.PSObject.Properties['Items']) {
                    $row.items_type = if ($null -ne $value.Items) { $value.Items.GetType().FullName } else { $null }
                    $row.items_count = if ($null -ne $value.Items) { [int]$value.Items.Count } else { $null }
                    $row.items_sample = @($value.Items | Select-Object -First 8)
                } elseif ($null -ne $value -and $value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
                    $row.sample = @($value | Select-Object -First 8)
                }
            } catch { $row.read_error = $_.Exception.GetBaseException().Message }
        }
        [pscustomobject]$row
    })

    $mapCollection = $dataset.Maps
    $mapItems = if ($null -ne $mapCollection) { @($mapCollection.Items) } else { @() }
    $mapRows = @($mapItems | ForEach-Object {
        $mapLayers = if ($null -ne $_.Layers) { @($_.Layers.Items) } else { @() }
        [pscustomobject]@{
            type = $_.GetType().FullName
            name = $_.Name
            is_populated = $_.IsPopulated
            layer_count = $mapLayers.Count
            layer_types = @($mapLayers | ForEach-Object { $_.GetType().FullName })
        }
    })
    $assembly = $grainMap.GetType().Assembly
    $boundaryInterface = $assembly.GetType('Core.Ebsd.Grains.IBoundaryMap', $false)
    $boundaryImplementations = @()
    $mapApi = @()
    foreach ($typeCandidate in $assembly.GetTypes()) {
        if ($null -ne $boundaryInterface -and $boundaryInterface.IsAssignableFrom($typeCandidate)) {
            $boundaryImplementations += [pscustomobject]@{
                type = $typeCandidate.FullName
                is_abstract = $typeCandidate.IsAbstract
                is_interface = $typeCandidate.IsInterface
                constructors = @($typeCandidate.GetConstructors([Reflection.BindingFlags]'Public,NonPublic,Instance') | ForEach-Object {
                    @($_.GetParameters() | ForEach-Object { $_.ParameterType.FullName })
                })
                methods = @($typeCandidate.GetMethods([Reflection.BindingFlags]'Public,NonPublic,Instance,DeclaredOnly') | ForEach-Object {
                    [pscustomobject]@{ name = $_.Name; parameters = @($_.GetParameters() | ForEach-Object { $_.ParameterType.FullName }); return_type = $_.ReturnType.FullName }
                })
                properties = @($typeCandidate.GetProperties([Reflection.BindingFlags]'Public,NonPublic,Instance,DeclaredOnly') | ForEach-Object {
                    [pscustomobject]@{ name = $_.Name; type = $_.PropertyType.FullName }
                })
            }
        }
        if ($typeCandidate.FullName -eq 'Core.Ebsd.EBSDMaps.Map') {
            $mapApi = @($typeCandidate.GetMethods([Reflection.BindingFlags]'Public,NonPublic,Instance,DeclaredOnly') | Where-Object { $_.Name -match 'populate|layer|boundary|grain' } | ForEach-Object {
                [pscustomobject]@{ name = $_.Name; is_public = $_.IsPublic; parameters = @($_.GetParameters() | ForEach-Object { [pscustomobject]@{ name = $_.Name; type = $_.ParameterType.FullName } }); return_type = $_.ReturnType.FullName }
            })
        }
    }
    $exportApiCandidates = @()
    foreach ($loadedAssembly in [AppDomain]::CurrentDomain.GetAssemblies()) {
        try { $loadedTypes = $loadedAssembly.GetTypes() }
        catch [Reflection.ReflectionTypeLoadException] { $loadedTypes = @($_.Exception.Types | Where-Object { $null -ne $_ }) }
        catch { continue }
        foreach ($candidateType in $loadedTypes | Where-Object { $_.FullName -match '(EBSDMaps|Map.*Legend|Legend|Export)' }) {
            foreach ($candidateMethod in $candidateType.GetMethods([Reflection.BindingFlags]'Public,Instance,Static,DeclaredOnly') | Where-Object { $_.Name -match 'Export|Save.*Data|Data.*Save' }) {
                $exportApiCandidates += [pscustomobject]@{
                    assembly = $loadedAssembly.GetName().Name
                    type = $candidateType.FullName
                    method = $candidateMethod.Name
                    parameters = @($candidateMethod.GetParameters() | ForEach-Object { [pscustomobject]@{ name = $_.Name; type = $_.ParameterType.FullName } })
                    return_type = $candidateMethod.ReturnType.FullName
                }
            }
        }
    }
    $populateSignatures = @($grainMap.GetType().GetMethods([Reflection.BindingFlags]'Public,NonPublic,Instance') |
        Where-Object { $_.Name -eq 'Populate' } | ForEach-Object {
            [pscustomobject]@{ type = $_.DeclaringType.FullName; parameters = @($_.GetParameters() | ForEach-Object { $_.ParameterType.FullName }) }
        })
    $spreadSpace = $grainSizing.DeviationAngleToMeanRad
    if ($null -eq $spreadSpace) { throw 'grain_spread_space_null_after_populate' }
    $spreadItems = @($spreadSpace.Items | ForEach-Object { if ($null -eq $_) { [double]::NaN } else { [double]$_ } })
    $spreadValid = @($spreadItems | Where-Object { -not [double]::IsNaN($_) -and -not [double]::IsInfinity($_) })

    $stage = 'build_gos_settings'
    $settings = [Core.Ebsd.EBSDMaps.MapLayerGrainOrientationSpreadSettings]::new()
    $available = @($settings.AvailableParameters | ForEach-Object { $_.ToString() })
    $requestedParameter = @($settings.AvailableParameters | Where-Object { $_.ToString() -eq $GosParameter } | Select-Object -First 1)
    if ($requestedParameter.Count -eq 0) { throw "gos_parameter_not_available:$GosParameter" }
    $settings.Parameter = $requestedParameter[0]
    if ($hasDisplayRange) {
        $dataLimits = $settings.DataLimitSettings
        if ($null -eq $dataLimits) { throw 'gos_data_limit_settings_null' }
        $limitTypeProperty = $dataLimits.GetType().GetProperty('DataLimitType')
        if ($null -eq $limitTypeProperty -or -not $limitTypeProperty.PropertyType.IsEnum) {
            throw 'gos_data_limit_type_enum_missing'
        }
        $dataLimits.DataLimitType = [Enum]::Parse($limitTypeProperty.PropertyType, 'UserDefined')
        $dataLimits.LowerLimit = $DisplayMin
        $dataLimits.UpperLimit = $DisplayMax
        if ($dataLimits.DataLimitType.ToString() -ne 'UserDefined' -or
            [double]$dataLimits.LowerLimit -ne $DisplayMin -or [double]$dataLimits.UpperLimit -ne $DisplayMax) {
            throw 'gos_display_range_settings_readback_mismatch'
        }
    }

    $stage = 'construct_gos_layer'
    $layer = $settings.GetMapLayer($dataset)
    if ($null -eq $layer) { throw 'gos_map_layer_returned_null' }
    $stage = 'attach_and_populate_gos_layer'
    $nativeMap = $dataset.CurrentMap
    if ($null -eq $nativeMap -and $mapItems.Count -gt 0) { $nativeMap = $mapItems[0] }
    if ($null -eq $nativeMap) { throw 'dataset_has_no_current_map' }
    $nativeMap.AddMapLayer($layer, $true)
    $nativeMap.PopulateSync()
    $populatedBefore = $layer.IsPopulated
    if (-not $populatedBefore) { $layer.Populate() }
    if ($hasDisplayRange) {
        $drawingLimits = $layer.LimitsForDrawing
        if ($null -eq $drawingLimits -or [double]$drawingLimits.Item1 -ne $DisplayMin -or
            [double]$drawingLimits.Item2 -ne $DisplayMax) {
            $rangeState=@{requested=@($DisplayMin,$DisplayMax);actual=$drawingLimits;is_populated=$layer.IsPopulated;values_null=($null -eq $layer.Values);values_count=$(if($null -ne $layer.Values){$layer.Values.Count}else{0});map_populated=$nativeMap.IsPopulated;mode=[string]$layer.Settings.DataLimitSettings.DataLimitType;lower=$layer.Settings.DataLimitSettings.LowerLimit;upper=$layer.Settings.DataLimitSettings.UpperLimit}
            throw ('gos_display_range_drawing_readback_mismatch:'+($rangeState|ConvertTo-Json -Compress))
        }
    }
    # Re-read after the native layer has completed population. GrainSizing can
    # replace its internal ParticleWithPhaseList during this operation.
    $grainList = $grainSizing.GrainList
    $grainListType = if ($null -ne $grainList) { $grainList.GetType().FullName } else { $null }
    $grainCountAfter = if ($null -ne $grainList) { $grainList.Count } else { 0 }
    if ($null -eq $grainList -or $grainCountAfter -le 0) {
        throw "grain_list_empty_after_map_layer_populate:pre_layer=$grainCountAfterPreLayer;map_data_count=$($grainMapData.Count)"
    }
    if ($grainMap.ObjectCount -gt 0 -and $grainCountAfter -ne $grainMap.ObjectCount) {
        throw "grain_list_object_count_mismatch:grain_list=$grainCountAfter;grain_map_objects=$($grainMap.ObjectCount)"
    }
    $grainItems = if ($null -ne $grainList.Items) { @($grainList.Items) } else { @($grainList) }
    if ($grainItems.Count -ne $grainCountAfter) {
        throw "grain_list_items_count_mismatch:list_count=$grainCountAfter;items_count=$($grainItems.Count)"
    }
    if ($grainMap.ObjectCount -gt 0 -and $grainItems.Count -ne $grainMap.ObjectCount) {
        throw "grain_list_items_object_count_mismatch:items_count=$($grainItems.Count);grain_map_objects=$($grainMap.ObjectCount)"
    }
    $grainStats = @()
    for ($grainIndex = 0; $grainIndex -lt $grainItems.Count; $grainIndex++) {
        $grain = $grainItems[$grainIndex]
        $meanRad = $grain.GrainOrientationSpreadRad
        $maxRad = $grain.MaximumOrientationSpreadRad
        $grainStats += [pscustomobject]@{
            GrainId = $grainIndex + 1
            PhaseId = $grain.PhaseID
            PixelArea = $grain.PixelArea
            MeanGosDegree = if ($null -eq $meanRad) { $null } else { ([double]$meanRad) * (180.0 / [Math]::PI) }
            MaxGosDegree = if ($null -eq $maxRad) { $null } else { ([double]$maxRad) * (180.0 / [Math]::PI) }
        }
    }
    if ($grainStats.Count -ne $grainMap.ObjectCount) {
        throw "grain_stats_count_mismatch:stats=$($grainStats.Count);grain_map_objects=$($grainMap.ObjectCount)"
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputGrainStatsCsv)) {
        $grainStatsPath = [IO.Path]::GetFullPath($OutputGrainStatsCsv)
        $grainStatsWriter = [IO.StreamWriter]::new($grainStatsPath, $false, [Text.UTF8Encoding]::new($true))
        try {
            $invariant = [Globalization.CultureInfo]::InvariantCulture
            $grainStatsWriter.WriteLine('GrainId,PhaseId,PixelArea,MeanGosDegree,MaxGosDegree')
            foreach ($row in $grainStats) {
                $meanText = if ($null -eq $row.MeanGosDegree) { '' } else { ([double]$row.MeanGosDegree).ToString('R', $invariant) }
                $maxText = if ($null -eq $row.MaxGosDegree) { '' } else { ([double]$row.MaxGosDegree).ToString('R', $invariant) }
                $grainStatsWriter.WriteLine(([string]$row.GrainId) + ',' + ([string]$row.PhaseId) + ',' + ([string]$row.PixelArea) + ',' + $meanText + ',' + $maxText)
            }
        } finally { $grainStatsWriter.Dispose() }
        $grainStatsCsv = [pscustomobject]@{
            path = $grainStatsPath
            rows = $grainStats.Count
            format = 'AZtec GrainSizing.GrainList ParticleWithPhase native orientation spread fields; radians converted to degrees'
            sha256 = (Get-Sha256Hex $grainStatsPath)
        }
    }
    $stage = 'read_value_space'
    $valueSpace = $layer.Values
    $numericItems = @()
    if ($null -ne $valueSpace) {
        $itemsProperty = $valueSpace.GetType().GetProperty('Items')
        if ($null -eq $itemsProperty) { throw "value_space_items_missing:$($valueSpace.GetType().FullName)" }
        $items = $itemsProperty.GetValue($valueSpace, $null)
        $numericItems = @($items | ForEach-Object { if ($null -eq $_) { [double]::NaN } else { [double]$_ } })
    }
    $exportSamples = @()
    if ($ProductionOutputDirectory) {
        [IO.Directory]::CreateDirectory($ProductionOutputDirectory) | Out-Null
        $currentCsv = Join-Path $ProductionOutputDirectory 'native_export_values.csv'
        if ([IO.File]::Exists($currentCsv)) { throw 'production_csv_already_exists' }
        $w = [IO.StreamWriter]::new($currentCsv,$false,[Text.UTF8Encoding]::new($true))
        try {
            $w.WriteLine('Index,Grain Orientation Spread'); $w.WriteLine(',()')
            for ($i=0;$i -lt $dataset.PixelCount;$i++) {
                $w.WriteLine($i.ToString([Globalization.CultureInfo]::InvariantCulture)+','+([double]$layer.Values.Items[$i]).ToString('R',[Globalization.CultureInfo]::InvariantCulture))
            }
        } finally { $w.Dispose() }
        # CSV is generated from this input and used only for audit comparisons.
        # Actual pixels remain the verified native float/GetPixel output.
        & (Join-Path $PSScriptRoot '../scripts/export_aztec_native_gos_pixels.ps1') `
            -Layer $layer -Dataset $dataset -GrainSizing $grainSizing -BoundaryMap $boundaryMap `
            -LegacyCsv $currentCsv -OutputDirectory $ProductionOutputDirectory `
            -LegacyDisplayMin ([double]$layer.LimitsForDrawing.Item1) -LegacyDisplayMax ([double]$layer.LimitsForDrawing.Item2) | Out-Null
    }
    # Optional display audit runs on the populated native objects; it does not
    # alter the verified grain calculation or the existing export path.
    if (-not [string]::IsNullOrWhiteSpace($PixelAuditOutputDirectory)) {
        & (Join-Path $PSScriptRoot '../scripts/export_aztec_native_gos_pixels.ps1') `
            -Layer $layer -Dataset $dataset -GrainSizing $grainSizing -BoundaryMap $boundaryMap `
            -LegacyCsv $PixelAuditLegacyCsv -OutputDirectory $PixelAuditOutputDirectory `
            -LegacyDisplayMin $PixelAuditDisplayMin -LegacyDisplayMax $PixelAuditDisplayMax | Out-Null
    }
    foreach ($recordIndex in @(0, 1, [Math]::Max(0, $dataset.PixelCount - 1))) {
        try {
            $exportSamples += [pscustomobject]@{
                record_index = $recordIndex
                value = $layer.GetStringForExport($recordIndex, [Globalization.CultureInfo]::InvariantCulture)
                error = $null
            }
        } catch { $exportSamples += [pscustomobject]@{ record_index = $recordIndex; value = $null; error = $_.Exception.Message } }
    }
    $csvExport = $null
    if (-not [string]::IsNullOrWhiteSpace($OutputCsv)) {
        $csvPath = [IO.Path]::GetFullPath($OutputCsv)
        $csvDirectory = [IO.Path]::GetDirectoryName($csvPath)
        if (-not [IO.Directory]::Exists($csvDirectory)) { [IO.Directory]::CreateDirectory($csvDirectory) | Out-Null }
        $writer = [IO.StreamWriter]::new($csvPath, $false, [Text.UTF8Encoding]::new($true))
        try {
            $writer.WriteLine('Index,Grain Orientation Spread')
            $writer.WriteLine(',()')
            for ($recordIndex = 0; $recordIndex -lt $dataset.PixelCount; $recordIndex++) {
                $value = $layer.GetStringForExport($recordIndex, [Globalization.CultureInfo]::InvariantCulture)
                $writer.WriteLine($recordIndex.ToString([Globalization.CultureInfo]::InvariantCulture) + ',' + $value)
            }
        } finally { $writer.Dispose() }
        $csvExport = [pscustomobject]@{
            path = $csvPath
            rows = $dataset.PixelCount
            format = 'AZtec MapLayerValueGrid.GetStringForExport; invariant culture; index/value only'
            sha256 = (Get-Sha256Hex $csvPath)
        }
    }
    $validityCsvExport = $null
    if (-not [string]::IsNullOrWhiteSpace($OutputValidityCsv)) {
        $validityPath = [IO.Path]::GetFullPath($OutputValidityCsv)
        $validityDirectory = [IO.Path]::GetDirectoryName($validityPath)
        if (-not [IO.Directory]::Exists($validityDirectory)) { [IO.Directory]::CreateDirectory($validityDirectory) | Out-Null }
        $validityWriter = [IO.StreamWriter]::new($validityPath, $false, [Text.UTF8Encoding]::new($true))
        $validCount = 0
        try {
            $validityWriter.WriteLine('Index,Valid')
            for ($recordIndex = 0; $recordIndex -lt $dataset.PixelCount; $recordIndex++) {
                $isValid = [bool]$layer.IsValid($recordIndex)
                if ($isValid) { $validCount++ }
                $validityWriter.WriteLine($recordIndex.ToString([Globalization.CultureInfo]::InvariantCulture) + ',' +
                    ([int]$isValid).ToString([Globalization.CultureInfo]::InvariantCulture))
            }
        } finally { $validityWriter.Dispose() }
        $validityCsvExport = [pscustomobject]@{
            path = $validityPath
            rows = $dataset.PixelCount
            valid_count = $validCount
            format = 'AZtec MapLayerGrainOrientationSpread.IsValid(recordIndex); CPR dataset index'
            sha256 = (Get-Sha256Hex $validityPath)
        }
    }
    $valid = @($numericItems | Where-Object { -not [double]::IsNaN($_) -and -not [double]::IsInfinity($_) })
    $hierarchy = @()
    $type = $layer.GetType()
    while ($null -ne $type) {
        $hierarchy += Get-MemberReport $type
        $type = $type.BaseType
    }
    $result = [pscustomobject]@{
        status = 'native_gos_map_layer_export_complete'
        source_cpr = $fullPath
        source_crc = $sourceCrc
        source_cpr_sha256 = $sourceCprHash
        source_crc_sha256 = $sourceCrcHash
        dataset_name = $dataset.Name
        width = $dataset.XCount
        height = $dataset.YCount
        point_count = $dataset.PixelCount
        csv_export = $csvExport
        validity_csv_export = $validityCsvExport
        parameter = $settings.Parameter.ToString()
        available_parameters = $available
        grain_sizing_type = $grainSizing.GetType().FullName
        grain_sizing_properties = $grainSizingApi
        grain_settings_values = $grainSettingsValues
        grain_settings_info = $grainSettingsInfo
        grain_sizing_methods = $grainSizingMethods
        user_grain_display_settings = $userGrainDisplayValues
        grain_map_type = $grainMapType
        grain_map_populated_before = $grainMapPopulatedBefore
        grain_map_populated_after = $grainMapPopulatedAfter
        boundary_map_populated_after = $boundaryMapPopulated
        grain_list_type = $grainListType
        grain_count_before = $grainCountBefore
        grain_count_after = $grainCountAfter
        grain_map_pixel_count = if ($null -ne $grainMap) { $grainMap.PixelCount } else { 0 }
        grain_map_object_count = if ($null -ne $grainMap) { $grainMap.ObjectCount } else { 0 }
        grain_map_data_type = $grainMapDataType
        grain_map_data_count = $grainMapData.Count
        grain_map_data_unique_id_count = @($grainMapData | Sort-Object -Unique).Count
        grain_map_data_samples = @($grainMapData | Select-Object -First 12)
        grain_csv_export = $grainCsvExport
        grain_stats_csv_export = $grainStatsCsv
        grain_stats_count = $grainStats.Count
        grain_stats_mean_finite_count = @($grainStats | Where-Object { $null -ne $_.MeanGosDegree }).Count
        grain_stats_max_finite_count = @($grainStats | Where-Object { $null -ne $_.MaxGosDegree }).Count
        boundary_csv_export = $boundaryCsvExport
        boundary_right_count = @($boundaryRight | Where-Object { $_ -eq 1 }).Count
        boundary_bottom_count = @($boundaryBottom | Where-Object { $_ -eq 1 }).Count
        boundary_data_count = $boundaryRight.Count
        grain_map_unique_ids = @($grainMapData | Sort-Object -Unique | Select-Object -First 12)
        grain_map_populate_signatures = $populateSignatures
        dataset_map_count = $mapItems.Count
        dataset_maps = $mapRows
        attached_map_name = $nativeMap.Name
        attached_map_populated = $nativeMap.IsPopulated
        boundary_map_interface_found = ($null -ne $boundaryInterface)
        boundary_map_implementations = $boundaryImplementations
        boundary_map_settings = $boundarySettingsReport
        boundary_map_settings_api = $boundarySettingsApi
        boundary_map_runtime_properties = $boundaryRuntimeProperties
        dataset_relevant_properties = $datasetRelevantProperties
        dataset_map_api = $mapApi
        native_export_api_candidates = @($exportApiCandidates | Select-Object -First 80)
        native_export_api_candidate_count = $exportApiCandidates.Count
        spread_space_type = $spreadSpace.GetType().FullName
        spread_space_count = $spreadSpace.Count
        spread_space_x_count = $spreadSpace.XCount
        spread_space_y_count = $spreadSpace.YCount
        spread_item_count = $spreadItems.Count
        spread_valid_count = $spreadValid.Count
        spread_min_native_units = if ($spreadValid.Count) { ($spreadValid | Measure-Object -Minimum).Minimum } else { $null }
        spread_max_native_units = if ($spreadValid.Count) { ($spreadValid | Measure-Object -Maximum).Maximum } else { $null }
        first_spread_values_native_units = @($spreadItems | Select-Object -First 12)
        populated_before = $populatedBefore
        populated_after = $layer.IsPopulated
        layer_type = $layer.GetType().FullName
        value_space_type = if ($null -ne $valueSpace) { $valueSpace.GetType().FullName } else { $null }
        value_space_count = if ($null -ne $valueSpace) { $valueSpace.Count } else { 0 }
        value_space_x_count = if ($null -ne $valueSpace) { $valueSpace.XCount } else { 0 }
        value_space_y_count = if ($null -ne $valueSpace) { $valueSpace.YCount } else { 0 }
        value_item_count = $numericItems.Count
        get_string_for_export_samples = $exportSamples
        valid_value_count = $valid.Count
        valid_value_min = if ($valid.Count) { ($valid | Measure-Object -Minimum).Minimum } else { $null }
        valid_value_max = if ($valid.Count) { ($valid | Measure-Object -Maximum).Maximum } else { $null }
        first_values_native_units = @($numericItems | Select-Object -First 12)
        layer_interfaces = @($layer.GetType().GetInterfaces() | ForEach-Object { $_.FullName })
        hierarchy = $hierarchy
    }
    if ((Get-Sha256Hex $fullPath) -ne $sourceCprHash -or (Get-Sha256Hex $sourceCrc) -ne $sourceCrcHash) {
        throw 'source_pair_hash_changed_during_export'
    }
    if ($SummaryOnly) {
        $summaryJson = $result | Select-Object status, source_cpr, source_crc, source_cpr_sha256, source_crc_sha256, dataset_name, width, height, point_count, csv_export, validity_csv_export, grain_csv_export, grain_stats_csv_export, grain_stats_count, grain_stats_mean_finite_count, grain_stats_max_finite_count, boundary_csv_export, boundary_data_count, boundary_right_count, boundary_bottom_count, parameter, grain_settings_values, grain_settings_info, boundary_map_settings, boundary_map_runtime_properties, grain_map_populated_after, grain_count_after, grain_map_object_count, grain_map_data_type, grain_map_data_count, grain_map_data_unique_id_count, grain_map_data_samples, spread_valid_count, value_space_count, value_item_count, valid_value_count, valid_value_min, valid_value_max, get_string_for_export_samples | ConvertTo-Json -Depth 8
        if ($SummaryBase64) {
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($summaryJson))
        } else {
            $summaryJson
        }
    } else {
        $result | ConvertTo-Json -Depth 12
    }
} catch {
    $chain = @()
    $exceptionDetails = @()
    $exception = $_.Exception
    while ($null -ne $exception) {
        $chain += ($exception.GetType().FullName + ': ' + $exception.Message)
        $exceptionDetails += [pscustomobject]@{
            type = $exception.GetType().FullName
            message = $exception.Message
            hresult = ('0x{0:X8}' -f $exception.HResult)
            file_name = if ($exception -is [System.IO.FileLoadException] -or $exception -is [System.IO.FileNotFoundException]) { $exception.FileName } else { $null }
            fusion_log = if ($exception -is [System.IO.FileLoadException]) { $exception.FusionLog } else { $null }
            stack_trace = $exception.StackTrace
        }
        $exception = $exception.InnerException
    }
    [pscustomobject]@{
        status = 'failed'
        stage = $stage
        exception_chain = $chain
        exception_details = $exceptionDetails
        script_stack = $_.ScriptStackTrace
        error_position = $_.InvocationInfo.PositionMessage
    } | ConvertTo-Json -Depth 5
    exit 2
} finally {
    if ($null -ne $project) {
        try { $project.Dispose() } catch { Write-Warning ("project_dispose: " + $_.Exception.Message) }
    }
}
