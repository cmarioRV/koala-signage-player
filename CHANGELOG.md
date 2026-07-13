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

### Changed

- Heartbeats now report the locally installed playlist version when available
- Added a macOS-compatible Unix socket type while preserving Linux behavior
- Existing configurations default staging storage to a sibling of the content directory
