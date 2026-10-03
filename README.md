[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/O3N726LJT4)
<img width="1874" height="525" alt="Workspace Restore" src="https://github.com/user-attachments/assets/59c65425-2446-405c-aaa2-2636177fa2fb" />

---
# Workspace Restorer

An Omarchy shell plugin (Quickshell) for Hyprland that snapshots your window layout and brings it back on demand as named profiles.

## Features

- **Snapshot** — Capture every open window: app, workspace, screen position, size, floating/fullscreen state, and working directory
- **Restore** — Re-launch missing apps directly onto the exact workspace they were on; move already-running windows back to the right workspace
- **Conflict Detection** — Avoids duplicate spawns; repositions existing windows instead of relaunching them
- **Layout Restoration** — Restores floating and fullscreen state for matched and spawned windows
- **Browser Tabs** — Captures open Firefox/Chromium tabs and reopens them with the restored window
- **Keyboard Navigation** — Walk, restore, and delete profiles with ↑/↓, Enter, and Delete
- **Desktop Notifications** — Feedback on snapshot/save/restore/delete actions

## Installation

```bash
omarchy plugin add https://github.com/Davedes83/workspace-restorer.git --enable
```

Then add the plugin to your `~/.config/omarchy/shell.json`:

```json
{
  "bar": {
    "layout": {
      "right": [
        { "id": "davedes.workspace-restorer" }
      ]
    }
  }
}
```

Restart the shell:

```bash
omarchy restart shell
```

## Remove

```bash
omarchy plugin remove davedes.workspace-restorer
```

## Usage

1. Click the bar widget to open the panel
2. Click **Take Snapshot** to capture your current window layout
3. Enter a name for the profile (e.g., "coding", "media")
4. Click a profile name — or select it with ↑/↓ and press Enter — to restore that layout
5. Click the delete action (or press Delete) to remove a profile; you'll be asked to confirm

### Keyboard

The panel is fully keyboard navigable, so you can restore a layout without
leaving the keys:

| Key | Action |
| --- | --- |
| `↑` / `↓` or `k` / `j` | Move between profiles |
| `Enter` | Restore the selected profile |
| `Delete` | Delete the selected profile (asks first) |
| `Esc` | Close the panel |
| `Tab` | Switch to the next bar panel |

Mouse and keyboard share a single cursor, so exactly one profile is highlighted
at a time. Dismissing the panel while the save prompt is open discards the
pending snapshot.

## How It Works

- Snapshots are saved as JSON profiles in `~/.config/omarchy/workspace-restorer/`
- State is captured via `hyprctl -j clients` and `hyprctl -j monitors`
- Command line and working directory are read per-process from `/proc/<pid>` (keyed by PID, so window data never misaligns)
- Restore uses the Omarchy Lua bridge (`hl.dsp.*` dispatchers) via `hyprctl dispatch` to move windows and workspaces, since plain Hyprland command syntax is unavailable through the bridge
- Missing windows are launched by focusing their target workspace first, then starting the app — so each opens directly where it belongs
- A detached safety pass re-checks spawned windows and corrects any that ignore the focused workspace, without delaying the restore notification

## Requirements

- [Omarchy](https://omarchy.org/) Linux
- Hyprland compositor
- Quickshell (for the shell framework)

## Troubleshooting

**A restore says "partially failed".** Some dispatches were rejected by Hyprland.
The full per-step log is kept at:

```
~/.config/omarchy/workspace-restorer/last-restore.log
```

It records every move, float, focus and launch attempt with its output, so you
can see which window refused to go where.

**A browser's tabs didn't come back.** Tab capture only works for browsers that
keep a readable session file (Firefox always; Chromium only when launched with
`--remote-debugging-port` or via the SNSS session files). Restore closes and
relaunches a browser window whose tabs were captured, so expect a brief flash.

## License

MIT
