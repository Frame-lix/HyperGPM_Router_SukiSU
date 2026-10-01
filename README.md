# HyperOS Google Passkey Router for SukiSU

Developer: **framelix**

- 模块 ID：`hypergpm-router`
- 版本：`1.0.0`
- 运行环境：SukiSU Ultra / KernelSU 风格 systemless 模块

## 当前版本：1.0.0

本次为 1.0 正式版，以保留正常功能、兼容保护和恢复能力为前提：

- **精简重复工作**：合并设置读写重试、报告采集与字段解析；复用同次状态查询的服务发现结果；成功读取不再逐次写日志，保留错误、重试和诊断信息。
- **更可靠的缓存**：指纹覆盖模块版本、策略文件、兼容档案、用户和 GMS 状态。稳定重复 apply 不写设置、不做完整服务发现、不读取 package dump/logcat；仍读取三个设置，并对已选 GMS 服务执行当前用户的定向 action/权限验证。观察、锁定用户、部分失败和不可读状态不缓存为成功。
- **减少设置争抢**：apply、restore 和卸载共用带进程身份的锁；开机流程独立检查已有路由所有权，依赖变化也不会绕过漂移保护。restore 后暂停自动接管，直到显式执行 `apply conservative` 或 `apply force`。
- **可恢复的写入**：每次修改前保存事务意图，异常中断后只回滚仍匹配本次目标的键；已提交的所有权不会被误回滚。按键扩展原值备份，保留旧版备份恢复能力。
- **有界的临时任务**：统一超时和子进程树清理，限制无换行诊断输出，嵌套命令共用可清理的临时目录。冲突扫描包含枚举预算，忽略禁用/待删除模块；扫描不完整时不会报告“无冲突”。

同一主机、相同 Android 合成夹具各运行三次，完整 Action 中位耗时由约 4.63 秒降至 3.79 秒，完整服务查询由 66 次降至 36 次；公开报告由约 1.28 秒降至 0.97 秒。测量执行实际入口脚本，排除夹具准备和预设启动等待；这些结果不代表真机时延或耗电。稳定路径保留必要服务验证，不以省略检查换取调用次数。

主机回归、真实子进程中断测试和 ZIP 文件白名单检查用于验证脚本行为，不能证明 Android 真机 passkey 功能或耗电表现。本版本标记为 **1.0.0 正式版**，以主机回归和发布包审计作为发布检查；真机验证不再作为发布前置条件。当前尚未进行 BusyBox ash 及目标设备验证。OS4/API37 默认兼容保护保持不变。详细变更见 [CHANGELOG](CHANGELOG.md)。

## 这是什么

HyperOS Google Passkey Router for SukiSU 是一个面向中国大陆版 HyperOS 3，并对 HyperOS 4 / Android 17 提供受保护实验路径的纯脚本模块。

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
- 运行时检测 API、HyperOS 主版本、build stability、区域、用户解锁状态、GMS 状态、Credential Manager feature、provider 查询能力和 OEM hybrid 限制证据。
- 使用无 `eval` 的 `compat-profiles.conf` 分别判断 OS3/API36、OS3/API37、OS4/API36 和 OS4/API37；机型名称只用于报告，不决定是否写设置。
- 只读探测 OEM Credential Manager dialog、hybrid service、credential autofill 和默认/primary provider overlay 资源，不替换 framework resource 或伪造系统权限。
- 写入前生成可解释的 per-user route plan；Google provider 排在前面，同时保留合法第三方 Credential provider。
- Credential provider 与 Autofill 分开决策。保守模式只在 Autofill 为空、已经是 Google，或当前为 Xiaomi/MIUI Autofill 时切换到经过验证的 GMS Autofill。
- 重建 provider 列表时尽量过滤 Xiaomi / MIUI / FIDO 相关组件。
- 对每个 Android 用户分别应用设置，并在写入后逐键回读；临时 Binder 事务失败会有限重试。Credential 关键键在 conservative 下保持原子，Autofill 独立降级，force 测试支持按键级 `unsupported`。
- 保存不含账号信息的成功指纹。模块、策略、兼容档案、构建、用户、GMS 和路由均匹配时，重复 apply 只做轻量读取及已选服务定向验证，不做完整 provider 发现、不运行 package dump/logcat，也不写 settings。
- `boot-completed.sh` 是 KernelSU/SukiSU 的主入口，路由和延迟检查总窗口为 90 秒；其他管理器的兼容回退最多等待开机 120 秒，再进入 90 秒路由窗口，外层总上限 210 秒（不含短暂清理开销）。结束后无常驻进程。
- Action、开机、restore 和卸载使用带进程身份、owner 类型和等待上限的同一互斥锁。Action 最多等待 3 秒；只读报告不依赖 apply lock。
- 只读扫描其他模块可能存在的设置写入、GMS 冻结/组件管理、深层 passkey hook 和 framework overlay。扫描最多 64 个模块、每模块 12 个文件、总计 128 个文件、单文件 64 KiB、总预算 4 秒，不执行或修改其他模块。
- 如果本模块写入后的路由被用户或其他模块改变，自动开机流程停止重写并记录 ownership conflict，避免循环争抢。
- 提供 SukiSU Ultra 模块页 Action 按钮，可一键应用、查看状态、生成诊断报告并打开相关设置页面。
- Action 的 status、apply、report、open 是四个独立且有硬超时的进程；前一步失败不会拖死后一步。
- 诊断报告分为默认 `public` 和显式 `private`；每个 section 及报告总流程都有时间预算，公开报告自动过滤常见账号、网络、设备标识、宿主路径和 token 模式。
- 诊断报告保存到 `/data/adb/hypergpm-router/logs/`，最多保留最近 5 份；运行日志超过 128 KiB 后最多轮转两代。
- 首次管理某个键时备份原始 secure settings。restore/卸载只恢复当前仍等于模块最后写入值且有备份的键，保留用户之后的新选择；锁定用户留待解锁后恢复。

