# AZtec 原生地图导出器

本目录包含主导出器 EXE 和 DLL。请保留仓库目录结构、脚本和 helper 工具；这些二进制不是独立程序，也不包含 Oxford Instruments 运行时。

使用 PowerShell 7 构建并验证工具链后再处理数据：

```powershell
$skillRoot = (Resolve-Path 'C:\path\to\aztec-ebsd').Path
& (Join-Path $skillRoot 'scripts/build-toolchain.ps1')
& (Join-Path $skillRoot 'scripts/verify-toolchain.ps1') -SkipEnvironment
$exe = Join-Path $skillRoot 'assets/aztec-native-toolchain/03_tools/aztec_exporter/AZtecBmpExporter.exe'
& $exe --input 'D:\data\map.cpr' --output 'D:\results\native-map' --types ALL --template native-v1
```

CPR 必须有匹配 CRC，输出目录必须是新的。原生执行需单独安装且获授权的 AZtec Crystal，以及工具链说明中列出的 .NET Framework/STA 前置条件。

DLL 暴露 `AZtecBmpExporter.AZtecBmpApi.Export`，并将原生 worker 隔离到子进程。核对返回的退出码、状态、各图状态与错误、manifest 路径和日志路径。

`native-v1` 调用已安装软件的原生 MapExport。`frozen-v1` 为兼容渲染器，不得称为原生 MapExport。两者都不代表与所有 AZtec 配置普遍等同。本包保留 `NativeFullMapFidelity=not_accepted`。详见[工具链说明](../../../../references/aztec-native-toolchain.md)。
