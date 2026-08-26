# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- Smart window matching by class name during restoration
- Profile ID tracking for future extensibility
- Expanded browser cache clearing (Firefox, Chrome, Chromium support)
- Workspace isolation mode to prevent cross-contamination

### Changed
- Restoration now only kills windows within target workspace scope
- Improved window deduplication logic with explicit matching
- Better documentation of restoration process

### Fixed
- Windows from other workspaces no longer killed during restore
- Browser sessions from previous profiles no longer leak into new profiles
- Incorrect windows no longer re-opened due to aggressive kill approach
