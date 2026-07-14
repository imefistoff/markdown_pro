# Project Export / Import — Design

**Date:** 2026-07-14
**Status:** Approved

## Goal

Let the user export a chosen set of projects — with their tasks, subtasks,
labels, activity history, and the markdown documents attached to them — to a
single file, and import such a file back, adding the projects to the board.

Driven entirely from the app UI. No MCP tools.

## Scope

**In:**

- Export selected projects to a `.mdproz` file (a store-only zip).
- Import a `.mdproz` file, selecting which of its projects to bring in.
- Markdown documents travel inside the bundle and are relinked or restored
  on import.

**Out:**

- Sync / merge of existing projects. Import is purely additive.
- MCP tools for export or import.
- Compression. Entries are stored uncompressed.

## Bundle format

A zip archive, extension `.mdproz`, containing:

```
manifest.json
documents/0001-auth-spec.md
documents/0002-migration-plan.md
```

Entries are **stored** (compression method 0). The archive is a valid zip:
Finder and `/usr/bin/unzip` open it. The custom extension keeps Finder from
auto-expanding it on download.

### manifest.json

```json
{
  "formatVersion": 1,
  "exportedAt": "2026-07-14T10:31:02.123Z",
  "projects": [
    {
      "name": "MarkdownPro",
      "color": "#5E6AD2",
      "archived": false,
      "createdAt": "2026-06-01T09:00:00.000Z",
      "updatedAt": "2026-07-14T08:12:44.000Z",
      "documents": [
        {
          "title": "Roadmap",
          "originalPath": "/Users/me/dev/markdown_pro/docs/roadmap.md",
          "file": "documents/0001-roadmap.md"
        }
      ],
      "tasks": [
        {
          "title": "Add export",
          "details": "…",
          "status": "in_progress",
          "priority": "high",
          "dueDate": "2026-07-20",
          "sortOrder": 3.0,
          "createdAt": "2026-07-01T11:00:00.000Z",
          "updatedAt": "2026-07-13T16:20:00.000Z",
          "labels": [{ "name": "feature", "color": "#8B5CF6" }],
          "subtasks": [{ "title": "Zip writer", "done": true, "sortOrder": 1.0 }],
          "activity": [
            {
              "actor": "claude",
              "kind": "status",
              "message": "Moved to In Progress",
              "createdAt": "2026-07-02T12:00:00.000Z"
            }
          ],
          "documents": [
            {
              "title": "Export spec",
              "originalPath": "/Users/me/dev/markdown_pro/docs/spec.md",
              "file": "documents/0002-export-spec.md"
            }
          ]
        }
      ]
    }
  ]
}
```

**No database IDs appear in the manifest.** Row IDs are meaningless on another
machine. Relationships are expressed by nesting: subtasks inside their task,
tasks inside their project.

`formatVersion` is checked on import; an unknown version is rejected with a
clear error rather than parsed optimistically.

### Documents

Each document entry has:

- `title` — from the `documents.title` column.
- `originalPath` — the absolute path the document had on the exporting machine.
- `file` — the path of the embedded copy inside the zip, or `null` if the file
  could not be read at export time (already deleted or moved).

Timestamps use `DateCoding` (ISO-8601 with fractional seconds); due dates stay
`yyyy-MM-dd`, matching the existing storage convention.

## Core

Four new files in `Core/Sources/MarkdownProCore/`:

### Zip.swift

A store-only zip writer and reader. No external dependencies, no subprocess.

- Writer: local file headers, central directory, end-of-central-directory
  record, CRC32 per entry.
- Reader: locates the end-of-central-directory record, walks the central
  directory, extracts entries by name.
- Only handles what we write: stored entries, no encryption, no zip64,
  no data descriptors. A bundle that uses anything else is rejected as
  malformed.

### ExportBundle.swift

The `Codable` manifest types. Pure data, no behavior.

### ProjectExporter.swift

