# AZtec 原生 EXE/DLL 工具链

本包包含主导出器 EXE、DLL 和两个 helper 程序。路径及对应源码见 [BINARY-DISTRIBUTION.md](../BINARY-DISTRIBUTION.md) 与 `assets/aztec-native-toolchain/toolchain-manifest.json`。DLL 会查找同目录的 EXE，并通过子进程隔离原生工作；请保留完整目录结构。

## 支持环境

原生执行要求 x64 Windows、PowerShell 7、.NET Framework 4.8、Windows PowerShell Framework STA worker，以及单独安装且已获授权的 AZtec Crystal 5.1.7829.1。当前脚本默认查找以下 AZtec 安装目录：

```text
C:\Program Files\Oxford Instruments NanoAnalysis\AZtec
```

不随包发布厂商程序集、AZtec 应用程序、CPR/CRC 数据或参考图。其他软件版本或安装位置需要适配脚本并重新验证。

## EXE 导出

对已保存的 CPR 及匹配 CRC，使用新输出目录：

```powershell
$skillRoot = (Resolve-Path 'C:\path\to\aztec-ebsd').Path
$toolRoot = Join-Path $skillRoot 'assets/aztec-native-toolchain'
$exe = Join-Path $toolRoot '03_tools/aztec_exporter/AZtecBmpExporter.exe'
& $exe --input 'D:\data\map.cpr' --output 'D:\results\native-map' --types ALL --template native-v1
```

批处理会按顶层 CPR 顺序处理，并为每个输入创建独立结果目录：

```powershell
& $exe --input-dir 'D:\data\maps' --output 'D:\results\native-batch' --types ALL --template native-v1
```

`--types` 支持 `ALL` 或 `IPF,KAM,GOS`。单阶段超时默认300秒，整任务默认1800秒，均可通过 CLI 参数调整。可传入 JSON 文件指定受支持的 KAM/GOS 显示范围；它不是完整 AZtec map-template 文件。检查生成 manifest 中的输入配对、状态和各图结果，不能只看进程退出码。

## DLL 与 helper

C# 可通过以下接口调用 DLL：

```csharp
var result = AZtecBmpExporter.AZtecBmpApi.Export(cprPath, newOutputDirectory, "ALL");
// 核对 ExitCode、Status、ImageStatuses、ImageErrors，并保留 ManifestPath / LogPath。
```

DLL 不包含或重新分发 Oxford 运行时。helper 程序用于验证和诊断；通过 Windows PowerShell Framework STA 宿主运行 `verify_aztec_native_dll.ps1`，不要在 PowerShell Core 中直接加载厂商 Framework 引用。

`native-v1` 调用已安装软件的原生 MapExport。它与 `frozen-v1` 兼容画布模式不同；后者不能称为原生 MapExport。两个模式均不能证明对所有 AZtec 配置的通用等同性。

## 完整性与图像等同性

原生绘制与所有可能的参考图完整一致尚未验证，必须保留 `NativeFullMapFidelity=not_accepted`。只有 CPR/CRC 身份、地图配置、尺寸、坐标布局和显示设置均可比时，才比较参考图；报告实际差异，不能用容差把结果标记为完全相同。

manifest 记录哈希和文件长度，仅用于本地完整性校验，不是数字签名。`verify-toolchain.ps1` 检查工具链文件和环境；`tests/smoke.ps1` 使用合成或 mock 输入，不验证真实 EBSD 数据的科学有效性。
