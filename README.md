# HyperOS Google Passkey Router for SukiSU

Developer: **framelix**

- 模块 ID：`hypergpm-router`
- 版本：`0.2.0-alpha`
- 运行环境：SukiSU Ultra / KernelSU 风格 systemless 模块

## 这是什么

HyperOS Google Passkey Router for SukiSU 是一个面向中国大陆版 HyperOS 3 / 澎湃 OS 3 的实验性纯脚本模块。

它的目标是：当网站或 App 调用 Android Credential Manager 创建 passkey 时，尽量让系统优先走 Google Play services / Google Password Manager，而不是小米通行密钥管理器。

它**不是** passkey 破解工具，不会导出、伪造、窃取通行密钥，也不会绕过 Google 账号认证。它只尝试修复本机 provider 路由，而且只在 ROM 仍然接受 Android secure settings 的场景下有效。

## 背景

Android Credential Manager 会聚合设备上可用的 credential providers，包括密码管理器和 passkey provider。部分国行 HyperOS 构建会更倾向使用小米自己的通行密钥管理器，即使用户在设置里尝试切换 provider，创建 passkey 时仍可能被路由回小米侧。

本模块尝试从设置层修复这个路由，主要写入：

- `Settings.Secure.credential_service`
- `Settings.Secure.credential_service_primary`
- `Settings.Secure.autofill_service`

目标 provider 是 Google Play services 中的 Google Password Manager / passkey 服务。Credential Manager provider 和 Autofill service 会分开判断；默认保守模式不会无条件覆盖用户选择的第三方 Autofill。

## 功能

- 通过 Android `query-services` 精确发现当前用户可见的服务，并验证 service action 与 `BIND_CREDENTIAL_PROVIDER_SERVICE`；有预算的 package dump 只作兼容回退。
- 运行时检测 API、HyperOS 主版本、区域、用户解锁状态、GMS 状态、Credential Manager feature、provider 查询能力和 OEM hybrid 限制证据。
- 写入前生成可解释的 per-user route plan；Google provider 排在前面，同时保留合法第三方 Credential provider。
- Credential provider 与 Autofill 分开决策。保守模式只在 Autofill 为空、已经是 Google，或当前为 Xiaomi/MIUI Autofill 时切换到经过验证的 GMS Autofill。
- 重建 provider 列表时尽量过滤 Xiaomi / MIUI / FIDO 相关组件。
- 对每个 Android 用户分别应用设置，并在写入后逐键回读；临时 Binder 事务失败会有限重试，部分写入失败只回滚本次事务触及的键。
- Action 与开机 watchdog 使用互斥锁，避免同时发现 provider、备份和写设置时互相干扰。
- 开机最多应用一次，15 秒后只读验证一次；如果系统回写设置，只记录分类，不进行重试风暴。
- 提供 SukiSU Ultra 模块页 Action 按钮，可一键应用、查看状态、生成诊断报告并打开相关设置页面。
- Action 的 status、apply、report、open 是四个独立且有硬超时的进程；前一步失败不会拖死后一步。
- 诊断报告分为默认 `public` 和显式 `private`；每个 section 及报告总流程都有时间预算，公开报告自动过滤常见账号、网络、设备标识、宿主路径和 token 模式。
- 诊断报告保存到 `/data/adb/hypergpm-router/logs/`，最多保留最近 5 份。
- 首次写入时备份原始 secure settings。restore/卸载只恢复当前仍等于模块最后写入值的键，保留用户之后的新选择。

## 0.2.0-alpha 新增内容

相较于 `0.1.x`，此版本重点修复 Action 偶发出现 `Failed transaction`，以及 collecting report 长时间无响应的问题：

- Action 的状态检查、路由应用、报告采集和页面打开改为互相隔离的限时步骤，单步失败后仍会继续执行并输出总结。
- Binder transaction 异常采用有限重试，能够识别“返回码为 0 但输出包含失败信息”的情况；写入后逐键回读，异常时回滚本次事务。
- 报告采集具有 section 超时和 30 秒总预算，不依赖设备是否提供外部 `timeout` 命令。
- 新增 public/private 报告模式。默认 public 报告会过滤常见账号、IP、MAC、Android ID、本机路径和 token 模式。
- 新增 capability snapshot、只读 `plan`、三种兼容模式和 OEM 设置回写分类。
- 开机任务改为每次启动最多应用一次，随后只读验证，减少重复写入、耗电和与其他模块争用。
- restore 与卸载增加所有权判断，避免覆盖用户在模块运行后手动选择的新 provider。

## 安装

1. 确认设备已安装 Google Play services，并且 Google 账号、Google Password Manager 基本可用。
2. 在 SukiSU Ultra 或 KernelSU 风格模块管理器中安装模块 zip。
3. 重启设备。
4. 进入模块页面，点击 **Action** 一次。
5. 到系统的密码 / passkey / autofill 设置页检查 Google Password Manager 是否已被选中。

## Action 按钮会做什么

点击模块 Action 后会依次执行：

1. 显示能力与当前状态。
2. 使用默认能力模式应用 Google provider 路由。
3. 生成经过隐私过滤的 public 诊断报告。
4. 尝试打开 Android Credential Provider 设置页和 Google passkey 管理页面。

报告路径：

```text
/data/adb/hypergpm-router/logs/
```

报告可能包含公开设备型号、系统版本、provider 组件名、相关 secure settings 和经过筛选的 Credential Manager 日志。模块会自动进行基础脱敏，但公开上传或提交 issue 前仍应人工检查；模块不会自动上传报告。

