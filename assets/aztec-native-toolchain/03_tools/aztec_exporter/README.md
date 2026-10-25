# AZtec 原生整图 EXE / DLL

当前入口是本目录的 `AZtecBmpExporter.exe` 和 `AZtecBmpExporter.dll`。它们依赖本目录脚本、工作区 `03_tools/scripts` 中的既有辅助程序、本机 PowerShell 7 和已授权的 AZtec Crystal 5.1 安装，不能只取两个二进制文件独立部署。DLL 使用子进程隔离调用同目录 EXE。

在工作区根目录的 PowerShell 7 中构建并导出到一个尚不存在的目录：

```powershell
& .\03_tools\aztec_exporter\build.ps1 -IncludeDll
& .\AZtecBmpExporter.exe --input 'C:\path\sample.cpr' --output 'C:\path\new-native-export' --types ALL --template native-v1
```

`native-v1` 是默认模式，通过原生 MapExport 绘制完整地图、图例、文字及晶界。`frozen-v1` 用于复现之前的兼容画布。自定义 JSON 模板支持 `kam.min/max` 与 `gos.min/max`，显示范围同时作用于原生地图和图例。

```csharp
var result = AZtecBmpExporter.AZtecBmpApi.Export(cprPath, newOutputDirectory, "ALL");
// 检查 ExitCode、Status、ImageStatuses，并保留 ManifestPath / LogPath。
```

原生子进程必须使用 .NET Framework / STA；这是厂商 WPF 程序集的运行条件。主编排仍使用 PowerShell 7。不要在 PowerShell Core 内用 Add-Type 编译引用该 Framework DLL 的临时 C# 测试宿主；既有 `verify_aztec_native_dll.ps1` 应通过 Windows PowerShell Framework 子进程运行。

每个成功原生输出包含文件 `sha256` 及 `pixel_sha256`。后者是从上到下、行内 BGR 三字节、无行填充的 Bgr24 像素 SHA-256，不包含 BMP 头、DPI、填充或 alpha。worker 会核对原生 BitmapForExport 与落盘后重新解码位图的 RGB；编排再核对最终文件副本哈希。不同运行的像素哈希不同仍需逐像素定位，不能仅凭哈希判断差异大小。

完整历史参考等同性仍为 `NativeFullMapFidelity=not_accepted`。原生 IPF 的边界绘制已直接复现黑/灰交点的并行覆盖波动；当前保留厂商原生行为。原生调用、成功导出或保存像素一致均不等于已与所有参考图完全一致。生产阶段不读取参考 BMP，不修改输入 CPR/CRC，不启动 AZtec GUI 或网络服务。
