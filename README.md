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

The plugin uses these commands, all of which ship with a standard Omarchy install:

| Command | Package | Used for |
| --- | --- | --- |
| `hyprctl` | `hyprland` | reading clients/monitors and dispatching window moves |
| `python3` | `python` | the bundled `scripts/profile_store.py` and `scripts/desktop_launch.py` helpers |
| `bash` | `bash` | per-process `/proc` introspection during a snapshot |
| `notify-send` | `libnotify` | action feedback notifications |
| `curl` | `curl` | optional — Chromium tab capture over `--remote-debugging-port` only |

Nothing needs to be fetched or compiled: the bundled Python scripts run straight from the plugin directory, and the unit tests are developer-only. If an optional command is missing, the feature that needs it is skipped and the rest of the plugin keeps working.

## Security model

**Restore never runs a command supplied by an application.** This is the important
property, so it is worth being explicit about how it works.

A window's `/proc/<pid>/cmdline` is written by that process, not by Omarchy or by
this plugin. If a saved profile carried that string and restore executed it, any
application on your desktop would get to choose what runs on the host — a
sandboxed application could set its own argv to `sh -c …` and have it run outside
its sandbox. Quoting does not help in that case, because the entire command is the
untrusted value rather than one argument inside a trusted command.

So restore resolves every launch command from the **freedesktop application
database** instead:

1. `scripts/desktop_launch.py` reads the installed `.desktop` entries from
   `/usr/share/applications`, `/usr/local/share/applications`,
   `~/.local/share/applications` and the Flatpak export directories — all host-side
   locations a sandboxed application cannot write to.
2. The entry is matched by the window's `StartupWMClass`, falling back to the
   desktop file name, falling back to the window class itself.
3. `restoreLogic.js` tokenises the registered `Exec` line, **strips** field codes
   (`%U`, `%F`, …) instead of expanding them, and refuses the entry outright if the
   program is a shell, interpreter or process-spawning shim (`sh`, `env`, `python3`,
   `flatpak`, `sudo`, `xdg-open`, …) or contains shell metacharacters.

The captured `argv` is not stored in saved profiles at all. Profiles written by
1.2.x and earlier still contain a `command` field; it is ignored, so upgrading is
safe. A consequence worth knowing: an app with no installed `.desktop` entry now
restarts by bare class name, so per-launch flags captured from a running process
(for example `nautilus --new-window`) are no longer replayed. Installing a proper
desktop entry restores that behaviour.

Everything else the plugin runs is bounded and read-only: `hyprctl -j` for window
state, `/proc` for a process's own command line and working directory, and the
browser session files under your `$HOME` for tab capture.

## Data and removal

All state lives in `~/.config/omarchy/workspace-restorer/`:

| Path | Contents |
| --- | --- |
| `*.json` | saved layout profiles |
| `last-restore.log` | per-step restore log |

Nothing is written outside that directory, and the plugin installs no services, hooks, or background daemons. `omarchy plugin remove davedes.workspace-restorer` plus deleting that directory is a complete uninstall; also drop the `davedes.workspace-restorer` entry from `~/.config/omarchy/shell.json`.

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
