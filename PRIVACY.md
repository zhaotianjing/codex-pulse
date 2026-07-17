# Privacy

Codex Pulse is a local macOS utility. It does not include analytics, telemetry,
advertising, or a developer-operated server.

## Data it reads

Codex Pulse starts the Codex installation already present on the Mac and uses
the local Codex app-server protocol to request:

- account rate-limit percentages and reset times;
- aggregate token-usage statistics.

Only one Codex Pulse instance may run per macOS user. Each refresh uses at most
one local Codex app-server process, and the app synchronously terminates and
reaps that process when the refresh finishes or Codex Pulse quits. Successful
OpenAI signature verification is cached only while the executable and signature
files remain unchanged, avoiding repeated full validation work.

The app does not request account profile details and does not read
`~/.codex/auth.json`.

When Claude monitoring is explicitly enabled, Codex Pulse installs a local
status-line bridge by replacing only `statusLine.command` in
`~/.claude/settings.json`. It preserves every other status-line field and keeps
an owner-only recovery copy of the complete previous `statusLine` object.

Claude Code sends status-line JSON to the bridge after normal interface events,
including completed assistant responses. The bridge validates a bounded copy
in memory and retains only these documented fields:

- `rate_limits.five_hour.used_percentage` and `resets_at`;
- `rate_limits.seven_day.used_percentage` and `resets_at`;
- a local capture timestamp and cache schema version.

The input is forwarded byte-for-byte to the previous status-line command, so
its output remains available in Claude Code. The complete JSON is never written
to disk. Codex Pulse does not retain session IDs, prompt IDs, prompts,
responses, transcript paths, working directories, repository details, model
names, cost data, account identifiers, or authentication fields. Anthropic's
documented status-line schema does not expose model-scoped limits such as
Fable, so Codex Pulse does not present them as live data.

Before launching Codex, the app verifies the executable's Developer ID
signature, OpenAI Team ID, and code identifier. It does not send signing
metadata anywhere.

## Authentication

Codex Pulse does not ask for or independently read an API key, access token,
refresh token, password, ChatGPT account email, Claude account identifier, or
Claude account email. Authentication and requests are handled by the user's
existing Codex and Claude installations and logins. Codex Pulse never reads the
macOS Keychain. If the user manually embedded a credential in the previous
`statusLine` command, the owner-only manifest and base64 helper fallback copy
that command verbatim until successful disable; Codex Pulse does not parse or
use the embedded value. It does not create a hidden Claude session or send an
automatic prompt to obtain usage data.

## Storage and transmission

Codex responses are held in memory only for display. Optional Claude monitoring
writes three local files under
`~/Library/Application Support/Codex Pulse/`:

- an owner-only (`0600`) rate-limit cache containing only the allowlisted
  values listed above;
- an owner-only (`0600`) recovery manifest containing the exact previous
  `statusLine` object and the installed bridge state;
- an owner-only executable (`0700`) helper that connects Claude Code to the app.

The recovery object may duplicate a user-supplied local command, path, or other
value already present in `statusLine`. The helper also contains a base64 fallback
copy of the previous command so it can preserve the user's status line if the
app or manifest is unavailable. Base64 is not encryption; file permissions
provide the local access control. These values are never logged, packaged,
uploaded, or displayed. These files are not sent to the developer or any third party.
The existing Codex and Claude installations may communicate with OpenAI and
Anthropic under the user's accounts and are governed by those providers'
applicable terms and privacy policies.

Claude monitoring is off by default. On successful disable, Codex Pulse first
stops cache capture, restores the previous command while preserving later
changes to non-command fields, removes the
rate-limit cache, recovery manifest, and helper, and clears Claude values from
the window. If the user or Claude Code changed the status-line object after
setup, Codex Pulse leaves the newer setting untouched, disables capture, removes
the rate-limit cache, and retains the private manifest and helper for recovery.
The app reports this conflict instead of claiming complete cleanup.

The bridge uses owner and permission checks, rejects symbolic links and hard
links for managed files, bounds parsed input, and uses same-directory atomic
writes. It does not change Claude hooks or login configuration.

## Source builds

The repository excludes local build caches, generated work files, application
archives, and macOS metadata. Release archives are built separately.
