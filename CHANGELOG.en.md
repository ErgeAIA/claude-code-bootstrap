# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-06-03

### Fixed
- Fix `$cfg` empty initialization causing crash when writing config after native install
- Fix `$methods` install methods array with broken syntax preventing script parsing
- Fix `install.ps1` hardcoding `powershell.exe` causing `ConvertFrom-Json -AsHashtable` to fail on PS5.1
- Fix native install Job returning empty value causing version number loss

### Changed
- Switch hooks download from GitHub-only to Gitee + GitHub dual-source, prioritizing Gitee for China users
- Remove ineffective content-matching checks in UV install script and setup-claude.ps1 download, replace with explicit trust-on-first-use declaration
- `install.ps1` now prefers `pwsh.exe` (PowerShell 7+), falls back to `powershell.exe`

### Added
- Add SHA256 integrity verification for hooks and status_line downloads; delete files on checksum mismatch
- Add `checksums.txt` to maintain SHA256 hashes for hooks and status_line
- Add `scripts/update-checksums.ps1` local checksum refresh script (supports `-DryRun` preview)
- Add `.github/workflows/update-checksums.yml` GitHub Actions workflow for weekly upstream hooks change detection with auto PR
- Add dual-platform sync convention (GitHub + Gitee) to CLAUDE.md
- Add automatic cleanup of temp script file after execution in `install.ps1`

### Security
- Add SHA256 verification for hooks downloads to prevent supply-chain attack leading to RCE
- Remove bypassable weak content checks (`-match 'astral|uv'`, `-match 'Claude Code'`) to eliminate false sense of security

## [1.0.0] - 2026-06-03

### Added
- Initial release
- Claude Code one-click installation script
- Windows PowerShell workflow automation
- Hooks workflow deployment
- China network environment optimization

[Unreleased]: https://github.com/ErgeAIA/claude-code-bootstrap/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/ErgeAIA/claude-code-bootstrap/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/ErgeAIA/claude-code-bootstrap/releases/tag/v1.0.0
