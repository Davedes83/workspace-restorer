# Workspace Restorer

An Omarchy shell plugin for Hyprland that snapshots and restores workspace layouts as named profiles.

## Features

- **Snapshot** — Capture all open windows, their positions, workspaces, and monitor assignments
- **Restore** — Re-launch windows into their exact workspace and monitor layout
- **Conflict Detection** — Avoids duplicate spawns; moves already-running windows to the correct workspace
- **Layout Restoration** — Applies tiling ratios and floating positions after spawning
- **Desktop Notifications** — Feedback on snapshot/restore/delete actions

## Installation

```bash
# Clone the repo
gh repo clone Davedes83/workspace-restorer ~/.config/omarchy/plugins/davedes.workspace-restorer

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

1. Click the **󰆞** icon in the top bar to open the panel
2. Click **Take Snapshot** to capture your current window layout
3. Enter a name for the profile (e.g., "coding", "media")
4. Click a profile name to restore that layout
5. Click **󰆴** to delete a profile

## How It Works

- Snapshots are saved as JSON files in `~/.config/omarchy/workspace-restorer/`
- Uses `hyprctl -j clients` and `hyprctl -j monitors` for state capture
- Uses `hyprctl dispatch exec` for window spawning with workspace/monitor rules
- Windows are spawned with 300ms delays to avoid overwhelming the compositor
- Layout ratios are applied after a 1-second settling period

## Requirements

- [Omarchy](https://omarchy.org/) Linux
- Hyprland compositor
- Quickshell (for the shell framework)

## License

MIT
