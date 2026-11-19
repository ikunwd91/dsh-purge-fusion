---
name: purge-re-unpack
description: 脱壳与自解压：判定壳类型、定位 OEP、dump 内存镜像、修复导入表与重定位、验证脱壳结果可静态分析；含 UPX/ASPack/Themida 类保护的分层处理与失败判据。
---

# purge-re-unpack —— 脱壳

## 1. 先判壳，再动手

| 特征 | 判读 |
|---|---|
| `.text` 熵 > 7.2，节名 `UPX0/UPX1`、`.aspack`、`.themida` | 已知壳，先试官方脱壳器 |
| 节表异常：`VirtualSize >> RawSize`、节名乱码/空 | 自研或改过的壳 |
| 导入表只有 `LoadLibraryA/GetProcAddress/VirtualAlloc/VirtualProtect` | 运行期解析 API |
| 入口处 `pushad/pushfd`、`popad`、`jmp` 到高地址 | 经典壳跳板 |
| TLS 回调存在且代码在可疑节 | 壳在 TLS 里先跑 |

**先记录再脱**：原始 sha256、节表、入口字节、熵表。脱壳产物是新样本，哈希必然不同，两者都要留档。

## 2. 定位 OEP 的三条路

1. **栈平衡法**：`pushad` 之后下硬件断点（`dr0=esp`）或对 `esp` 下内存访问断点，命中在 `popad` 附近，单步跟到跳向原入口。
2. **区段法**：壳解密后会在原代码节写入并 `mprotect/VirtualProtect` 改属性；对目标节下写入断点，命中后跟到控制流转移。
3. **内存扫描法**：跑到壳 stub 末尾，扫内存里出现完整 PE 头（`MZ`+`PE\0\0`）的区域，取 `AddressOfEntryPoint`。

命中判据：OEP 处应当是编译器生成的函数序言（`push rbp/mov rbp,rsp` 或 `sub rsp,XX`），且附近有正常导入调用。**只有「像入口」不算，要有调用链证据。**

## 3. dump 与修复

```
1. dump 目标模块内存镜像（按 SizeOfImage，不是文件大小）
2. 修正节对齐：RawOffset/RawSize 与 VirtualAddress/VirtualSize 对齐到 FileAlignment/SectionAlignment
3. 重建导入表：扫描 IAT 槽位 → 反查模块导出 → 生成新的导入目录；解析不到的槽标 UNRESOLVED 并列出
4. 重定位：ASLR 开启时保留或重建 .reloc；丢弃会导致加载失败
5. 校验：重新载入 → 静态工具能识别函数边界 → 关键字符串/常量落在预期位置
```

- 修复后必须验证：函数数、导入数、入口能否被静态识别。**「能打开」不等于「修复正确」**。
- IAT 有未解析槽时如实记录，不能伪造模块名。

## 4. 分层保护（VMP / Themida 类）

- 先区分「壳」与「虚拟机保护」：出现 handler 表、字节码解释循环、`push reg; ... ; ret` 式分派 → 是 VM 保护，脱壳只能拿到 VM 入口，不是原始逻辑。
- 处理策略：定位 VM 入口 → 提取 handler 表 → 建立字节码到 handler 的映射 → 只对有界函数做语义重建。
- 交付时明确写：`wholeBinaryVerified=false`、`vmLayers=N`、哪些函数已还原、哪些仍是字节码。

## 5. 失败判据（命中任一条就停下报告，不要硬猜）

- OEP 候选处没有合法序言且后续调用全是壳内部地址。
- dump 后导入表修复率 < 60%。
- 重定位被抹且无法重建（加载即崩）。
- 出现反调试：`IsDebuggerPresent`、`NtQueryInformationProcess`、`rdtsc` 计时、`int 3` 陷阱、父进程检查。

反调试/反虚拟机处理属本地实验范畴：记录检测点地址与触发条件，用最小补丁或环境调整绕过，**不改样本原件的证据链**（保留原文件与补丁 diff）。
