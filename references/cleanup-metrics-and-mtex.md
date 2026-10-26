# 数据清理、指标与 MTEX 的适用边界

## 清理与持久化

当前用户的默认清理采用已验证的本地配方 `local-cleanup-v1`，使用本技能`scripts/native-cleanup/run_aztec_native_cleanup.ps1`；名称仅标识文档配方，不是 CLI 参数。其他任务须依据当前输入和目标明确配方与参数，不将本地设置视为材料无关的通用默认。纯导出保持CPR/CRC字节不变。配方与验证范围见[AZtec原生降噪](aztec-native-cleanup.md)：8→1每级最多50次原生迭代，完整阶梯最多100趟、零解不再下降时停止；先独立执行一次 Wild Spike Removal 并固定 `FourPixels`，使≤4 pixels 的小连通晶粒进入原生候选判据；然后Auto Clean五次，其序列内的 WildSpikeRemoval 同样为 `FourPixels`；最后Quadrants/radius3 Kuwahara。伪对称删除已按用户决定排除。5次Auto Clean每次须传递上次原生IDataset结果。

使用版本绑定的原生接口保存派生CPR，并在独立进程读回。四元数与Euler均须审核，不能只看零解计数。默认NativeSave保留原生Euler，临时滤波四元数不一定全部持久化；FilteredQuaternion显式提交滤波四元数，两种保存状态须独立命名，不能把前者称为完整滤波取向保存。详见降噪规范的保存策略。原生临时数据质量数组与最终保留的采集质量字段须分别记录。修改掩码不等于donor来源，后者未暴露，不得声称补点是实测。当前新入口优先于旧工作区pipeline及历史渲染器。独立验收通过后才调用当前MapExport。

## 数值与图像分别验收

KAM：报告对称性、邻域、有效点/同相规则、最大角、边缘策略、分母。当前原生导出 profile 明确为 square 3×3 periphery、5°；不能用 MTEX 一阶默认邻域暗中替换。

GOS：报告晶粒重构阈值/边界规则、相、mean/maximum统计、有效掩码。当前导出 profile 10°/Mean 是显式本地配置，不能称所有输入保存设置。显示 min/max 与晶粒分割及 Mean/Maximum 不是同一个参数。

原生 API 数值表须与同一 CPR/CRC 及同一 row-major点索引对应；匹配有效掩码后报告 MAE、分位误差、最大误差。数值相同不证明插值、色标、晶界、文字或完整画布相同；跨不同数据状态的图像误差也不能证明计算实现出错。

## MTEX 分析

本包未提供通用可运行的 MTEX 处理入口，也不包含历史工作区的 MTEX runner。用户明确需要 MTEX 分析、算法对照或近似绘制时，先确认本机 MATLAB/MTEX 安装和当前版本，使用该版本官方 help 核实可用读取器、函数签名及参数，再读取当前工程坐标/相对称性设置，并为本次输入编写和验证独立脚本。记录输入身份、相/坐标约定、有效点与补点掩码、邻域、角度和晶粒重构设置及输出路径；不要将历史脚本路径当作包内已验证入口。历史安装 R2025a/MTEX5.11.2、Bunge、xAxisDirection=north、zAxisDirection=outOfPlane 只是工作区记录，不能无检查套用新数据。

先验证当前读取器是否支持该输入；CPR/CRC 可直接导入时不引入无必要 CTF 中间件，需转换时必须核对相、坐标、点序和取向身份。MTEX 的 KAM、GOS、calcGrains、Kuwahara 与 AZtec 的配置/算法不同，必须独立命名并说明参数。近似绘制标为 approximate_aztec_style，不能标原生全图，也不进入当前原生EXE/DLL默认生产路线。

保留 GOS、KAM、LAGB/HAGB、IPF 与 recrystallized-like fraction 的独立含义。GOS<2°或低KAM均不能单独确证完全再结晶或 CDRX/DDRX。
