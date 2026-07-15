# HyperOS Google Passkey Router for SukiSU

Developer: **framelix**

- 模块 ID：`hypergpm-router`
- 版本：`0.1.1-alpha`
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

目标 provider 是 Google Play services 中的 Google Password Manager / passkey 服务。

## 功能

- 优先通过 Android `query-services` 精确发现 Google Play services 中声明的凭据服务组件；仅在 ROM 查询异常时使用有超时限制的 package dump 回退。
- 优先使用 `com.google.android.gms/.auth.api.credentials.credman.service.PasswordAndPasskeyService` 作为 passkey 创建 provider。
- 写入 `credential_service` 和 `credential_service_primary`，尽量让 Google provider 排在前面。
- 写入 `autofill_service`，指向 Google Autofill / Google Password Manager。
- 重建 provider 列表时尽量过滤 Xiaomi / MIUI / FIDO 相关组件。
- 对每个 Android 用户分别应用设置，并在写入后回读验证；临时 Binder 事务失败会自动重试，部分写入失败会回滚。
- Action 与开机 watchdog 使用互斥锁，避免同时发现 provider、备份和写设置时互相干扰。
- 开机后自动重复应用，减少 HyperOS Settings / SecurityCenter 回写设置的影响。
- 提供 SukiSU Ultra 模块页 Action 按钮，可一键应用、查看状态、生成诊断报告并打开相关设置页面。
- 诊断命令均有时间上限并显示采集进度，避免 `dumpsys`、`logcat` 或文件扫描长期阻塞 Action。
- 诊断报告保存到 `/data/adb/hypergpm-router/logs/`，最多保留最近 5 份。
- 首次 apply 时备份原始 secure settings，支持手动 restore 和卸载时恢复。

## 安装

1. 确认设备已安装 Google Play services，并且 Google 账号、Google Password Manager 基本可用。
2. 在 SukiSU Ultra 或 KernelSU 风格模块管理器中安装模块 zip。
3. 重启设备。
4. 进入模块页面，点击 **Action** 一次。
5. 到系统的密码 / passkey / autofill 设置页检查 Google Password Manager 是否已被选中。

## Action 按钮会做什么

点击模块 Action 后会依次执行：

1. 显示当前状态。
2. 立即应用 Google provider 路由。
3. 生成诊断报告。
4. 尝试打开 Android Credential Provider 设置页。
5. 尝试打开 Google passkey 管理页面。

报告路径：

```text
/data/adb/hypergpm-router/logs/
```

报告可能包含设备型号、系统版本、已安装 provider 组件名和相关系统日志。公开上传或提交 issue 前请先检查并脱敏；模块不会自动上传报告。

## 手动命令

可以在 root shell 中执行：

```sh
su
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh status
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh apply
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh report
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh open
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh restore
sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh log
```

如果 Action 第 2 步显示 `failed`，先查看 `log` 命令输出。日志会记录失败发生在 provider 查询、设置读取、设置写入还是回读验证；原始 `Failed transaction` 不会再直接打断 Action，模块会最多重试 3 次。

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

卸载模块时，`uninstall.sh` 也会尽量恢复备份过的设置。

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
├── tests/
│   └── test_common.sh
└── META-INF/
```

## 参考

- [KernelSU module guide](https://kernelsu.org/guide/module.html)
- [Android Credential Manager provider documentation](https://developer.android.com/identity/sign-in/credential-provider)
- [Android CredentialProviderService API reference](https://developer.android.com/reference/android/service/credentials/CredentialProviderService)
- [AOSP Settings.Secure credential settings](https://android.googlesource.com/platform/frameworks/base/+/master/core/java/android/provider/Settings.java)
- [AOSP CredentialManagerService provider setting logic](https://android.googlesource.com/platform/frameworks/base/+/main/services/credentials/java/com/android/server/credentials/CredentialManagerService.java)
- [Chromium GPM provider component definition](https://chromium.googlesource.com/chromium/src/+/main/components/webauthn/android/java/src/org/chromium/components/webauthn/CredManHelper.java)
- [HyperPasskey](https://github.com/Howard20181/HyperPasskey)
- [KeePassDX issue: Xiaomi passkey provider behavior](https://github.com/Kunzisoft/KeePassDX/issues/2220)

## 开源许可

本项目使用 [MIT License](LICENSE) 开源。

## 免责声明

这是 `0.1.1-alpha` 实验模块，面向愿意自行排障的高级用户。它会以 root 权限写入 Android secure settings，不同 HyperOS 构建的行为可能不同。发布 issue 时请先检查并脱敏诊断报告；如果 ROM 拒绝该路由，请使用 restore 或卸载模块恢复原设置。
