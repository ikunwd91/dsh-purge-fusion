---
name: purge-apk-audit
description: APK 静态审计：用 purge_apk_audit 拿包名/组件/权限/签名/能力调用点/嵌套载荷，再按线索回到 dex 与 native 层验证；证书只识别不验证，能力命中是线索不是判定。
---

# purge-apk-audit —— APK 静态审计

工具：`purge_apk_audit`（审计）、`purge_apk_result`（分节读取）。全程不执行样本、不联网。

## 1. 一次跑完

```
purge_apk_audit path="C:\samples\APP.apk"
```

返回要点：

- `file`：sha256 / size（后续所有结论绑定这个哈希）
- `overview`：package、versionName/Code、min/target SDK、dex 数、类/方法数、native ABI、权限数、组件数、证书指纹、指标计数
- `manifest`：导出组件（含是否带 permission）、`debuggable`、`allowBackup`、`usesCleartextTraffic`、异常
- `permissions`：声明权限，dangerous 单列
- `signatures`：证书 sha256 / subject / flags（`android-debug-key`、`expired`、`unparseable`）+ v1/v2/v3 结构
- `dex`：每个 `classes*.dex` 的类/方法/字符串数、`checksumOk`/`signatureOk`
- `capabilities`：规则命中（含 `appCount` 与库内命中区分）、组合链（`chains`）、声明了但没代码（`declaredWithoutCode`）、用了但没声明（`usedWithoutPermission`）
- `indicators`：按 high/medium/low 排好的线索列表
- `nestedPayloads` / `highEntropyAssets`：伪装扩展名、嵌套 dex/so、高熵未知格式
- `obfuscation`：短类名/短方法名比例
- `limitsHit` / `notRun`：本次没做到的部分

## 2. 判读顺序（别一上来就看 indicators）

1. **签名**：debug key / 过期 / 多证书 / 只有 v1 —— 决定这个包能不能当「正式发布包」看。
2. **manifest**：`debuggable=true`、`allowBackup=true`、导出且无权限保护的组件、`usesCleartextTraffic`。
3. **权限 vs 代码**：`usedWithoutPermission`（代码用了敏感 API 但没声明，常见于动态申请或反射）与 `declaredWithoutCode`（声明了但没用，常见于 SDK 冗余）。
4. **能力链**：`chains` 是「同类里多个 API 同时出现」的组合，比单条规则更有指向性；`libraryOnly=true` 的链来自系统/三方库，先排除。
5. **载荷**：`nestedPayloads` 里 `disguised=true`（扩展名与内容不符）优先级最高；高熵资产按大小和引用位置排。
6. **混淆**：短名比例 > 50% 时，类名/方法名不可作为语义依据，只能靠调用点与字符串。

## 3. 深挖路径

```
purge_apk_result result_id=UUID select=capabilities.rules     # 全部规则命中与样例调用点
purge_apk_result result_id=UUID select=classes                # 应用类按强度排序（前 200）
purge_apk_result result_id=UUID select=strings                # 有趣字符串（URL/IP/路径/密钥字样）
purge_apk_result result_id=UUID select=nestedPayloads         # 嵌套载荷清单
```

- 拿到 `类 + 方法 + 目标 API` 三元组后，回到 dex 反汇编（baksmali/jadx 等价流程）确认调用上下文：是否在真实业务路径上，还是死代码/SDK。
- `lib/<abi>/*.so` 需要单独走 ELF 分析（`purge-re-triage` → `purge-re-deep-dive`），本工具不分析 native。
- `resources.arsc` 未解码：字符串资源里的域名/密钥需另行解包。

## 4. 结论口径

- 能力命中 = 「代码具备该能力」，不等于「实际做了该行为」。必须给调用点，并按 `library` 标记排除三方库。
- 证书只做识别，不做签名验证：不要写「签名有效」，只能写「证书指纹 + 结构 + 标记」。
- 高熵资产 = 加密或压缩的候选，不是「恶意载荷」。
- `limitsHit` 非空时，结论标 `partial`。

## 5. 常见误判

| 现象 | 正确解读 |
|---|---|
| `signature.aosp-subject` | 主体字符串可伪造，必须比对真实平台密钥指纹 |
| `app.cleartext` | 只是允许明文，不等于实际明文传输 |
| `manifest.exported-unprotected` | 导出但可能靠运行时校验，需看代码 |
| `code.obfuscated` | 短名也可能来自代码压缩工具，不是恶意 |
| `dex.integrity` 失败 | 可能被二次打包/加固，先确认是否为加固壳 |
