# Codex Pulse

Codex Pulse is a native macOS floating usage monitor for Codex. It reads real-time rate limits and token usage for the currently signed-in account through Codex's local app-server protocol. It does not read or store account credentials.

## Download

Download `CodexPulse-macOS.zip` from [GitHub Releases](https://github.com/zhaotianjing/codex-pulse/releases/latest), unzip it, and open `Codex Pulse.app`.

## Requirements

- macOS 14 or later
- An Apple Silicon Mac (the current prebuilt release is arm64)
- ChatGPT or Codex installed, with Codex signed in through a ChatGPT account

No OpenAI API key is required. Accounts signed in with an API key may not provide ChatGPT plan rate-limit data.

## Features

- Always-on-top floating window that can appear across desktops
- Primary Codex rate limit and reset countdown
- Other independent account-level limit pools, clearly marked as separate from the active model
- Lifetime and peak daily token usage
- Automatic refresh every 60 seconds, plus manual refresh
- A minimize button that collapses the window into a visible compact bar
- Menu bar controls to show, hide, refresh, or quit
- Reopening the app automatically brings the window back
- No Dock icon, with automatic window-position persistence

## Run the App

1. Make sure Codex or the ChatGPT desktop app is installed and signed in.
2. Open `Codex Pulse.app`.
3. If macOS blocks the app the first time, Control-click the app and choose **Open**.

The current release uses local ad-hoc code signing and is not notarized by Apple, so macOS may display a security warning the first time it opens.

## Build from Source

Building requires macOS 14 or later and Swift 5.9 or later:

```bash
chmod +x build-app.sh
./build-app.sh
```

Build artifacts are written to `outputs/`.

If the Codex executable is not in a standard installation path, set its location before launching:

```bash
export CODEX_USAGE_CODEX_BIN=/path/to/codex
open "outputs/Codex Pulse.app"
```

## Privacy

Codex Pulse does not parse `~/.codex/auth.json`, request account profile data, or store API keys, access tokens, email addresses, or usage history. Each refresh starts Codex's local app-server and requests only `account/rateLimits/read` and `account/usage/read`. See [PRIVACY.md](PRIVACY.md) for details.

## License

[MIT](LICENSE)
