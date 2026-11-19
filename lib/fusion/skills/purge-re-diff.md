---
name: purge-re-diff
description: 版本对比与补丁分析：用 purge_bindiff 做函数级语义匹配，输出变更函数、常量增删、变更基本块与歧义项；区分「字节变化」「语义变化」「行为变化」。
---

# purge-re-diff —— 语义 bindiff

工具：`purge_bindiff`（本插件融合层）。输入两份函数快照，输出匹配表与变更列表。

## 1. 快照怎么来

每份快照：

```json
{"functions":[{
  "ea":"0x140001000","name":"sub_140001000","instructions":42,
  "mnemonics":{"mov":18,"lea":6,"call":4},
  "topology":["B0->B1","B1->B2","B1->B3"],
  "constants":["0x20","0x1f","0xedb88320"],
  "strings":["license.dat"],
  "call_degree":4,
  "blocks":[{"hash":"a1b2","start":"0x140001000","end":"0x140001020","insns":9}],
  "semantic_hash":"可选","bytes_hash":"可选","truncated":false
}]}
```

来源：任意反汇编器/自研解析器导出，或静态工具的函数摘要。**只导出摘要，不要塞整段反汇编**——匹配靠结构特征。

## 2. 调用

```
purge_bindiff left="C:\a\v1.json" right="C:\a\v2.json" threshold=0.62 limit=50
```

也接受直接传对象。返回：

- `summary`：`matched / changed / unchanged / unmatchedLeft / unmatchedRight / incomplete`
- `changes`：变更函数（含 `evidence.cfg`、`evidence.mnemonics`、`constantsAdded/Removed`、`changedBlocks`）
- `unmatchedLeft/Right`：只在一边出现的函数（新增或删除）
- `ambiguous`：margin < 0.05，说明存在多个同分候选，**不能当确定匹配**

## 3. 判读顺序

1. 先看 `incomplete`：为 true 说明有截断或候选裁剪，结论只能是「候选」。
2. 看 `unmatchedRight`：新增函数通常是补丁引入的校验/修复逻辑。
3. 看 `changes` 里 `ambiguous=false` 且 `score` 高的：这些是可信变更点。
4. 对每个变更函数读 `changedBlocks`：定位到具体基本块，再回静态工具看该块的反汇编。
5. 常量增删是强线索：新常量常是新校验的魔数/掩码。

## 4. 三层区分（报告必须写清）

| 层 | 证据 | 结论强度 |
|---|---|---|
| 字节变化 | `bytesChanged=true`、文件哈希不同 | 确定 |
| 语义变化 | `changed=true`（semantic_hash 不同）+ 结构证据 | 高（启发式） |
| 行为变化 | 动态观测到不同返回值/输出 | 需实测 |

字节没变但语义变了 = 依赖环境变了（重定位、外部配置），要单独说明。
语义变了但行为没变 = 等价重写或死代码改动，不要报成「功能变更」。

## 5. 纪律

- 匹配分数是**证据**，不是等价证明。不要写「完全一致」。
- 候选裁剪（`candidatePruned > 0`）时 margin 一律不可信，标 `ambiguous`。
- 同一函数在两边重复出现时可能被误配；用 `unmatched` 数量和名字核对。
- 报告里保留两份快照的 sha256，否则结论不可复现。
