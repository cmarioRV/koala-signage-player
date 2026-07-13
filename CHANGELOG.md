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

### Changed

- Heartbeats now report the locally installed playlist version when available
- Added a macOS-compatible Unix socket type while preserving Linux behavior
