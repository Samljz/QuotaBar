# QuotaBar

macOS 菜单栏应用，集中显示各家 AI coding 订阅 / 额度的用量。

## 支持的额度源

| Provider | 计费方式 | 数据来源 | 凭据来源 | 状态 |
|---|---|---|---|---|
| **GLM Coding** | 订阅 | `api.z.ai` / `open.bigmodel.cn` `/api/monitor/usage/quota/limit` | 手动填 Token | 待配置 |
| **Cursor** | 订阅 | `cursor.com/api/usage-summary`（非官方） | **自动**读 Cursor 登录态 | ✅ 已跑通 |
| **Codex** | 订阅 | `chatgpt.com/backend-api/wham/usage`（非官方） | **自动**读 `~/.codex/auth.json` | ✅ 已跑通 |
| **Xiaomi MiMo** | 按量/充值 | `platform.xiaomimimo.com/api/v1/balance`（非官方） | 手动填会话 Cookie | 待配置 |
| **DeepSeek** | 按量/充值 | `api.deepseek.com/user/balance`（官方） | 手动填 API Key | 待配置 |

两类账号的呈现方式不同：

- **订阅制**（GLM / Cursor / Codex）—— 展示额度窗口的消耗百分比，带重置时间
- **按量充值**（MiMo / DeepSeek）—— 展示**剩余余额**，不画进度条

## 构建与运行

```bash
./scripts/build-app.sh     # 产出 .build/QuotaBar.app
open .build/QuotaBar.app
```

需要 macOS 14+。只有 Command Line Tools 也能构建，不需要完整 Xcode。

### 调试

```bash
swift build
./.build/debug/QuotaBar --dump          # 拉一次所有额度并打印
./.build/debug/QuotaBar --dump --dump-raw  # 额外打印原始响应（用于排查字段）
```

`--dump` 只打印额度数字，不打印任何 token / cookie。

## 配置

点击菜单栏图标 → **设置**。Token 与 Cookie 存在 macOS 钥匙串，非敏感项存
`~/Library/Application Support/QuotaBar/config.json`。

secret 字段**从不回显**，只显示「已配置」。

| Provider | 需要填什么 |
|---|---|
| GLM Coding | Token + Base URL（`https://api.z.ai/api/anthropic` 或 `https://open.bigmodel.cn/api/anthropic`） |
| Xiaomi MiMo | 浏览器 DevTools → `platform.xiaomimimo.com` 任意请求 → Request Headers → `Cookie`（需含 `api-platform_serviceToken=...; userId=...`） |
| DeepSeek | API Key（platform.deepseek.com/api_keys） |

Cursor 与 Codex 无需配置：分别从 Cursor 的本地登录态和 `~/.codex/auth.json` 自动读取。

## 数据源的稳定性

- **官方接口**：DeepSeek、GLM（后者是官方插件使用的同款接口）
- **非官方接口**：Cursor、Codex、MiMo —— 均为网页 dashboard / CLI 内部使用的私有端点，
  与既有开源实现一致（`openusage`、`CodexBar`、`opencode-quota`）。**可能在无预告的情况下失效**，
  代码对 schema 漂移做了容错，并会在失败时给出可读的错误信息。

## 项目结构

```
Sources/QuotaBar/
  Support/
    Model.swift          Meter / QuotaSnapshot / QuotaProvider 协议 / BillingModel
    HTTPClient.swift     请求与 JSON 解码，失败时附响应摘要
    CredentialStore.swift 钥匙串 + 配置文件
    QuotaStore.swift     定时刷新调度
    Dump.swift           --dump 调试输出
  Providers/             每家一个文件
  QuotaBarApp.swift      MenuBarExtra 入口
  MenuContentView.swift  弹出面板
  SettingsView.swift     凭据配置
```

新增一家额度源：实现 `QuotaProvider`，再到 `ProviderRegistry.make()` 里注册。