Takes a `Repository` and project IDs. Reads each project through the existing
API (`listTasks`, `getTask`, `documents(projectId:)`), reads each document's
contents off disk, builds a `Zip` archive, returns its bytes.

A document whose file cannot be read is exported with `file: null` — a broken
link exports as a broken link and does not fail the export.

### ProjectImporter.swift

Takes bundle bytes and a `Repository`.

- `readManifest(_:)` parses and validates without writing anything, so the UI
  can show a preview.
- `importProjects(_:selecting:)` inserts the chosen projects.

## Import semantics

**Projects** are always created new — never merged. A name collision becomes
`Name (imported)`, then `Name (imported 2)`, and so on. A double-import
produces a visible duplicate, never a silent overwrite.

**Labels** must merge: `labels.name` is globally `UNIQUE`. An incoming label
matches an existing one by name and reuses it; a new name creates a new label.
On a color conflict the existing color wins — the label is already on the
board and other tasks use it.

**Documents:**

1. If `originalPath` exists on disk, link to it. Importing a project back onto
   the machine that produced it reconnects to the live file, and edits keep
   flowing through the reader.
2. Otherwise, if `file` is present, write the embedded copy to
   `~/Library/Application Support/MarkdownPro/Imported/<project>/<name>.md`
   and link there.
3. Otherwise (no embedded copy and no file at the original path), the document
   row is still created pointing at `originalPath`, preserving the broken link
   as it was.

**Tasks, subtasks, activity** restore verbatim: original timestamps, original
sort order, original `user` / `claude` attribution.

`Repository.createTask` stamps its own `created_at` and auto-logs a "created"
activity entry. That is wrong for import — it would clobber exported timestamps
and inject fabricated history on top of the real history being restored. So
`Repository` gains an import-specific insert path that preserves timestamps
verbatim and does not auto-log.

Each project's insert runs in a single transaction: a mid-import failure leaves
the board untouched rather than half-populated.

## UI

No new window. Two entry points:

- **File ▸ Export Projects…** and **File ▸ Import Projects…** in the menu bar.
  The app has no `.commands` block today; this adds one.
- **Export…** in the sidebar's per-project context menu (which currently holds
  only "Delete Project"), opening the same sheet with that project pre-checked.

**Export sheet:** every project listed with a checkbox and its task count.
Archived projects appear but start unchecked. Confirming opens an `NSSavePanel`
defaulting to `MarkdownPro Export <yyyy-MM-dd>.mdproz`.

**Import sheet:** an `NSOpenPanel` picks the file; the app reads the manifest
and shows what it contains — each project, its task count, and how many of its
documents will relink to a live file versus restore from the embedded copy —
with checkboxes. Nothing is written until the user confirms.

Errors surface through the existing `store.errorMessage` alert. Import goes
through `Repository`, so the app's `data_version` polling picks up the new rows
on its own.

`Store` gains passthroughs: `exportProjects(ids:to:)`, `readImportBundle(url:)`,
`importProjects(from:selecting:)`.

## Testing

`Core` tests, against a scratch database via `MARKDOWNPRO_DB`:

- **Zip round-trip** — entries written then read back byte-for-byte; the
  produced archive passes `/usr/bin/unzip -t`.
- **Export → import round-trip** — tasks, subtasks, labels, activity and
  documents come back with fields and timestamps intact.
- **Name collision** — importing into a board that already has the project name
  produces `Name (imported)`, leaving the original untouched.
- **Label merge** — an incoming label with an existing name reuses that label
  and keeps the existing color.
- **Documents** — both branches: relink when `originalPath` exists, restore
  from the embedded copy when it does not.
- **Malformed bundle** — an unknown `formatVersion` and a non-zip file both
  fail with a clear error and write nothing.

Then a manual pass in the app: export a project, delete it, import it back.

## Non-goals / risks

- Store-only zip means the archive is roughly the size of its contents. Fine
  for markdown.
- The bundle carries no schema version of the *database*. `formatVersion`
  covers the bundle; if the DB schema gains columns later, the importer must be
  updated to fill them with defaults.
