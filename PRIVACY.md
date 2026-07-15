# Privacy

Codex Pulse is a local macOS utility. It does not include analytics, telemetry,
advertising, or a developer-operated server.

## Data it reads

Codex Pulse starts the Codex installation already present on the Mac and uses
the local Codex app-server protocol to request:

- account rate-limit percentages and reset times;
- aggregate token-usage statistics.

The app does not request account profile details and does not read
`~/.codex/auth.json`.

Before launching Codex, the app verifies the executable's Developer ID
signature, OpenAI Team ID, and code identifier. It does not send signing
metadata anywhere.

## Authentication

Codex Pulse does not ask for, store, or transmit an API key, access token,
refresh token, password, or ChatGPT account email. Authentication and requests
to OpenAI are handled by the user's existing Codex installation and login.

## Storage and transmission

Usage responses are held in memory only for display. Codex Pulse does not save
them to disk or send them to the developer or any third party. The existing
Codex installation may communicate with OpenAI under the user's account and is
governed by OpenAI's applicable terms and privacy policy.

## Source builds

The repository excludes local build caches, generated work files, application
archives, and macOS metadata. Release archives are built separately.
