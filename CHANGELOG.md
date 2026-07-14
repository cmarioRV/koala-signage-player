# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- Initial project structure
- Swift Package
- MPV integration
- JSON IPC support
- Automatic playlist generation
- Automatic playlist reload
- Raspberry Pi support
- Video Wall support
- Remote manifest polling and decoding
- Installed-versus-remote playlist version comparison
- Manifest contract tests
- Missing asset downloads into an isolated staging directory
- Partial-file handling and expected-size checks for remote downloads
- Manifest filename and relative URL safety validation
- SHA-256 validation for downloaded and existing assets
- In-memory verification cache to avoid hashing unchanged files on every poll
- Immutable versioned releases for complete remote manifests
- Atomic remote playlist publication and MPV reload
- Installed playlist identity and version persistence
- Remote playlist restoration after service or device restart
- Serialized local and remote playlist updates
- Post-activation staging cleanup
- Obsolete release cleanup with active and previous release retention
- Backward-compatible scheduled manifest decoding
- Scheduled asset prefetching without changing active playback
- Cross-playlist filename conflict validation
- Local schedule evaluation using each schedule's timezone and weekday mask
- Cross-midnight schedule evaluation using the schedule's starting weekday
- Deterministic priority resolution for overlapping schedules
- Immutable release preparation for the currently selected scheduled playlist
- Automatic activation of the highest-priority active scheduled playlist
- Automatic fallback restoration when no schedule is active
- Scheduled staging retention during schedule transitions
- Atomic persistence of the last successfully fetched manifest
- Offline schedule and fallback reevaluation from the cached manifest
- Verified asset recovery from retained releases without network access
- MPV current-path inspection through JSON IPC
- Current media asset reporting in Player heartbeats

### Changed

- Heartbeats now report the locally installed playlist version when available
- Added a macOS-compatible Unix socket type while preserving Linux behavior
- Existing configurations default staging storage to a sibling of the content directory
- Raspberry installer now deploys the current player binary and preserves existing configuration
- systemd deployment now creates all runtime directories and starts the updated service
- Player logs now write directly to standard output for immediate systemd journal visibility
- Raspberry deployment now uses `install.sh` for provisioning and `deploy-rpi.sh` for upgrades
- Routine deployments preserve configuration, synchronize `appVersion`, and roll back failed releases
- Example Player version updated to 0.1.12
