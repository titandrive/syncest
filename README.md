# Syncest

Syncest is a KOReader plugin for syncing reading data to a WebDAV folder you control. It is based on the Readest KOReader plugin, but with a different goal: keep KOReader progress, annotations, reading stats, vocabulary, and optional book files in one self-hosted central location instead of tying that data to a single device.

The WebDAV folder becomes the source of truth, so multiple KOReader devices can push and pull from the same place. It also keeps the synced files readable enough for other tools, such as an Obsidian note generator, to inspect and reuse.

Syncest was made primarily to be used alongside [Obsidian MoonSync](https://github.com/titandrive/Obsidian-MoonSync), an Obsidian plugin for working with the synced reading data. MoonSync is optional: Syncest can also be used standalone as a KOReader-to-WebDAV sync plugin.

## Features

- Sync reading progress per book.
- Sync annotations, including deleted annotation tombstones.
- Sync KOReader reading statistics.
- Sync vocabulary builder entries.
- Maintain a Syncest book library with optional book and cover upload/download.
- Push or pull all sync data except book files/catalog from one menu command.
- Mirror progress pushes to KOReader KOSync when enabled.
- Auto sync on common reading events:
  - Push progress every X page turns.
  - Push progress, stats, and annotations on book close.
  - Push annotations when they change.
  - Push vocab after word lookup.
  - Pull progress and annotations on book open, with an optional stats pull.
  - Pull stats and vocab on app open.
- Background update checks with in-plugin install prompts.

## Installation

1. Download `syncest.koplugin.zip` from the latest GitHub release.
2. Unzip it into KOReader's `plugins` folder so the path is:

   ```text
   koreader/plugins/syncest.koplugin/
   ```

3. Restart KOReader.
4. Open the KOReader top menu and go to `Tools` -> `More tools` -> `Syncest`.

After Syncest is installed, future updates can be installed from `Syncest` -> `Sync settings` -> `Updates`.

## Setup

Open `Syncest` -> `Configure WebDAV account` and choose a WebDAV target through KOReader's cloud storage picker. Syncest stores all data under the folder path configured there.

This works well with self-hosted storage such as Nextcloud, a WebDAV server exposed over a VPN, or any other WebDAV-compatible backend KOReader can reach.

## WebDAV Layout

Syncest writes JSON files and optional book assets under the configured WebDAV folder:

```text
library.json
stats.json
vocab.json
sync/
  <book-hash>/
    progress.json
    annotations.json
    _<Book Title>.json
books/
  <book-hash>/
    <book-hash>.<ext>
    cover.png
    _<Book Title>.json
```

The `<book-hash>` folder names are stable machine identifiers. The `_<Book Title>.json` marker files make the folders human-readable and provide a stable metadata target for external automation.

## Synced Data

`progress.json` stores the current reading location and related dynamic progress fields for a single book. When available, it also carries the book's current `readingStatus` and `readingStatusUpdatedAt` so progress-only sync workflows can see the same status that appears in `library.json`.

`annotations.json` stores notes and highlights for a single book. Deleted annotations are synced as tombstones so another device can remove the same annotation instead of resurrecting it.

`stats.json` stores reading-stat rows from KOReader's statistics database.

`vocab.json` stores vocabulary builder entries.

`library.json` stores the Syncest book catalog: hashes, titles, authors, formats, reading status, timestamps, and metadata used by the Syncest Library view.

The marker files under `sync/<book-hash>/` and `books/<book-hash>/` use the same rich metadata shape. They store static book metadata such as title, author/authors, promoted identifiers like ISBN, Google Books ID, Calibre ID, and UUID when available, format, book filename, cover filename, source title, timestamps, and a cleaned KOReader metadata payload. Normal progress/annotation sync queues sync marker maintenance as low-priority background work, so metadata never blocks the actual reading data sync.

## Auto Sync Behavior

Auto sync can be enabled or disabled from the main Syncest menu. Individual auto-sync actions live under `Syncest` -> `Sync settings`.

Book-specific pulls happen when a book opens:

- Pull reading progress on book open.
- Pull annotations on book open.
- Optionally pull stats on book open.

Optional resume pulls can also run when KOReader returns to the foreground with a book already open:

- Pull reading progress on app resume.

Global pulls happen when KOReader/Syncest starts:

- Pull stats on app open.
- Pull vocab on app open.

Pushes happen when data changes or when a book closes:

- Push every X page turns.
- Push reading progress on book close.
- Optionally push reading progress on app suspend.
- Push annotations on change.
- Push annotations on book close.
- Optionally push annotations on app suspend.
- Push stats on book close.
- Optionally push stats on app suspend.
- Push vocab on word lookup.

## Manual Sync

When a book is open, Syncest shows manual commands for that book:

- Push/pull reading progress.
- Push/pull annotations.

The main Syncest menu also includes:

- Push/pull stats.
- Push/pull vocab.
- Push/pull the Syncest book library.
- Push all / Pull all for progress, annotations, stats, and vocab.

`Push all` and `Pull all` do not upload or download book files or the book catalog. Book library sync is kept separate on purpose.

Manual stats pushes and pulls reconcile the complete statistics history. Automatic stats sync uses an incremental cursor for efficiency.

## KOSync Mirroring

If KOReader's KOSync plugin is also configured, enable `Mirror progress to KOSync` in Syncest settings. When enabled, Syncest asks KOSync to mirror progress pushes during manual progress pushes, page-turn autosync, and book-close progress pushes.

## Updates

Syncest can check GitHub releases in the background. When an update is available, it can notify you, prompt to install, and then prompt to quit KOReader after installation so the new plugin code loads cleanly.

Manual update checks are available from `Syncest` -> `Sync settings` -> `Updates`.

## Notes

Syncest is designed around self-hosting. It assumes your WebDAV storage is yours, reachable from each device, and durable enough to be the central copy of your reading data.

The plugin uses short network timeouts and background jobs for sync operations where possible, so a missing VPN connection or unreachable WebDAV server should fail gracefully instead of freezing or crashing KOReader.