## 0.4.0-beta 历史新增内容

- 新增 stable-state 快速路径和最小成功指纹。合成基准中，完整 apply 为 12 次 settings get、3 次 put、6 次 provider query、2 次 package dump、1 次 logcat；稳定重复 apply 为 3 次 settings get、0 次 put、0 次 provider query、0 次 dumpsys、0 次 logcat。
- KernelSU/SukiSU 开机流程改为直接使用 `boot-completed.sh`。`service.sh` 在 KernelSU 环境立即退出，兼容 watchdog 最长存活 120 秒。
- 正常开机发现路径禁止完整 package dump 和 logcat；只有 Action、CLI 或显式报告允许昂贵诊断。
- 新增严格有界的只读模块冲突检测。public 报告只显示类别和计数，private 报告才显示经过限制的模块 ID。
- 检测到设置写入者、GMS 管理器或深层 Credential Manager hook 时，自动模式降级为 `observe-only`；用户仍可显式执行 `apply conservative` 或 `apply force`。
- 新增路由漂移保护。自动开机流程不覆盖后续用户选择或其他模块写入，避免设置争抢。
- ownership 记录增加写入时间和原因；新增显式 `restore force`，默认 `restore` 继续保护后续用户选择。
- 新增日志大小轮转、锁 owner/等待时间诊断、生命周期与冲突安全测试。

以上调用次数来自 host 合成夹具，用于比较脚本路径，不代表真机耗电或 Binder 时延；本项目不宣称未经真机测量的节电百分比。

## 0.3.0-alpha 新增内容

