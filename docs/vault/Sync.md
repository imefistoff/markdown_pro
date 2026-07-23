---
type: reference
tags: [project, sync, github]
---

# MarkdownPro — Sync

Part of [[MarkdownPro]]. Lives in `Core` (`MarkdownProCore`), so both the app and the MCP server share it. See [[Architecture]].

## What it is
Optional **GitHub-only** sync so a board can follow you across Macs. Local writes are recorded as an operation log and replayed against a GitHub repo over the REST API; another Mac adopts and replays them back. Deliberately **narrowed from an earlier folder+GitHub design to GitHub-only** (Spec B) — `FolderTransport` was removed and the engine tests migrated to `GitHubTransport`.

## Pieces (`Core/Sources/MarkdownProCore/`)
- **`SyncTransport.swift`** — the transport protocol the engine talks to.
- **`GitHubTransport.swift`** — `SyncTransport` implemented over the GitHub REST API.
- **`GitHubAPI.swift`** — thin GitHub REST client (contents API; base64 file bodies).
- **`SyncEngine.swift`** — drives push/pull, cursors, adoption.
- **`SyncModels.swift` / `SyncState.swift` / `SyncClock.swift`** — op records, cursors/state, logical clock.
- **`SyncReplayer.swift`** — replays adopted ops into the local `Repository`.
- App side: `MarkdownPro/Views/SyncSettingsView.swift`, `Store.swift` transport selection, `KeychainTokenStore.swift` (+ `Core` uses it for the token).

## Token & security
The GitHub token is kept in the **macOS Keychain** (`KeychainTokenStore`), not the DB or defaults. Keychain errors are surfaced to the user rather than swallowed.

## Sharp edges (learned in the Spec B work)
- **Switching the sync target resets cursors** (`Repository.resetSyncCursors`) so a genuine target switch replays cleanly instead of diffing against the wrong history.
- **Malformed `devices.json` throws** (does not silently wipe the roster).
- **Guard non-base64 contents** from the GitHub contents API before decoding (`d15f15d`).
- **On-demand adoption refresh** and a durable disconnect that clears the stale path/cursor on a genuine switch.

## Tests
`Core/Tests/MarkdownProCoreTests/`: `GitHubAPITests`, `GitHubTransportTests`, `SyncEngineTests`, `SyncAdoptionTests`, `SyncClockTests`, `SyncDocumentTests`, `SyncModelsTests`, `SyncReplayerTests`, `OpRecordingTests`, plus `FakeGitHubServer` (in-memory `URLProtocol` double — no live network in tests).
