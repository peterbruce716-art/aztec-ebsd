# AZtec 原生 EXE/DLL 工具链与操作规范

## 包内容与运行环境

`../assets/aztec-native-toolchain` 保留公开包相对结构：`03_tools/aztec_exporter` 放主 EXE/DLL、源码和 worker；`03_tools/scripts` 放自有 helper、测试和诊断；`aztec_bmp_compare/p46_ipf_overlay` 放参数化的 BC 审计和兼容 IPF 合成依赖；`p47_baseline/P47BaselineMetrics.cs` 为独立 RGB 比较器。`../scripts/verify-toolchain.ps1` 校验 `toolchain-manifest.json` 中每个导出工具链文件的字节数、哈希与环境，并按技能根的 `runtime-manifest.json` 覆盖核心降噪脚本、技能入口和当前说明文档。清单核对是本地文件完整性检查，不是数字签名或来源认证。

不要拆走两个主二进制。不要把 vendor 程序集、原始 CPR/CRC、参考 BMP 或历史输出混入技能。原有 helper EXE 按已验收字节保留，`build.ps1 -IncludeDll` 只重建主 EXE/DLL，不重建 helper；不能假设旧 helper 源码与已验收二进制完全对应。

运行前确认：

- Windows x64，`C:\Program Files\PowerShell\7\pwsh.exe` 为稳定 PowerShell Core；主 EXE 固定调用该路径。
- Windows PowerShell Framework 宿主 `%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe`，.NET Framework 4.8；原生 worker 的**真实线程**必须为 STA，不能只检查 runspace 标签。
- 已授权 AZtec Crystal 5.1，本批实测版本 5.1.7829.1；生产代码固定安装根 `C:\Program Files\Oxford Instruments NanoAnalysis\AZtec`。其他版本/路径需先适配和重新验证，不能仅复制程序集或更新说明就视为兼容。

原生 MapExport 是厂商实现程序集上的版本绑定集成。早期 Dataset.RunBatch/GetBitmapForExport 无窗口探针失败不再代表当前 MapExport 不可用；同时不代表存在厂商支持的公共 SDK。

## 输入与图层合同

- 当前主入口接受本地规则网格、单 Dataset。CPR 字段顺序必须为 `3,4,5,6,7,8,10,11,12`，CRC 每点 25 字节，`xCells*yCells=NoOfPoints`，实际数量/长度由程序核验；不支持的模式应失败。
- IPF 输出实际为唯一保存的 BC + IPF + GrainBoundaries 复合图。缺失或多个候选时失败，不猜地图、不借其他样品的相、取向、百分比或范围。
- KAM profile 明确设置 Square、3×3、OnlyPeriphery=true、最大角 5°。GOS profile 明确以 10° boundary threshold 填充原生 grain map 并选择 Mean；输出文件称 GOS，原生标题为 OS。
- 标量 HeatMap、梯度、5 步、非反转；默认原生 Automatic 显示范围。可明确覆盖 KAM/GOS 的有限 min<max，地图与图例同步。显示范围不改变指标定义或晶粒分割。
- 输出 profile 使用固定的本地导出配置；具体地图尺寸、文化、页眉页脚和比例尺状态必须随当前运行记录，不能称为任意 AZtec GUI 导出选项均已实现。
- 同 schema/长度的不同 CRC 互换不能单靠几何发现。单输入可提供可信 `--expected-crc-sha256`；批量入口不接受这个单一哈希选项。来源配对另行验证。

## CLI、DLL 与范围

下例在 PowerShell 7 中运行，`$toolRoot` 指实际技能包根，所有输入使用获授权的绝对路径，输出尚不存在：

```powershell
$skillRoot = '<skill-root>'
$toolRoot = Join-Path $skillRoot 'assets/aztec-native-toolchain'
$exe = Join-Path $toolRoot '03_tools/aztec_exporter/AZtecBmpExporter.exe'
& $exe --input 'C:\path\sample.cpr' --output 'C:\path\new-native' --types ALL --template native-v1
& $exe --input-dir 'C:\path\inputs' --output 'C:\path\new-batch' --types ALL --template native-v1
```

批次只按顶层 CPR 顺序处理，每样品独立目录；`--types` 为 ALL 或 IPF,KAM,GOS 的选择。每阶段超时默认300秒（10–900），整任务默认1800秒（10–7200）。部分失败也应检查输出列表，不只看是否产生图片。

`--template` 可指向 JSON 文件，例如 `{"kam":{"min":0,"max":5},"gos":{"min":0,"max":10}}`。它只控制本 profile 支持的显示范围，不是完整 AZtec MapTemplate 文件。禁止为贴合参考而暗改计算阈值。

Framework C# 使用：

```csharp
var result = AZtecBmpExporter.AZtecBmpApi.Export(cprPath, newOutputDirectory, "ALL");
// 核对 ExitCode、Status、ImageStatuses、ImageErrors，并保留 ManifestPath / LogPath。
```

DLL 在同目录找 EXE 并通过子进程隔离；不能加载后绕过原生 STA worker。验证 DLL 的现成 helper 需通过独立 Framework STA 宿主运行。无控制台的 PowerShell 7 宿主中，优先用 .NET `ProcessStartInfo` 启动并显式重定向 stdout/stderr；`Start-Process -WindowStyle Hidden` 可能返回 `0xC0000142`，不能把该宿主错误误记为样品失败：