- 新增 HyperOS 4 与 Android 17/API37 双轴识别，避免把“OS4”等同于“Android 17”。
- 新增 `stable`、`beta`、`unknown` build stability 和 `planned/reported/verified/unsupported` profile 状态。
- OS3/API37、OS4/API36、OS4/API37 和未知组合在没有真机验证 profile 时默认 `observe-only`，不会由开机脚本自动写设置。
- 支持 API37 风格的 `ResolveInfo` / `ServiceInfo` 输出和冒号形式 permission 字段，同时保留 Android 16 parser。
- 新增五类 Credential framework overlay 资源探测，仅在 status/report 中展示“configured/not_configured/unknown”。
- Secure Settings 改为按键记录能力和所有权。缺失的 Autofill 不会阻止 Credential 路由，也不会在 restore 时被误写。
- 检测到 deep OEM hybrid restriction 后阻止继续 apply；Activity 打开失败会给出手动入口提示，但不影响 apply/report。
- Android 17 正式 AOSP `android-17.0.0_r1` 差异已核对：三个 Secure Settings 键、冒号分隔、provider binding permission 和核心 overlay 资源仍保留；API37 真机输出仍需设备验证。

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
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh apply conservative
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh apply force
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh report public
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh report private
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh open
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh restore
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh restore force
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh log
```

`plan` 只解释计划，不写设置。`apply force` 会显式覆盖兼容保护，也可能替换第三方 Autofill，仅用于主动测试。`restore force` 会覆盖模块运行后的用户选择，只有明确需要恢复安装前值时才使用。

如果 Action 第 2 步显示 `failed`，先查看 `log`。结构化事件会记录失败阶段、用户、尝试次数、返回码和短错误；`Failed transaction` 不会再阻止第 3、4 步继续执行。

## 兼容模式与配置

- `conservative`：OS3/API36 的默认模式；保留合法第三方 Credential provider，并避免无条件替换第三方 Autofill。未验证平台可通过显式命令进入受控测试。
- `observe-only`：只检查和报告，不写设置；未验证的 OS4、API37 和未知组合默认使用该模式。
- `force`：仅供用户明确测试，可能覆盖第三方 Autofill。

如果只读冲突扫描发现其他模块正在写相同设置、管理 GMS，或 hook Credential Manager，自动模式会降级为 `observe-only`。本模块不会禁用、修改或执行其他模块；显式模式表示用户决定让 HyperGPM 继续测试，并不保证两个模块能够共存。

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

如确实需要忽略所有权冲突并恢复安装前值，可显式执行：

```sh
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh restore force
```

## 性能与冲突设计

- 稳定重复 apply 只比较最小指纹和三个设置值；GMS、构建、用户集合、模块目录或路由变化后才重新完整发现。
- 开机路径不持有 wakelock、不访问网络、不递归扫描系统目录，也不运行完整 package dump/logcat。
- 临时 provider/Binder 不可用最多进行一次 5 秒退避重试；deep OEM restriction、永久不支持和 ownership drift 不重试。
- 合法第三方 Credential provider 会保留；conservative 模式保留第三方 Autofill。冲突检测失败记为 `unknown`，不会擅自处理其他模块。
- public 报告不列出完整模块 ID 或路径；private 报告可能包含有限模块 ID，分享前仍应人工检查。

## 支持状态

| HyperOS | Android API | 默认行为 | 当前证据 |
| --- | --- | --- | --- |
| OS3 | 36 | `conservative` | Xiaomi 15/REDMI K80 合成测试通过；最终 ZIP 真机流程待完成。 |
| OS3 | 37 | `observe-only` | Xiaomi 17 Android 17 Beta 风格 parser/route fixture 通过；无真机验证。 |
| OS4 | 36 | `observe-only` | Xiaomi 17/REDMI K90 Beta 风格 fixture 通过；可显式 conservative 测试，无真机验证。 |
| OS4 | 37 | `observe-only` | planned；无真机证据。 |

Xiaomi 14/15/17 系列和 REDMI K70/K80/K90 系列都走相同的 capability path，不按 marketing name 硬编码 provider。当前没有任何 OS4 或 Android 17 组合被标记为 `verified`。

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
├── compat-profiles.conf
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
- [Xiaomi HyperOS 4](https://hyperos.mi.com/)
- [Xiaomi Android 17 adaptation guide](https://dev.mi.com/xiaomihyperos/documentation/detail?pId=2297)
- [Android 17 release notes](https://developer.android.com/about/versions/17/release-notes)
- [AOSP Android 17 release 1](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-17.0.0_r1/)
- [Chromium GPM provider component definition](https://chromium.googlesource.com/chromium/src/+/main/components/webauthn/android/java/src/org/chromium/components/webauthn/CredManHelper.java)
- [HyperPasskey](https://github.com/Howard20181/HyperPasskey)
- [KeePassDX issue: Xiaomi passkey provider behavior](https://github.com/Kunzisoft/KeePassDX/issues/2220)

## 开源许可

本项目使用 [MIT License](LICENSE) 开源。

## 免责声明

这是 `1.0.0` 正式版模块，面向愿意自行排障的高级用户。它会以 root 权限写入 Android secure settings，不同 HyperOS 构建的行为可能不同。OS4/API37 的 fixture 结果不等于真机 passkey 创建成功；发布 issue 时请先检查诊断报告，如果 ROM 拒绝该路由，请使用 restore 或卸载模块恢复原设置。