## 手动命令

可以在 root shell 中执行：

```sh
su
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh status
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh plan
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh apply
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh apply force
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh report public
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh report private
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh open
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh restore
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh log
```

`plan` 只解释计划，不写设置。`apply force` 会显式覆盖兼容保护，也可能替换第三方 Autofill，仅用于主动测试。

如果 Action 第 2 步显示 `failed`，先查看 `log`。结构化事件会记录失败阶段、用户、尝试次数、返回码和短错误；`Failed transaction` 不会再阻止第 3、4 步继续执行。

## 兼容模式与配置

- `conservative`：OS3/API36 的默认模式；保留合法第三方 Credential provider，并避免无条件替换第三方 Autofill。
- `observe-only`：只检查和报告，不写设置；OS4 和 API37 在本版本中默认使用该模式。
- `force`：仅供用户明确测试，可能覆盖第三方 Autofill。

可选持久配置文件：

```text
/data/adb/hypergpm-router/conf/policy.conf
```

示例：

```ini
mode=conservative
manage_autofill=auto
```

`mode` 支持 `observe-only`、`conservative`、`force`；`manage_autofill` 支持 `auto`、`true`、`false`。未知值和重复键不会执行为 shell 代码，并会回退到能力检测结果。

## 恢复与卸载

首次成功 apply 时，模块会备份以下原始值：

- `credential_service`
- `credential_service_primary`
- `autofill_service`

手动恢复：

```sh
su
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh restore
```

卸载模块时，`uninstall.sh` 也会进行相同恢复。若某个键已被用户或其他模块修改，HyperGPM 会记录 `skipped_user_changed` 并保留当前值。

## 支持状态

`0.2.0-alpha` 的核心目标是 HyperOS 3 / Android 16（API 36）。Xiaomi 15 与 REDMI K80 类合成 fixtures 已通过，但在完成最终 zip 的真机端到端测试前，不标记任何机型为 `verified`。Xiaomi 14、REDMI K70 升级机型仍为 planned。

OS4 或 API37 在本阶段默认 `observe-only`，不会自动写设置，也不属于本版本的支持声明。

## 已知限制

这是一个设置层路由修复模块，不是 `system_server` hook。

如果 HyperOS 在更深层强制 OEM hybrid credential service，单纯写 secure settings 可能不够。若日志里出现类似内容，通常说明问题可能超出本模块能力范围：

```text
Remote entry being dropped as it is not from the service configured by the OEM
Remote entry being dropped as it does not meet the restriction checks
TYPE_NO_CREATE_OPTIONS
```

这种情况可能需要 LSPosed / Xposed / Zygisk / KPM / native hook 等更深层方案。

另外，如果已经能打开 Google 的 **Create a passkey for your Google Account** 页面，但保存时出现：

```text
We weren't able to save your changes
```

那不一定是 provider 路由问题，可能和旧 passkey 冲突、Google 账号风控、Keystore 状态、TrickyStore 干扰或 Google Password Manager 状态有关。

## 与 HyperPasskey 的关系

HyperPasskey 是一个通过 Xposed / LSPosed hook 修复 HyperOS passkey 行为的项目，作用层级更深。

本模块定位更轻量：

| 项目 | 实现层级 | 能力边界 |
| --- | --- | --- |
| HyperPasskey | Xposed / LSPosed hook | 可以 hook 更深层的 HyperOS / `system_server` passkey 路由逻辑。 |
| HyperOS Google Passkey Router for SukiSU | shell + secure settings + 开机重应用 | 主要修复 provider 设置层路由，不直接 hook Java / system_server。 |

建议把本模块作为轻量优先尝试。如果 ROM 不接受设置层路由，再考虑 hook 型方案。

## 项目结构

```text
.
├── module.prop
├── customize.sh
├── service.sh
├── boot-completed.sh
├── post-fs-data.sh
├── action.sh
├── uninstall.sh
├── common.sh
├── bin/
│   ├── hypergpmctl.sh
│   └── watchdog.sh
├── skip_mount
├── README.md
├── CHANGELOG.md
└── LICENSE
```

## 参考

- [KernelSU module guide](https://kernelsu.org/guide/module.html)
- [Android Credential Manager provider documentation](https://developer.android.com/identity/sign-in/credential-provider)
- [Android CredentialProviderService API reference](https://developer.android.com/reference/android/service/credentials/CredentialProviderService)
- [Credential Manager troubleshooting](https://developer.android.com/identity/sign-in/credential-manager-troubleshooting-guide)
- [AOSP Android 16 Settings.Secure credential settings](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android16-release/core/java/android/provider/Settings.java)
- [AOSP Android 16 CredentialManagerService](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android16-release/services/credentials/java/com/android/server/credentials/CredentialManagerService.java)
- [Chromium GPM provider component definition](https://chromium.googlesource.com/chromium/src/+/main/components/webauthn/android/java/src/org/chromium/components/webauthn/CredManHelper.java)
- [HyperPasskey](https://github.com/Howard20181/HyperPasskey)
- [KeePassDX issue: Xiaomi passkey provider behavior](https://github.com/Kunzisoft/KeePassDX/issues/2220)

## 开源许可

本项目使用 [MIT License](LICENSE) 开源。

## 免责声明

这是 `0.2.0-alpha` 实验模块，面向愿意自行排障的高级用户。它会以 root 权限写入 Android secure settings，不同 HyperOS 构建的行为可能不同。发布 issue 时请先检查诊断报告；如果 ROM 拒绝该路由，请使用 restore 或卸载模块恢复原设置。