```powershell
$framework = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
& $framework -NoProfile -STA -File (Join-Path $toolRoot '03_tools/scripts/verify_aztec_native_dll.ps1') -InputPath 'C:\path\sample.cpr' -OutputDirectory 'C:\path\new-dll-test'
```

`frozen-v1` 仅复现旧兼容画布，它包含自有兼容绘制并可能生成/读取中间 CSV，不能标为完整原生 MapExport。当前任务默认 native-v1；没有用户明确选择不要改走 frozen、MTEX、Pillow、嵌入缩略图或 GUI。

## 保存完整性与重试

worker 对原生 BitmapForExport 保存前取 Bgr24 快照，调用原生 SaveAs 后以 OnLoad 解码 BMP，再核对宽高与 RGB SHA-256；编排复核 report、输入前后哈希及最终副本文件 SHA-256。

像素哈希：从上到下，每行 B/G/R 三字节，无行填充；不包括 BMP 头、DPI、alpha 或 padding。文件哈希与像素哈希作用不同，两者都应保存。`saved_pixels_match_native=true` 仅证明保存没有改变原生 RGB，不证明与参考一致。

worker 捕获异常可能只写 report/stdout，stderr 为空。重试分类优先 report，必要时 stdout，保留 stage、原始错误及诊断读取错误；仅明确 RegisterClassEx/WriteableBitmap/Geometry 初始化症状最多三次新目录、新 STA 子进程。真实 STA 条件错误、输入变化、像素不一致不重试。验收从 manifest 输出的 `native_report` 找成功尝试，不硬编码第一次目录。

`03_tools/scripts/test_aztec_native_retry.ps1 -OutputDirectory <新目录>` 为八项隔离 mock 行为测试，不运行厂商绘制。它验证错误分类、上限和恢复行为，不等于真实绘图验收。

## 严格参考比较与展示

生产导出不读参考图；独立比较时先确定是同一 CPR/CRC、相同尺寸和对应配置，不能为得分缩放/平移/替换原始像素。记录 reference/candidate 身份与哈希，完整画布、地图 ROI、地图外及图例分别报告精确相同数、不同像素数、MAE/RMSE。跨 CPR 差异同时包含数据与绘制差异，不能单独用于调渲染。

原生 IPF 边界重复绘制已直接出现黑/灰交点波动。遵循用户选择：保持原生绘制并严格报告，不能用容差称严格一致，也不能把所有历史差异未经定位一律归因为竞态。诊断串行稳定不等于历史 GUI 参考相同。BitmapForExport 有缓存，SaveAs 复用；本次已排除无依据的重复绘制解释。

打包验证器的适用范围：

| 文件 | 适用范围 |
| --- | --- |
| verify_aztec_native_dll.ps1 | 参数化单输入 DLL 三图及已有目录拒绝；Framework STA |
| probe_aztec_boundary_determinism.ps1/.cs | 唯一已保存BC/IPF/GB地图的重复边界诊断；非替代生产绘制 |
| P47BaselineMetrics.cs | 参数化两张BMP及ROI的独立RGB比较器；可用于新数据，但ROI须匹配 |

验证器只对当前包和当前输入负责。不要用历史固定结果放宽路径或哈希断言；新的展示应最近邻放大实际差异位置，标记放在图外，明确缩略预览与原尺寸严格判定的区别。

新样品可直接调用独立比较器。先把 `$candidate`、`$reference` 设为获授权的两张 BMP 绝对路径，再根据当前输出布局核验地图和图例的 ROI，赋值下列坐标与宽高；不能盲目套用旧样品 ROI。比较器要求尺寸一致，支持未压缩 24/32 位 BMP，只比较 RGB：

```powershell
Add-Type -Path (Join-Path $toolRoot 'aztec_bmp_compare/p47_baseline/P47BaselineMetrics.cs')
$mapMetrics = [AztecP47.BaselineMetrics]::Compare(
    $candidate, $reference, $mapX, $mapY, $mapWidth, $mapHeight)
$legendMetrics = [AztecP47.BaselineMetrics]::Compare(
    $candidate, $reference, $legendX, $legendY, $legendWidth, $legendHeight) |
    Where-Object Region -eq 'map_viewport'
$mapMetrics | Select-Object Region, Pixels, ExactPixels,
    @{Name='DifferentPixels';Expression={$_.Pixels-$_.ExactPixels}}, Mae, Rmse
$legendMetrics | Select-Object Region, Pixels, ExactPixels,
    @{Name='DifferentPixels';Expression={$_.Pixels-$_.ExactPixels}}, Mae, Rmse
```

第一次调用依次返回 `full_canvas`、`map_viewport`、`outside_map`；第二次选出的 `map_viewport` 对应该次传入的图例 ROI。`Pixels-ExactPixels` 是不同像素数。另行记录两张文件的 SHA-256，并保存比较参数和结果；该比较器不会修改图像。

保留 `NativeFullMapFidelity=not_accepted`，直到当前明确范围所有相关图像/设置均有严格证据支持。原生调用、nonblank、维度正确、保存完整性和单个样品0差异均不足以单独升级此状态。
