# Syncest

Syncest is a KOReader plugin for syncing reading data to a WebDAV folder you control. It is based on the Readest KOReader plugin, but with a different goal: keep KOReader progress, annotations, reading stats, vocabulary, and optional book files in one self-hosted central location instead of tying that data to a single device.

The WebDAV folder becomes the source of truth, so multiple KOReader devices can push and pull from the same place. It also keeps the synced files readable enough for other tools, such as an Obsidian note generator, to inspect and reuse.

Syncest was made primarily to be used alongside [Obsidian MoonSync](https://github.com/titandrive/Obsidian-MoonSync), an Obsidian plugin for working with the synced reading data. MoonSync is optional: Syncest can also be used standalone as a KOReader-to-WebDAV sync plugin.

## Features

- Sync reading progress per book.
- Keep a cross-device history of recent progress pushes and return to an older saved location.
- Sync annotations, including deleted annotation tombstones.
- Sync KOReader reading statistics.
- Sync vocabulary builder entries.
- Maintain a Syncest book library with optional book and cover upload/download.
- Push or pull all sync data except book files/catalog from one menu command.
- Mirror progress pushes to KOReader KOSync when enabled.
- Auto sync on common reading events:
  - Push progress every X page turns.
  - Push progress when a chapter is finished.
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

Open `Syncest` -> `Syncest: Not configured` -> `Configure WebDAV` and choose a WebDAV target through KOReader's cloud storage picker. After configuration, the connection entry shows `Syncest: Idle` until the first sync request finishes. It then shows `Syncest: Connected` after a successful request or `Syncest: Disconnected` after a failed request. Syncest stores all data under the folder path configured there.

This works well with self-hosted storage such as Nextcloud, a WebDAV server exposed over a VPN, or any other WebDAV-compatible backend KOReader can reach.

## Notifications

Open `Syncest` -> `Notifications` to enable or disable status notifications for progress, annotations, statistics, vocabulary, books and library operations, and connection changes. All notification types are enabled by default.

These controls suppress routine status notifications. Required confirmations and actionable error dialogs remain visible.

## WebDAV Layout

Syncest writes JSON files and optional book assets under the configured WebDAV folder:

```text
library.json
stats.json
vocab.json
sync/
  <book-hash>/
    progress.json
    progress-history/
      devices.json
      <device-id>.json
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

`progress-history/` stores recent progress-push snapshots for the book. Each KOReader installation writes only to its own `<device-id>.json` file, avoiding cross-device write collisions, while `devices.json` lets the history browser discover every device. The latest 25 entries per device are retained. This history is separate from `progress.json`: normal syncing still uses `progress.json` as the current location, while the history files provide older locations that can be restored manually.

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

Resume progress pulls use short background retries while Wi-Fi, DNS, or a VPN reconnects. Syncest only reports a disconnection if the final attempt fails, and update checks wait until the progress pull finishes.

If an automatic push fails, Syncest remembers the affected progress, annotations, stats, or vocabulary as pending. Pending changes survive KOReader restarts and are pushed once a resume, network-online callback, manual sync, or other successful Syncest request confirms that the connection is available again. Syncest does not poll the server on a recurring timer.

Global pulls happen when KOReader/Syncest starts:

- Pull stats on app open.
- Pull vocab on app open.

Pushes happen when data changes or when a book closes:

- Push every X page turns.
- Optionally push reading progress when a chapter is finished.
- Push reading progress on book close.
- Optionally push reading progress on app suspend.
- Push annotations on change.
- Push annotations on book close.
- Optionally push annotations on app suspend.
- Push stats on book close.
- Optionally push stats on app suspend.
- Push vocab on word lookup.

## Progress History

Progress History is a cross-device list of recent reading locations. It is intended as a recovery tool when you lose your place, accidentally jump elsewhere, or want to return to a location that was previously pushed from another KOReader device.

History begins with the first successful progress push made by a version of Syncest that supports this feature. It does not reconstruct positions that existed before the feature was installed. Automatic and manual progress pushes are labeled separately, and manual pushes are recorded even when the current location is already synced.

To use it:

1. Open the relevant book.
2. Open the main `Syncest` menu.
3. Select `Progress history`, located immediately above `Push reading progress now` and `Pull reading progress now`.
4. Select the first row to cycle between `Automatic and manual`, `Automatic only`, and `Manual only`.
5. Select a saved entry and confirm `Go` to return to that location.

The window shows the current book's title and author. Each entry shows its timestamp, whether it was automatic or manual, its saved page/location, and the device that created it.

The number of entries displayed can be set to 10 or 25 under `Syncest` -> `Sync settings` -> `Progress` -> `Progress history entries`. Cloud retention is capped at the latest 25 entries per device for each book.

`Syncest: Open progress history` is also available as a reader dispatcher action, so Progress History can be assigned to a KOReader gesture, profile, keyboard shortcut, or other dispatcher-driven action.

## Manual Sync

When a book is open, Syncest shows manual commands for that book:

- Push/pull reading progress.
- Browse and restore progress history.
- Push/pull annotations.

The main Syncest menu also includes:

- Push/pull stats.
- Push/pull vocab.
- Push/pull the Syncest book library and book files.
- Push all / Pull all for progress, annotations, stats, and vocab.

`Push all` and `Pull all` do not upload or download book files or the book catalog. Book library sync is kept separate on purpose.

Selecting a cloud-only book in the Syncest Library opens download options for choosing the destination folder, changing the filename, and viewing book information. After downloading, Syncest asks whether to read the book immediately.

`Push books now` refreshes the cloud catalog, scans the complete local library, and reconciles all eligible catalog entries and book files instead of relying on the incremental sync cursor. `Pull books now` shows the current missing-book count and destination folder for confirmation, then refreshes the cloud catalog and downloads every cloud book that is not already present locally. Both operations verify books by hash, so an existing copy is updated or skipped instead of duplicated. Opening the Syncest Library refreshes its cloud catalog but does not automatically download every book.

If an archive folder is configured, pushing the Syncest book library skips books inside it.

Manual stats pushes and pulls reconcile the complete statistics history. Automatic stats sync uses an incremental cursor for efficiency.

## KOSync Mirroring

If KOReader's KOSync plugin is also configured, enable `Mirror progress to KOSync` in Syncest settings. When enabled, Syncest asks KOSync to mirror progress pushes during manual progress pushes, page-turn and chapter-finish autosync, and book-close progress pushes.

## Updates

Syncest can check GitHub releases in the background. When an update is available, it can notify you, prompt to install, and then prompt to quit KOReader after installation so the new plugin code loads cleanly.

Manual update checks are available from `Syncest` -> `Sync settings` -> `Updates`.

## Notes

Syncest is designed around self-hosting. It assumes your WebDAV storage is yours, reachable from each device, and durable enough to be the central copy of your reading data.

The plugin uses short network timeouts and background jobs for sync operations where possible, so a missing VPN connection or unreachable WebDAV server should fail gracefully instead of freezing or crashing KOReader.
