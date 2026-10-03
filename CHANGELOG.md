# Changelog

All notable changes to this project are documented in this file.

## [1.2.0] - 2026-10-03

### Fixed

- **Hover feedback on the delete icon, Save and Cancel never worked.** Those handlers assigned `color` on an enclosing `RowLayout`/`Column`, which have no such property, so QML threw `TypeError: Cannot assign to non-existent property "color"` on every mouse enter/leave. Each now targets a named `id` instead of walking the parent chain.
- **A snapshot could latch the widget into a permanent "Capturing..." state.** Three of the four capture stages reset the flag on failure, but the tab-capture stage did not, and no stage had a timeout — a hung capture left every action disabled until the shell was restarted. All failure paths now funnel through one `failSnapshot()` teardown, the final assembly is wrapped in try/catch, and a 45s watchdog kills stuck processes.
- **Closing the panel mid-prompt kept a stale snapshot.** Dismissing the panel while the save prompt was open left the prompt and its captured layout alive, so reopening later offered to save a capture that was long out of date. It is now discarded on close.
- **A failed save could destroy the profile it was replacing.** The store wrote with `O_TRUNC`, so a crash, OOM kill, or full disk partway through lost the old profile *and* failed to write the new one. Saves now stage through a sibling temp file, `fsync`, then `os.replace` — a reader sees either the whole old file or the whole new one.
- **Restore always reported success.** Every generated step was suffixed `|| true`, so the script always exited 0 and the widget reported "Restored N windows" even when every launch failed — with the log holding the only evidence deleted on exit. Failed dispatches are now counted and reported as `Restored 3/5 windows`, and the log is preserved at `~/.config/omarchy/workspace-restorer/last-restore.log`.
- **A window whose class differed only in case was duplicated on restore.** Class matching was case-sensitive while every other class decision was not, so a mismatch left the live window open *and* spawned a replacement. Matching is now case-insensitive.
- **Browser relaunch raced the browser's own shutdown.** Restore closed matching browser windows and waited a fixed 1.5s before relaunching; a browser that outlived the sleep swallowed the relaunch as a command-line message and the tabs never reopened. It now polls for the process to actually exit.
- **Window counts in the restore summary were double-counted**, because a floating window that also needed moving appeared in both the move and float lists.

### Changed

- **The panel was styled with the bar's colours, not the popup's.** `Color.bar.*` painted every row with `Qt.darker(barBackground, 1.05)` — a ~2% shift against a panel background of nearly the same value, so rows read as flat as the background and ignored the active theme. The panel now uses the popup/foreground colour roles throughout.
- **Profiles past the seventh were unreachable.** The card had a fixed 400px height with no scrolling. The profile list is now a scrolling `ListView` capped at a sensible viewport.
- **The panel is now keyboard navigable.** ↑/↓ (or j/k) walks the profiles, Enter restores, Delete removes, Esc closes and Tab switches panels. Mouse and keyboard drive one shared cursor, so exactly one row is ever highlighted.
- **Deleting a profile asks first.** A single click on a 22px icon destroyed a profile irrecoverably; it now goes through a confirmation dialog.
- Rebuilt on the shell's own UI kit — `CursorSurface` rows, `PanelActionButton` with a themed destructive tint and tooltip, `PanelSeparator`, `qs.Ui.Button`/`TextField`, and `Style` spacing/typography tokens so the panel follows the user's theme instead of hardcoded pixels. Added an empty state so an empty list explains itself.
- The security-critical validators and command builders now live in a single shared module (`restoreLogic.js`) that both the widget and the test suite use, replacing two hand-maintained copies that could drift. The test suite now exercises the code that actually ships.

### Verified

- Large-profile saves were probed rather than assumed: a 221 KB snapshot (6 windows × 250 tabs, ~3.4× the 64 KiB pipe buffer) round-trips intact through the real save path. Quickshell buffers the overflow internally, so the single `write()` plus stdin close is correct.

## [1.1.3] - 2026-09-11

### Fix

- Fixed a `NameError` in the `lz4jsoncat` fallback of `scripts/capture_tabs.py`: the `shutil` import was dropped during the 1.1.2 hardening but the fallback still calls `shutil.which()`. Restored the import so the CLI fallback works when `python3-lz4` is unavailable. (Found in marketplace security review.)

## [1.1.2] - 2026-09-06

### Hardened profile store and tab capture file reads

- All profile-directory reads, writes, and deletions (create dir, list, save, load, delete) now go through a new hardened helper, `scripts/profile_store.py`, instead of shell `mkdir`/`ls`/`cat`/`rm` on user paths. Every file it touches is opened with `O_NOFOLLOW | O_NONBLOCK`, fstat-checked to be a regular file owned by the user, and read within a byte bound — a planted symlink or FIFO can no longer redirect a read or block the persistent shell on a stale profile path.
- Profile saves stream their JSON over stdin (no temp files, no shell heredocs), and both save and load enforce cardinality limits (max 512 windows, 300 tabs per window, 256 profiles) plus a size cap, so a hand-edited or corrupt profile cannot drive an oversized launch.
- Browser tab capture now reads the Chromium DevTools port file and Firefox/Chromium session files through the same held-descriptor bounded reader (no-follow, regular-file/ownership check, byte caps), bounds SNSS files, and feeds the `lz4jsoncat` fallback from a private 0600 temp copy with bounded chunked output — closing the check-then-open and unbounded-read gaps in capture.
- Restore now revalidates a loaded profile's window/tab cardinality before generating any launch command (mirrored in `restoreLogic.mjs` and the bar widget).

## [1.1.1] - 2026-08-30

### Security hardening for browser tab capture

- Bounded all untrusted local browser inputs read during tab capture: the Chromium DevTools debug port is now constrained to a bare 1-5 digit number (so a crafted `DevToolsActivePort` can no longer redirect a snapshot request to an arbitrary host) and the CDP response is capped in size.
- Bounded Firefox session-store decoding: the compressed file is stat-limited before any read and its declared uncompressed size is validated against a ceiling before decompression, so a crafted `recovery.jsonlz4` cannot force an unbounded memory allocation. The fallback decoder's output is length-checked as well.

## [1.1.0] - 2026-08-30

### Browser tabs now restore correctly

- Fixed browser tab restore when browsers are already running: no more split-screen windows (Firefox), extra session-restore tabs (Vivaldi), or windows landing on the wrong workspace.
- Changed browser windows with captured tabs are now closed and relaunched fresh at restore time, so each opened window shows exactly the tabs from your snapshot — one window, no duplicates, on the correct workspace.
- Fixed a launch-script stall that could stop a restore partway through.

> **Note:** restoring a snapshot with browser tabs will close and reopen the matching browser window. Capture snapshots without browser tabs if you prefer not to have browsers relaunched.

## [1.0.0] - 2026-08-27

Initial release.
