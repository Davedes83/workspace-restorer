````markdown
# Workspace Restorer

An Omarchy shell plugin for Hyprland that snapshots and restores workspace layouts as named profiles.

## Features

- **Snapshot** — Capture all open windows, their positions, workspaces, and monitor assignments
- **Restore** — Re-launch windows into their exact workspace and monitor layout
- **Smart Conflict Detection** — Matches existing windows by class name; only kills windows in target workspaces
- **Cross-Contamination Prevention** — Isolated restoration prevents windows from other workspaces being affected
- **Layout Restoration** — Applies tiling ratios and floating positions after spawning
- **Browser Cache Clearing** — Clears session files from Vivaldi, Firefox, Chrome, and Chromium
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
- Intelligently matches existing windows by class name before restoration
- Only kills windows in the target workspace scope (prevents cross-contamination)
- Clears browser session files to prevent old tabs/windows from restoring
- Uses `hyprctl dispatch exec` for window spawning with workspace/monitor rules
- Windows are spawned with 300ms delays to avoid overwhelming the compositor
- Layout ratios are applied after a 1-second settling period

## Profile Structure

Each snapshot is stored as a JSON file containing:
- `profileId` — Unique identifier for the profile
- `timestamp` — When the snapshot was taken
- `windows` — Array of window objects with class, command, workspace, position, size, etc.
- `monitors` — Monitor configuration at snapshot time

## Requirements

- [Omarchy](https://omarchy.org/) Linux
- Hyprland compositor
- Quickshell (for the shell framework)

## License

MIT
````
