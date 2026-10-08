# QuotaBar

macOS 菜单栏应用，集中显示各家 AI coding 订阅和额度的用量。

菜单栏上只有一个仪表图标。点击后弹出各家额度；设置从面板里的齿轮打开。应用不出现在 Dock 里。

## 支持的额度源

| Provider | 计费方式 | 数据来源 | 凭据来源 |
|---|---|---|---|
| **GLM Coding** | 订阅 | `api.z.ai` / `open.bigmodel.cn` 的 `/api/monitor/usage/quota/limit` | 自动读 `~/.claude/settings.json` |
| **Cursor** | 订阅 | `cursor.com/api/usage-summary`（非官方） | 自动读 Cursor 本地登录态 |
| **Codex** | 订阅 | `chatgpt.com/backend-api/wham/usage`（非官方） | 自动读 `~/.codex/auth.json` |
| **Xiaomi MiMo** | 按量/充值 | `platform.xiaomimimo.com` 控制台余额（非官方） | 自动读 Chrome 里的小米官网登录 |
| **DeepSeek** | 按量/充值 | `api.deepseek.com/user/balance`（官方） | 自动读 `~/.claude/providers/deepseek.json` |

两类账号的呈现方式不同：

- **订阅制**（GLM / Cursor / Codex）展示额度窗口的消耗百分比，并带重置时间。GLM 会分开显示 5 小时 Token、每周 Token 和每月 MCP。
- **按量充值**（MiMo / DeepSeek）展示剩余余额，不画进度条。

本机已经登录对应账号时，五家都可以直接出数，设置里不用再粘贴 Token 或 Cookie。设置里的字段是可选覆盖：填了就用填写的值，留空则继续读本机账号。

## 构建与运行

```bash
./scripts/build-app.sh     # 产出 .build/QuotaBar.app，并用稳定的本地证书签名
open .build/QuotaBar.app
```

需要 macOS 14+。只有 Command Line Tools 也能构建，不需要完整 Xcode。

`build-app.sh` 会确保登录钥匙串里有名为 `QuotaBar Local` 的自签名证书，并用它签名。这样钥匙串可以记住这个应用，重建之后不会每次启动都再要本机密码。

### 调试

```bash
./.build/QuotaBar.app/Contents/MacOS/QuotaBar --dump
./.build/QuotaBar.app/Contents/MacOS/QuotaBar --dump --dump-raw
```

也可以用未打包的调试二进制：

```bash
swift build
./.build/debug/QuotaBar --dump
```

`--dump` 只打印额度数字，不打印任何 token 或 cookie。

## 配置

点击菜单栏图标，再点设置。Token 与 Cookie 存在 macOS 钥匙串（服务名 `com.lijunze.quotabar`），非敏感项（例如刷新间隔、Base URL）存在 `~/Library/Application Support/QuotaBar/config.json`。

密钥字段从不回显，只显示「已配置」。留空表示保持原值。

| Provider | 自动读取 | 可选手动覆盖 |
|---|---|---|
| GLM Coding | `~/.claude/settings.json` 里的 `ANTHROPIC_AUTH_TOKEN` 和 `ANTHROPIC_BASE_URL`；否则用环境变量 `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` | Token、Base URL |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` 里的登录态 | Session Cookie |
| Codex | `~/.codex/auth.json` | OAuth Token、Account ID |
| Xiaomi MiMo | Chrome 中 `platform.xiaomimimo.com` 的小米登录会话 | 会话 Cookie |
| DeepSeek | `~/.claude/providers/deepseek.json` 里的 `ANTHROPIC_AUTH_TOKEN` | API Key |

MiMo 的推理 API Key 查不到余额，额度来自控制台登录会话。需要本机 Chrome 已经登录小米开放平台。

## 数据源的稳定性

- **官方接口**：DeepSeek、GLM（后者与官方用量插件使用同一额度接口）
- **非官方接口**：Cursor、Codex、MiMo。它们是网页控制台或 CLI 内部使用的私有端点，可能在没有预告的情况下失效。解析对字段漂移做了容错，失败时会给出可读的错误信息。

## 项目结构

```
Sources/QuotaBar/
  Support/
    Model.swift            Meter / QuotaSnapshot / QuotaProvider
    HTTPClient.swift       请求与 JSON 解码
    CredentialStore.swift  钥匙串 + 配置文件
    LocalAccount.swift     从本机配置文件读取已登录账号
    QuotaStore.swift       定时刷新
    Dump.swift             --dump 调试输出
  Providers/               每家一个文件；MiMo 的浏览器会话在 MiMoBrowserSession.swift
  QuotaBarApp.swift        菜单栏入口
  MenuContentView.swift    下拉面板与设置窗口
  SettingsView.swift       凭据配置
scripts/build-app.sh
scripts/ensure-codesign-identity.sh
```

新增一家额度源：实现 `QuotaProvider`，再在 `ProviderRegistry.make()` 里注册。
