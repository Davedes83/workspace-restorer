<img width="1874" height="525" alt="Workspace Restore" src="https://github.com/user-attachments/assets/59c65425-2446-405c-aaa2-2636177fa2fb" />

---
# Workspace Restorer

An Omarchy shell plugin (Quickshell) for Hyprland that snapshots your window layout and brings it back on demand as named profiles.

## Features

- **Snapshot** — Capture every open window: app, workspace, screen position, size, floating/fullscreen state, and working directory
- **Restore** — Re-launch missing apps directly onto the exact workspace they were on; move already-running windows back to the right workspace
- **Conflict Detection** — Avoids duplicate spawns; repositions existing windows instead of relaunching them
- **Layout Restoration** — Restores floating and fullscreen state for matched and spawned windows
- **Desktop Notifications** — Feedback on snapshot/save/restore/delete actions

## Installation

```bash
# Clone the repo
gh repo clone Davedeses/workspace-restorer ~/.config/omarchy/plugins/davedes.workspace-restorer

# Or manually copy to the plugin directory
cp -r workspace-restorer ~/.config/omarchy/plugins/davedes.workspace-restorer
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

## Usage

1. Click the bar widget to open the panel
2. Click **Take Snapshot** to capture your current window layout
3. Enter a name for the profile (e.g., "coding", "media")
4. Click a profile name to restore that layout
5. Click the delete action to remove a profile

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

## Buy Me A Coffee
PayPal @DavidDesousa13

## License

MIT
