---
name: purge-re-patch-sign
description: 二进制补丁与重签：定位校验函数、设计最小字节补丁、验证补丁前后行为、重算校验与重签（APK/PE/macOS）；保留原件与可回滚 diff。
---

# purge-re-patch-sign —— 补丁与重签

## 1. 先定补丁目标

把「要改什么」写成可验证断言，例如：

```
CHECK_FN @ 0xADDR 返回 eax=0 表示失败
目标: 失败分支不跳转
可验证: 同一输入下补丁前 exit=1，补丁后 exit=0，且其他功能不变
```

没有可验证断言的补丁不要写。

## 2. 定位校验点

1. 字符串 xref：`"invalid license"`、`"expired"`、`"trial"`、`"signature"`。
2. 分支形态：`test eax,eax; jz/jnz`、`cmp` + 条件跳转紧邻错误输出。
3. 交叉确认：同一函数被多处调用，改一处不够；要找共用判定点。
4. 反调试/完整性校验单独记录，不要和业务校验混成一个补丁。

## 3. 最小补丁

```
原件: OFFSET 原字节 PATCH_OLD  (记录 16 字节上下文)
补丁: OFFSET 新字节 PATCH_NEW
语义: jz -> jmp / nop 填充 / 返回值改为 1
副作用: 栈平衡、寄存器存活、后续分支依赖
```

- 优先改**判定**而不是改**返回值**：改返回值容易破坏调用者的其他假设。
- `nop` 填充要保持指令长度不变，避免错位。
- 每次只改一处，改完立刻验证；批量改无法定位回归。

## 4. 验证矩阵

| 用例 | 期望 |
|---|---|
| 合法输入 | 行为与原件一致（不能把正常功能弄坏） |
| 非法输入 | 补丁点行为改变，且不崩溃 |
| 边界输入 | 空/超长/异常编码不触发未定义行为 |
| 二次启动 | 无持久化副作用残留 |

「没崩」不算通过，要断言返回值/输出/文件副作用。

## 5. 重算校验与重签

**PE**
- 改字节后 `CheckSum` 失效：`0` 或重算（部分加载器不校验，但签名会失效）。
- Authenticode 签名必然失效：需要重签或去掉签名目录；重签用测试证书，保留原签名信息作证据。

**APK**
```
1. 改 dex/so/资源（保持 ZIP 条目对齐，zipalign -p 4）
2. 重签：apksigner sign --ks KEYSTORE --ks-pass pass:PASS out.apk
3. 验证：apksigner verify --print-certs out.apk
4. 记录：原证书 sha256 / 新证书 sha256 / v1-v2-v3 方案
```
- 换证书意味着与原包不同签名，覆盖安装会失败，属预期行为。
- v2/v3 签名覆盖整包字节，任何改动都要重签，不能只改 `META-INF`。

**macOS**
```
codesign --force --deep --sign - APP.app
codesign --verify --deep --strict APP.app
```

## 6. 交付与回滚

- 原件副本（不改动）、补丁脚本（可重放）、diff（十六进制上下文）、验证记录。
- 明确写：`patched=true / resigned=true / originalPreserved=true`。
- 失败或部分成功要写 `partial_commit` 与已改偏移，不能声称「已回滚」。
