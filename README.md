# Codex Pulse

一个原生 macOS Codex 用量悬浮窗。它通过本机 Codex 自带的 app-server 协议读取当前登录账号的实时额度与 token 数据，不直接读取或保存账号密钥。

## 下载

从 [GitHub Releases](https://github.com/zhaotianjing/codex-pulse/releases/latest) 下载 `CodexPulse-macOS.zip`，解压后双击 `Codex Pulse.app`。

## 系统要求

- macOS 14 或更高版本
- Apple Silicon Mac（当前预编译版本为 arm64）
- 已安装 ChatGPT/Codex，并已使用 ChatGPT 账号登录 Codex

应用不需要额外配置 OpenAI API key。API key 登录模式不一定能返回 ChatGPT 套餐额度。

## 功能

- 悬浮置顶，可跨桌面显示
- 主 Codex 周期额度与重置倒计时
- 账户中的其他独立额度池（明确标注为非当前会话模型）
- 累计 token 与最高单日 token
- 60 秒自动刷新，支持手动刷新
- “−”键缩成仍然可见的迷你条，点击展开按钮即可恢复
- 菜单栏显示、隐藏、刷新与退出
- 再次双击应用可自动找回窗口
- 无 Dock 图标，窗口位置自动记忆

## 运行

1. 确认 Codex 或 ChatGPT 桌面应用已经登录。
2. 双击 `Codex Pulse.app`。
3. 如果 macOS 首次阻止打开，请右键应用并选择“打开”。

当前发布包使用本地 ad-hoc 签名，尚未经过 Apple notarization，因此首次打开时可能出现安全提示。

## 从源码构建

需要 macOS 14+ 和 Swift 5.9+：

```bash
chmod +x build-app.sh
./build-app.sh
```

构建产物会写入 `outputs/`。

如果 Codex 可执行文件不在常见安装路径，可在启动前设置：

```bash
export CODEX_USAGE_CODEX_BIN=/path/to/codex
open "outputs/Codex Pulse.app"
```

## 隐私

应用不会解析 `~/.codex/auth.json`，不会请求账户资料，也不会保存 API key、access token、邮箱或用量记录。每次刷新只启动 Codex 自带的本地 app-server，并请求 `account/rateLimits/read` 与 `account/usage/read`。完整说明见 [PRIVACY.md](PRIVACY.md)。

## 许可证

[MIT](LICENSE)
