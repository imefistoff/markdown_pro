# Design: Launch Claude Code sessions from the Review Center

**Date:** 2026-07-12
**Status:** approved (brainstorm)
**Depends on:** the Review Center (`2026-07-04-review-center-design.md`)

## Problem

Approving a proposal today sets `attention = ready_to_execute` and then nothing
happens. The flag is a sticky note: a human must notice it, open a terminal,
`cd` to the repo, recall what the task was about, and type the right `claude`
invocation from memory.

The app already knows the task id, the approved document's path, the project,
and the review comments. It can compose that command better than a human can
recall it. This design closes the loop: **an approved document becomes a
running Claude Code session, in one deliberate click.**

## Scope

In scope: a per-project launch configuration, a command builder, a confirm
sheet, and a Warp launcher. Out of scope: process supervision of the spawned
session, terminals other than Warp, and mirroring the `.superpowers/sdd/`
ledger onto the board (a known second source of truth — filed separately).

## Decisions

Four decisions were made during brainstorming; each closed a real fork.

**1. Launch is an armed button, not an approve side-effect.** Approving stays a
judgement about a *document*; launching stays a deliberate act that spawns an
*agent*. Fusing them would mean a misclick on Approve starts a process — and
the person clicking Approve is in "reviewing prose" headspace, not "authorizing
code execution" headspace.

**2. The app models the pipeline, but couples to superpowers through
configuration rather than code.** This repo's last feature already ran through
superpowers (`docs/superpowers/specs/` → `docs/superpowers/plans/` →
`.superpowers/sdd/`), so inventing a competing spec→plan→execute vocabulary
would leave two workflows fighting over one repo. But hardcoding a versioned
plugin's skill names into Swift means a rename in superpowers 6.2 ships as a
MarkdownPro release. So: the app learns the generic rule *"an approved document
of kind K launches command template T"*, and the superpowers chain ships as the
seeded default. Tight in practice, loose in code.

**3. Dangerous permission modes cost a deliberate click.** The confirm sheet
always shows the exact command; for `auto` / `dontAsk` / `bypassPermissions` it
adds a warning band and does not focus the Run button.

**4. The command is a generated shell script, invoked by a Warp launch
config.** Not an inline command in YAML — see "Injection containment".

## Architecture

```
Review Center                Core (MarkdownProCore)              Warp
─────────────                ──────────────────────              ────
 Approve  ──► attention = ready_to_execute
                                   │
 [▶ Launch] ──► LaunchScriptBuilder.script(task:document:settings:)
                       │  pure: (task, document, settings) → LaunchScript
                       ▼
                Confirm sheet (exact command, warn if unsafe)
                       │
                       ▼
                TerminalLauncher (protocol)
                       │
                WarpLauncher ──► writes task-N.sh + task-N.yaml
                                 open("warp://launch/markdownpro-task-N")
                                                              └─► new window
                                                                  runs claude
                       │
                Repository.recordLaunch ──► attention = executing
                                            activity row (actor: user)
```

### Schema v3

`documents.kind` is already a plain `TEXT` column, so adding `spec` and `plan`
to `DocumentKind` is a **Swift-only enum change** — no migration, consistent
with the Swift-only enum validation decided in the Review Center work.

