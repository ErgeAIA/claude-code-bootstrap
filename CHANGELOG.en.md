# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.0] - 2026-06-03

### Added
- New `-InstallMode` parameter (`Minimal`/`Full`) with interactive selection, default `Minimal` (software only)
- Embed 4 user-written hooks into `setup-claude.ps1` via `$USER_HOOKS_CONTENT`, auto-written to `~/.claude/hooks/` in Full mode — **no manual placement required**
- New `Install-UserHooks` function: writes user hooks from embedded content using UTF-8 no-BOM (consistent across PS 5.1/7+)
- New `Install-SettingsJson` function: merges `GeneralConfiguration.json` and writes `~/.claude/settings.json`, **hooks take effect immediately** in Full mode
- Embedded content SHA256 checksums added to `$CHECKSUMS` (auto_format / block_dangerous / check_secrets / verify_on_stop)
- README: new execution flow chart (Mermaid format)
- README: comprehensive `GeneralConfiguration.json` field reference table (7 top-level fields + 5 allow categories + 6 deny rules)
- README: new "Install Mode" section explaining 1/2 options and parameter usage

### Changed
- `setup-claude.ps1` main flow now branches on `InstallMode` for hooks deployment and settings.json generation
- User hooks write changed from `Set-Content -Encoding UTF8` to `[IO.File]::WriteAllText` + UTF-8 no-BOM to avoid BOM interference with SHA256
- `Install-Hooks` function removed "check user-written hooks" logic (replaced by `Install-UserHooks`)
- `Show-Summary` function displays different content per install mode, Full mode additionally shows settings.json status
- README: removed redundant "License" section
- README: updated project structure comments to mark user hooks' dual identity (source file + embedded content)

### Security
- User hooks embedded content + SHA256 verification; tampering is detected and rejected
- settings.json written via `[ordered]@{}` to ensure field order matches `GeneralConfiguration.json`

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
