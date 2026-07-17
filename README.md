# Codex Pulse

<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="Codex Pulse app icon">
</p>

Codex Pulse is a native macOS floating usage monitor for Codex, with optional Claude Code plan monitoring. It reads Codex limits through the local app-server protocol and can display Claude's official 5-hour and 7-day subscription limits. It does not read provider authentication stores or request account credentials. If a user has embedded a credential directly in a custom Claude `statusLine` command, the private recovery copies necessarily reproduce that command verbatim while monitoring is enabled.

## Download

Download `CodexPulse-macOS.zip` from [GitHub Releases](https://github.com/zhaotianjing/codex-pulse/releases/latest), unzip it, and open `Codex Pulse.app`.

Each release also includes `SHA256SUMS` and `CodexPulse-build-info.txt`. The build information records the source commit, app version, executable architecture, and signing status without including the builder's username or local path.

## Requirements

- macOS 14 or later
- An Apple Silicon Mac (the current prebuilt release is arm64)
- ChatGPT or Codex installed, with Codex signed in through a ChatGPT account
- Optional: a current Claude Code installation signed in with a Claude Pro or Max account

No OpenAI or Anthropic API key is required. API-key sessions may not provide subscription plan rate-limit data.

## Features

- Always-on-top floating window that can appear across desktops
- Primary Codex rate limit and reset countdown
- Other independent account-level limit pools, clearly marked as separate from the active model
- Lifetime and peak daily token usage
- Optional Claude 5-hour and 7-day subscription limits
- Automatic refresh every 5 minutes, plus manual refresh
- Verification of the official OpenAI code signature before Codex is launched
- Single-instance protection and synchronous cleanup of the local Codex app-server process
- A passive Claude status-line bridge that sends no prompt and consumes no extra tokens
- Bounded process output and sanitized on-screen errors
- A minimize button that collapses the window into a visible compact bar
- Menu bar controls to show, hide, refresh, or quit
- Reopening the app automatically brings the window back
- No Dock icon, with automatic window-position persistence

## Run the App

1. Make sure Codex or the ChatGPT desktop app is installed and signed in.
2. Move `Codex Pulse.app` to the Applications folder and open it.

### Enable Claude Monitoring (Optional)

Claude monitoring is off by default:

1. Install Claude Code with Anthropic's official native installer and confirm that `claude` opens an authenticated Pro or Max session in Terminal.
2. Open Codex Pulse and click **Enable Claude Monitoring** in the Claude card.
3. Send any normal prompt in Claude Code. The rate-limit fields become available after Claude completes the first API response in that session.
4. Codex Pulse checks the latest captured values every 5 minutes. Click **Refresh** to read them immediately, or click **Disable** to restore the previous status line and remove the captured values.

Claude Code exposes subscription rate limits to its [`statusLine` command](https://code.claude.com/docs/en/statusline). When monitoring is enabled, Codex Pulse replaces only the `command` field in `~/.claude/settings.json` and preserves `padding`, `refreshInterval`, and any other status-line fields. Its private helper receives the same JSON that Claude Code already sends to the status line, saves only the allowlisted 5-hour and 7-day percentages and reset timestamps, and forwards the original JSON byte-for-byte to the previous command. The previous status-line output and exit status are preserved.

The full status-line JSON is never written to disk. Codex Pulse does not retain session IDs, prompts, responses, transcript paths, working directories, model names, cost data, account identifiers, or authentication fields. It does not launch a hidden Claude session, read the macOS Keychain, or make an additional Anthropic request. Normal prompts that you choose to send to Claude still consume Claude usage; the bridge itself does not.

Bridge files are stored in `~/Library/Application Support/Codex Pulse/`. The captured rate-limit cache and recovery manifest are owner-only files (`0600`), and the helper is owner-only executable (`0700`). The recovery manifest contains the exact previous `statusLine` object so Codex Pulse can restore it; that object may include a local command or path supplied by the user. The helper also contains an owner-only base64 fallback copy of the previous command so the existing status line can still run if the app or manifest becomes unavailable. Base64 is recovery encoding, not encryption. A successful **Disable** restores the previous command and deletes all three files.

Changes to non-command fields such as `padding` are preserved when monitoring is disabled. If the status-line command itself is changed after monitoring is enabled, Codex Pulse will not overwrite the newer command. **Disable** stops capture and removes the rate-limit cache, but leaves the private recovery manifest and helper in place and reports the conflict. Re-enabling monitoring adopts the newer status line as the one to preserve. Avoid editing `~/.claude/settings.json` at the exact moment you click **Enable** or **Disable**, and disable monitoring before deleting the app.

Anthropic's documented status-line schema provides only the 5-hour and 7-day windows. Model-scoped limits such as Fable are not exposed there, so Codex Pulse does not claim or display them as live Claude data.

If the card still says it is waiting after Claude has completed a response, restart that Claude session and confirm the workspace is trusted. A project, local, or managed Claude setting with a higher-precedence `statusLine` can override the user setting that Codex Pulse installs; remove that override or configure monitoring at the active settings level.

### First Launch: Open Anyway

The current release uses local ad-hoc code signing with Hardened Runtime enabled, but it is not signed with an Apple Developer ID or notarized by Apple. Hardened Runtime adds process protections, while an ad-hoc signature does not authenticate the publisher. On first launch, macOS may display a **“Codex Pulse” Not Opened** warning because Apple cannot verify the developer.

Only override this warning when the app was downloaded from this repository's official [GitHub Releases](https://github.com/zhaotianjing/codex-pulse/releases/latest) page.

1. In the warning dialog, click **Done**. Do not click **Move to Trash**.
2. Open **System Settings** and select **Privacy & Security**.
3. Scroll down to the **Security** section.
4. Find the message that says **“Codex Pulse” was blocked to protect your Mac**.
5. Click **Open Anyway**.
6. Authenticate with Touch ID or your Mac password, then confirm **Open**.

This approval is normally required only once. If **Open Anyway** does not appear, try opening `Codex Pulse.app` again and immediately return to **System Settings → Privacy & Security**. See [Apple's official instructions](https://support.apple.com/102445) for additional details.

### Verify the Download

Download `CodexPulse-macOS.zip` and `SHA256SUMS` from the same release into the same folder. In Terminal, change to that folder and run:

```bash
grep ' CodexPulse-macOS.zip$' SHA256SUMS | shasum -a 256 --check
```

The expected result is `CodexPulse-macOS.zip: OK`. This confirms that the archive matches the checksum attached to that release. Because the checksum and archive are hosted together and the app is not Developer ID signed, this detects accidental corruption or a mismatched download but does not independently prove the publisher's identity.

### Start Automatically After Login (Optional)

To launch Codex Pulse automatically whenever you sign in to your Mac:

1. Make sure `Codex Pulse.app` is in the Applications folder.
2. Open **System Settings → General → Login Items & Extensions**.
3. Under **Open at Login**, click the **Add (+)** button.
4. Select `Codex Pulse.app` from the Applications folder.
5. Click **Open**.

Keep the app in the Applications folder after adding it. To disable automatic launch later, return to **Open at Login**, select **Codex Pulse**, and click the **Remove (−)** button.

When upgrading from version 1.0.2 or earlier, macOS may treat version 1.1.0 as a new app because it now uses a unique bundle identifier. The saved window position may reset. If automatic launch stops working, remove the old Login Item and add the new app again.

## Build from Source

Building requires macOS 14 or later and Swift 5.9 or later:

```bash
chmod +x build-app.sh
./build-app.sh
```

Build artifacts are written to `outputs/`. The build script enables Hardened Runtime, verifies the resulting ad-hoc signature, creates a source archive with stable file ordering and timestamps, writes provenance to `CodexPulse-build-info.txt`, and generates `SHA256SUMS` for the release files.

Local validation commands are available after building:

```bash
.build/release/CodexUsageFloat --self-test
.build/release/CodexUsageFloat --fetch-once
.build/release/CodexUsageFloat --fetch-claude-once
```

If an official OpenAI-signed Codex executable is not in a standard installation path, quit Codex Pulse, then set its absolute location before launching:

```bash
export CODEX_USAGE_CODEX_BIN=/path/to/codex
open "outputs/Codex Pulse.app"
```

The override does not bypass security checks. Codex Pulse rejects the file unless its Developer ID signature, OpenAI Team ID, and executable identifier are valid.

## Privacy

Codex Pulse does not parse `~/.codex/auth.json`, access the macOS Keychain, or request account profiles. It does not independently read API keys, access tokens, email addresses, or account identifiers. Codex refreshes request only `account/rateLimits/read` and `account/usage/read`. Optional Claude monitoring stores only two rate-limit percentages, their reset timestamps, capture timestamps, and private recovery copies of the user's previous `statusLine` command. A credential manually embedded in that command is therefore copied verbatim until successful disable. See [PRIVACY.md](PRIVACY.md) for details.

## License

[MIT](LICENSE)