Three idempotent `ALTER TABLE … ADD COLUMN` steps on `projects` (v2's pattern):

| Column | Type | Purpose |
| --- | --- | --- |
| `repo_path` | TEXT | Working directory to `cd` into. Null ⇒ launch disabled |
| `permission_preset` | TEXT | `manual` \| `plan` \| `acceptEdits` \| `auto` \| `dontAsk` \| `bypassPermissions` (default `acceptEdits`) |
| `use_worktree` | INTEGER | Pass `-w <slug>` on execute launches (default 1) |

plus one table:

```sql
CREATE TABLE IF NOT EXISTS launch_templates (
  project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  doc_kind    TEXT    NOT NULL,          -- 'spec' | 'plan'
  command     TEXT    NOT NULL,
  PRIMARY KEY (project_id, doc_kind)
);
```

A row exists **only when a template has been overridden**; absent means the
built-in superpowers default applies. Bump `PRAGMA user_version` to 3.

No `workflow_profile` column. A dropdown with one entry is dead vocabulary, and
this codebase already carries one unreachable state (`DocumentState.superseded`,
tracked as task 10) — the editable templates *are* the profile. If a second
profile ever earns its place, that is one migration away.

### The default profile (superpowers)

```
spec approved  →  claude --permission-mode plan
                  "Use the superpowers:writing-plans skill on @{doc} to produce
                   an implementation plan for MarkdownPro task {task_id}
                   — {task_title}. Submit the plan with submit_for_review."

plan approved  →  claude -w {slug} --permission-mode {preset}
                  "Use the superpowers:subagent-driven-development skill to
                   execute @{doc}. This is MarkdownPro task {task_id} —
                   {task_title}. Call add_progress_note as each task lands;
                   call submit_for_review with the final report when done."
```

Planning sessions never get a worktree (planning does not touch code). Execute
sessions honour `use_worktree`. `claude -w` creates the worktree itself, so the
app never shells out to `git` — an entire class of bug avoided.

Placeholders: `{doc}` `{doc_abs}` `{task_id}` `{task_title}` `{project}`
`{slug}` `{preset}` `{repo}`. Unknown placeholders pass through untouched, so a
typo produces a visibly wrong command in the confirm sheet rather than a crash.

### MCP surface

`submit_for_review` gains an optional `kind` parameter — `spec` | `plan` |
`proposal`, defaulting to `proposal` — so a session can declare which stage it
is submitting. It keeps rejecting `note` and `wiki` (only reviewable kinds may
enter the queue), mirroring the guard `attach_document` already applies in the
opposite direction.

**Existing `proposal` documents keep working and gain nothing.** `proposal`
stays a valid, reviewable kind with no launch template, so approving one arms no
Launch button — exactly today's behavior. Only `spec` and `plan` are launchable.
This means the feature is strictly additive: nothing on the current board
changes state or behavior when v3 lands.

### The engine

```swift
public struct LaunchScriptBuilder {
    public static func script(task: TaskItem,
                              document: Document,
                              settings: ProjectLaunchSettings) throws -> LaunchScript
}
```

A pure function — no filesystem, no processes, no UI — so all interesting logic
is unit-testable in `Core/Tests` without opening a window. It emits:

```bash
cd "/Users/…/markdown_pro" || exit 1
PROMPT=$(cat <<'MDPRO_PROMPT_EOF'
Use the superpowers:subagent-driven-development skill to execute
@docs/superpowers/plans/2026-07-12-warp-launch.md.
This is MarkdownPro task 10 — "Define rejected-proposal semantics".
MDPRO_PROMPT_EOF
)
exec claude -w "task-10-rejected-proposal" --permission-mode acceptEdits "$PROMPT"
```

**Injection containment.** Task titles are untrusted input that would otherwise
flow through YAML *and* a shell — a task titled ``Fix the `rm -rf` bug; drop
tables`` is a live weapon under naive interpolation. The quoted heredoc
(`<<'EOF'`) means nothing in the prompt is ever shell-interpreted. The only
values reaching a shell word are `repo_path` (quoted) and the worktree slug
(sanitized to `[a-z0-9-]`, length-capped). The builder rejects a prompt
containing its own heredoc delimiter — the one escape a hostile string could
attempt.

**Why a script and not `Process`.** A GUI app launched from Finder inherits a
stunted `PATH` and typically cannot find `claude` at all. The script runs inside
a Warp login shell, so `PATH` is the user's — `claude`, `mise`, `nvm` all
resolve. The script file is also the artifact behind the "Copy command" button,
and it survives Warp breaking its URI scheme (`sh ~/Library/…/task-10.sh`). The
feature degrades instead of dying.

**Repository** gains `projectLaunchSettings(_:)`, `setProjectLaunchSettings(_:)`
and `recordLaunch(taskId:kind:)`; the last flips `attention → executing` and
writes an activity row, keeping attribution correct per CLAUDE.md.

### The launcher

```swift
protocol TerminalLauncher {
    func launch(_ script: LaunchScript) throws
}
```

One conformance ships: `WarpLauncher`. It writes
`~/Library/Application Support/MarkdownPro/launch/task-N.sh` (chmod 0700) plus a
three-line launch config to `~/.warp/launch_configurations/`, then opens
`warp://launch/markdownpro-task-N`. A `FakeTerminalLauncher` conformance lets
the app layer be tested without spawning anything.

*Verified during brainstorming:* writing a launch config and firing
`warp://launch/<name>` runs an arbitrary command in a new Warp window at a chosen
`cwd` (probe returned `exec ran; cwd=/Users/…/markdown_pro`). The app has no
sandbox entitlements and `ENABLE_HARDENED_RUNTIME: NO`, so it may write these
files and open the URI.

## UI

**Launch button** — task detail and board card, shown when
`attention == .readyToExecute` and the project has a `repo_path`. Without one it
renders *disabled* with "Set repo path…" linking to settings: a dead button that
explains itself beats a hidden one.

**Confirm sheet** — always shows the exact composed script, monospaced and
scrollable. Safe presets: `[Copy] [Cancel] [Run]`, Run focused (Return to go).
Unsafe presets (`auto`, `dontAsk`, `bypassPermissions`): a warning band naming
the mode and what it disables, and Run is *not* focused.

**Project settings** — repo path picker, preset dropdown, worktree toggle, and
the two templates as editable fields with per-field "Reset to default".

## Closing the loop

```
Approve a spec        → attention = ready_to_execute     (exists today)
press Launch          → attention = executing, activity logged; Warp opens
claude submits plan   → submit_for_review → attention = needs_review
Approve the plan      → attention = ready_to_execute
press Launch          → attention = executing; worktree; SDD executes
claude finishes       → submit_for_review (final report) → needs_review
```

The return trip needs **no new mechanism**. It is carried by the prompt template
instructing the session to call `add_progress_note` and `submit_for_review` —
existing MCP tools writing to the same SQLite the app polls. No second write
path. `TaskAttention.executing` finally gains a writer.

**Known gap:** killing the Warp window mid-run leaves the task `executing`
forever. Rather than invent process supervision, task detail gains a "Clear
attention" menu item to unstick it manually.

## Error handling

| Failure | Behavior |
| --- | --- |
| No `repo_path` | Button disabled, links to settings |
| Document missing on disk | Sheet opens, Run disabled — never spend a context on a vanished file |
| Warp not installed | Sheet opens, Copy enabled, Run replaced by "Warp not found — copy and run manually" |
| Script write fails | Alert with the underlying error |
| `warp://` open silently fails | **Undetectable** — `open` returns success the moment LaunchServices dispatches. The sheet does not auto-dismiss, and Copy stays available. |

## Testing

`Core/Tests/MarkdownProCoreTests/LaunchTests.swift`, all pure:

- every placeholder substitutes; unknown ones pass through
- injection: titles containing `"`, `'`, backticks, `$(…)`, newlines, and a
  literal heredoc delimiter
- slug sanitization: unicode, spaces, `../`, 200-character titles
- kind → command: `spec` never gets `-w`; `plan` honours `use_worktree`
- a template override beats the default; deleting the row restores the default
- `recordLaunch` sets `executing` and logs activity with the correct actor

Plus `QA_CHECKLIST.md` §9 for the interactive pass (sheet contents, unsafe-mode
warning, Copy fallback, real Warp launch, board updating while the session runs).

## Scope estimate

Comparable to the Review Center: schema, Core engine, two UI surfaces, settings
panel. One spec, but expect a multi-task plan.
