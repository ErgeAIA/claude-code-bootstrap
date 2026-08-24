# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **setup-claude.ps1**: Native binary download now uses synchronous streaming with a real-time progress bar (`Write-Progress`, showing downloaded/total MB and percent), and prints the target version, size and total timeout upfront; total timeout is controlled by `-InstallTimeout` (replaces the background Job, which could not display progress on the main console).
- **setup-claude.ps1**: Hook deployment now downloads in parallel (`ForEach-Object -Parallel`, concurrency 4 with exponential backoff retries of 2/5/10s plus random jitter), significantly speeding up Full-mode downloads of the 10 hooks + status_line.
- **setup-claude.ps1**: When an installed Claude Code has a newer release, the script now shows a prompt and asks whether to upgrade immediately (defaults to yes — just press Enter; type `n` to skip; yes runs the same upgrade flow as `-Upgrade`; network/version-parse failures are silent and do not block installation).

### Changed
- **setup-claude.ps1**: Upgrades (`-Upgrade` or interactive) now use three-tier fallback instead of native-only: on native failure it falls back to winget (Microsoft CDN, usually better reachability in China) then npm; an exact `-ClaudeVersion` still uses native only (winget/npm manifests lag behind and cannot guarantee an exact version). If the version is unchanged after upgrade, a hint about leftover old installs is shown.
- **setup-claude.ps1**: Native install default wait timeout raised from 60s to 180s, and the per-request download timeout from 60s to 300s (the win32-x64 binary is ~215MB; 60s would require 3.5MB/s+ average, easily exceeded on normal/VPN networks); `-InstallTimeout` remains configurable.

### Fixed
- **setup-claude.ps1**: Fixed the interactive upgrade (`Test-ClaudeUpdate`) wrapping the `Upgrade-ClaudeCode` call inside a silent catch, which swallowed upgrade failures (e.g. download timeout) so the UI showed "upgrade started" but nothing happened — the upgrade call now sits outside the try block and failures surface as a normal FATAL error.
- **setup-claude.ps1**: Fixed the `$HOOK_SOURCES` disler hook base URLs missing the `/hooks/` path segment, which caused 404s on download (previously all 6 disler hooks failed to deploy in Full mode).

## [1.7.0] - 2026-08-24

### Added
- **setup-claude.ps1**: Added `-Upgrade`, which upgrades Claude Code to the latest stable release by default or to an exact release when combined with `-ClaudeVersion <version>`. Upgrades only replace Claude Code itself, leave hooks and settings untouched, and use the native release package with manifest, file-size, and SHA256 validation; winget/npm are not used because they cannot reliably pin an exact version.
- **README.md**: Added command examples for upgrading to the latest stable release and an exact version.
- **hooks/auto_format.py**: After a successful format, the hook now tells Claude via `hookSpecificOutput.additionalContext` that the file was rewritten on disk, preventing later Edit/MultiEdit failures caused by mismatched in-memory content.
- **hooks/tests/test_hooks.py**: Added pytest regression tests for the 4 hooks (14 cases covering dangerous-command blocking, secret detection, formatter selection, checker selection); run with `uv run --with pytest pytest hooks/tests/`.
- **scripts/smoke-test.ps1**: Added smoke tests for the settings.json merge logic (8 assertions; extracts the real functions from `setup-claude.ps1` via AST, verifying permissions union/dedup, hook dedup by command, and user-priority `defaultMode`).

### Changed
- **PowerShell requirement**: Raised from 5.1+ to **7+** (README and `Test-Prerequisites` updated; scripts are UTF-8 without BOM, and 5.1 decodes them as system GBK, corrupting Chinese text or failing to parse).
- **setup-claude.ps1**: Hook/status_line deployment failures now produce a prominent warning at the end of installation (no longer silent, but installation is not aborted to tolerate flaky networks).
- **README.md**: Documented how hooks are updated (existing files are skipped; to upgrade, delete the corresponding files under `~/.claude/hooks/` and re-run).

### Fixed
- **.github/workflows/update-checksums.yml**: Fixed a cascading failure in the `Create Pull Request` step where `Author identity unknown` caused `git commit` to fail without aborting the flow, resulting in an empty branch being pushed and `gh pr create` failing. Added a `Configure git identity` step before commit that explicitly sets `github-actions[bot]` `user.name`/`user.email`, and sets `core.quotepath=false` to prevent Chinese filenames from being octal-escaped
- **.github/workflows/update-checksums.yml**: Fixed `git push` being rejected with `fetch first` when a previous failed run left an empty `update-checksums/<date>` branch on the remote. Branch name now appends `-<github.run_id>` for uniqueness across runs, eliminating the need for force-push
- **.github/workflows/update-checksums.yml**: Fixed the workflow generating weekly PRs with no real checksum changes — the CI now reuses `scripts/update-checksums.ps1` (compares old vs new SHA256 first, exits without rewriting files when unchanged) and the checksums output format is unified (comment alignment, trailing newline), removing format-noise false positives

### Security
- **README.md**: Disclosed the security model boundary of the default `defaultMode=bypassPermissions` — dangerous-command blocking relies on hook regex blacklists, which are a "speed bump" rather than a security boundary (hooks fail open on exceptions); suggested switching to `ask` on sensitive machines

## [1.6.1] - 2026-06-04

### Changed
- **setup-claude.ps1**: User hooks changed from embedded script content to repository download, unified with disler hooks; script size reduced from 73KB / 1897 lines to 52KB / 1257 lines (-28%)
- **scripts/update-checksums.ps1**: Added user hooks download source (ErgeAIA repo), removed legacy embedded content preservation logic
- **.github/workflows/update-checksums.yml**: Added user hooks checksum refresh support (11 files = 7 disler + 4 user-written); downloads now wrapped in try/catch/finally for isolation, single-file failure annotated with `::error::` and `exit 1`; replaced `Get-Content`/`Set-Content` with `[System.IO.File]::ReadAllText/WriteAllText` + UTF-8 no-BOM (consistent with encoding conventions); replaced conditional padding calculation with `[Math]::Max`

## [1.6.0] - 2026-06-04

### Added
- **setup-claude.ps1**: Install mode selection adds `[0] Exit` option; `[1]` label changed from "recommended" to "default"
- **setup-claude.ps1**: ASCII art welcome banner with block-character ErgeAIA logo + author credit "宝藏二哥AIA"
- **install.ps1**: Two-stage bootstrap — downloads script with `curl.exe` (preserves UTF-8) then re-executes via `-File`, fixing Chinese garbled output in `iwr | iex`

### Changed
- **setup-claude.ps1**: `Test-Prerequisites` refactored as environment report — collects all check results, then prints a formatted table (pass/suggest/optional/block), no longer `exit 1` midway
- **setup-claude.ps1**: Main flow reordered: environment check before install mode selection (dependencies first)
- **install.ps1**: Removed UAC auto-elevation (`Start-Process -Verb RunAs -Wait` hangs when UAC dialog is hidden)
- **install.ps1**: Bootstrap dual-source download (Gitee priority + GitHub fallback) for faster CDN propagation
- **setup-claude.ps1**: UV auto-install uses `Start-Process -NoNewWindow -Wait` synchronous subprocess, avoiding `Stop-Job` `PipelineStoppedException` that bypasses try/catch
- **setup-claude.ps1**: Added try/catch around `Test-Prerequisites` call for defensive error handling

### Fixed
- **setup-claude.ps1**: Stray closing brace after `Test-Prerequisites` refactor caused parser error
- **install.ps1**: `@(...) + $args` as `-ArgumentList` value throws `ParameterBindingException` in `Invoke-Expression` context; assign to variable first
- **install.ps1**: Duplicate lines from edit caused try/catch block parse failure

## [1.5.0] - 2026-06-04

### Added
- **scripts/refresh-user-hook-hash.ps1**: User-written hooks hash refresh utility, preventing SHA256 calculation errors caused by UTF-8 mis-decoded as GBK
- **CLAUDE.md**: New "Complete Commit Workflow" convention section (5 steps: CHANGELOG → README → review → commit → dual-platform push)

### Changed
- **hooks/verify_on_stop.py**:
  - Parallelize 3 checkers with `ThreadPoolExecutor`, worst-case reduced from 210s to 90s
  - Refactored to `Checker` dataclass data-driven architecture
  - TypeScript runner expanded to 5 lockfiles (pnpm/bun/yarn/npm + npx fallback)
  - Sorted by timeout ascending (Python 30s → TS/Rust 90s)
  - Added `VERIFY_ON_STOP_SKIP` env var to skip specified checkers
- **hooks/auto_format.py**: Data-driven architecture, `FORMATTERS` list replaces if-elif chain, `run_silent` returns `bool`
- **hooks/block_dangerous.py**: Rules upgraded to `Rule` NamedTuple (with severity/why), regex precompiled, JSON+stderr dual-channel output
- **hooks/check_secrets.py**: PostToolUse semantic fix (using `hookSpecificOutput.additionalContext`), path matching exactification, regex precompiled, secret patterns expanded to 15 types
- **setup-claude.ps1**: Replaced 4 occurrences of `Get-Content`/`Set-Content` with `[System.IO.File]::ReadAllText`/`WriteAllText` (UTF-8 no BOM, consistent with encoding conventions)
- **install.ps1**: Auto-detect admin privilege at entry; non-admin triggers UAC prompt and self-restart
- **setup-claude.ps1**: `Test-Prerequisites` shows recommended marker for PowerShell 7.x; warning for 5.1 with upgrade hint (soft warning, non-blocking)
- **README.md**: Quick start updated from "run as administrator" to "script auto UAC elevation"
- **CLAUDE.md**: refresh-user-hook-hash.ps1 description fixed; `core.quotepath` downgraded from "mandatory" to "suggested"
- **setup-claude.ps1**: Simplified hooks download from Gitee + GitHub dual-source to GitHub-only (users must reach api.anthropic.com, so GitHub unavailability is unrealistic); `Invoke-DownloadFile` parameter simplified from `[string[]]$Urls` to `[string]$Url`
- **scripts/update-checksums.ps1**: Synced to GitHub-only download

### Fixed
- **install.ps1**: Content validation threshold 100→1000+CmdletBinding; UTF-8 no-BOM write; 3 retries per mirror; exit code captured before finally
- **scripts/update-checksums.ps1**: Regex supports uppercase filenames; UTF-8 no-BOM; added user hook checksum preservation logic
- **setup-claude.ps1**: Embedded content updates synchronized
- **setup-claude.ps1**: Recovered all garbled Chinese (183 lines) from git history (UTF-8→GBK→UTF-8→GBK multi-round mis-decoding)
- **GeneralConfiguration.json**: Removed zero-width spaces (U+200B) in `Read(**/id_rsa)` and `Read(**/id_ed25519)`
- **install.ps1**: Incorrect `iex -InstallMode Full` example in comments (parameter would be parsed by iex)
- **setup-claude.ps1**: `ConvertFrom-Json -AsHashtable` crashes on PS 5.1 (added `ConvertFrom-JsonToHashtable` compat function with manual PSCustomObject conversion)
- **install.ps1**: Catch `Win32Exception` when UAC is denied, show friendly message instead of raw exception stack
- **install.ps1**: Chinese garbled when run via `iwr | iex` (`.Content` property decodes UTF-8 response using system default GBK; switched to `-OutFile` for raw byte write)
- **hooks/check_secrets.py**: `search()` → `finditer()`, detects multiple secrets of the same type instead of only the first
- **hooks/verify_on_stop.py**: `ThreadPoolExecutor` future exceptions no longer silently swallowed by outer `except Exception`

### Security
- **CLAUDE.md**: New "Encoding Conventions (Mojibake Prevention)" section mandating UTF-8 no-BOM and prohibiting `Get-Content`/`Set-Content`/`Out-File` for Chinese-containing files

### Performance
- **hooks/verify_on_stop.py**: Stop event checkers parallelized, blocking time reduced 57% (210s → 90s)

## [1.4.0] - 2026-06-03

### Added
- New `Test-ExistingConfig` function: scans settings.json / .claude.json / hooks / status_lines and reports existing config
- New `Backup-SettingsJson` function: auto-backup to `~/.claude/backups/settings.json.<timestamp>.bak` before writing, keeps last 10
- New `Read-SettingsJsonStrategy` function: interactive strategy selection when settings.json exists (overwrite / merge / skip / cancel)
- New `Merge-Hooks` function: per-event hooks merge, user hooks preserved + project hooks appended (dedup by command)
- New `Merge-Permissions` function: allow/deny array union dedup, defaultMode user-priority
- `Install-SettingsJson` now accepts `-Strategy` param (fresh / overwrite / merge / skip), merge strategy implements deep merge:
  - `env`: user-priority (protects API key / base URL), missing keys filled from project
  - `enabledPlugins`: both sides merged, user switches take priority
  - `hooks`: per-event append with dedup (user preserved + project appended)
  - `permissions`: allow/deny union dedup, defaultMode user-priority
  - `statusLine`: project-priority (standardized status_line_v6)
  - Other fields (ccmManaged / ccmProvider etc.): user-priority preserved
- settings.json write changed to atomic (.tmp + Move-Item + UTF-8 no-BOM), consistent with .claude.json
- `Show-Summary` now displays strategy type (merge / overwrite / skip)
- README updated "cc-switch integration" and "existing config protection" sections
- CLAUDE.md updated installation flow steps 6-8 and notes

### Changed
- Full mode main flow: `Backup-SettingsJson` → `Read-SettingsJsonStrategy` → cancel exits 0 → `Install-SettingsJson -Strategy`
- Ensure `~/.claude/` directory exists before writing settings.json (fix WriteAllText path-not-found on fresh install)

### Documentation
- README.md fixed strategy options count: 3 -> 4 (add `4. Cancel` as fourth option)
- README.md added deep merge semantics table (10 fields) for `Install-SettingsJson -Strategy merge`
- README.md `~/.claude/` deployment tree: add `backups/` directory
- README.md project structure: add `CHANGELOG.en.md` / `CLAUDE.md` / `LICENSE` / `logs/`
- README.md added atomic write description (.tmp + Move-Item + UTF-8 no-BOM)
- CLAUDE.md added step 7 (strategy selection `Read-SettingsJsonStrategy`)
- CLAUDE.md step 9 added detailed deep merge semantics
- CLAUDE.md step 8 added hooks "Test-Path skip" note
- CLAUDE.md project structure: add missing `LICENSE` entry
- CLAUDE.md notes: detailed merge semantics, add `~/.claude/backups/` maintenance note
- Related commit: `9fe4bca` (docs: align README.md and CLAUDE.md with v1.4.0 config protection)

## [1.3.0] - 2026-06-03

### Added
- Full mode now automatically writes `hasCompletedOnboarding: true` into `~/.claude.json`, skipping the theme picker / welcome wizard on first launch
- New `Install-ClaudeJson` function: read existing `.claude.json` → merge `hasCompletedOnboarding` → atomic write (.tmp + Move-Item) → preserves `installMethod` / `autoUpdates` / `projects` fields
- `Show-Summary` in Full mode shows `~/.claude.json: hasCompletedOnboarding = true ✓` status line
- README adds "Onboarding skip (Full mode default)" section, explaining only `hasCompletedOnboarding` is prefilled and why `hasTrustDialogAccepted` / `hasCompletedProjectOnboarding` are NOT touched
- CLAUDE.md adds step 7 "onboarding prefill" to installation flow

### Security
- `hasTrustDialogAccepted` (workspace trust gate) is **not** prefilled — that flag would bypass the trust dialog for every project, exposing users to CVE-2026-33068-class risk; keep the default behavior (prompt the user) is safer
- `hasCompletedProjectOnboarding` is **not** prefilled — requires absolute project paths, anti-idempotent, low user-friendliness
- `.claude.json` writes use UTF-8 no-BOM + atomic replace, so a crash never leaves a half-written file

### Documentation
- README.md added "Onboarding skip (Full mode default)" section, explaining only `hasCompletedOnboarding` is prefilled and why `hasTrustDialogAccepted` / `hasCompletedProjectOnboarding` are NOT touched (CVE-2026-33068 risk + anti-idempotent)
- CLAUDE.md installation flow added step 7 "onboarding prefill" note
- Related commit: `042f49e` (feat: skip global onboarding wizard in Full mode (v1.3.0))

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

### Documentation
- README added execution flow chart (Mermaid format), showing mirror source selection -> install mode branching -> Full mode hooks deployment flow
- README added comprehensive `GeneralConfiguration.json` field reference table (7 top-level fields + 5 allow categories + 6 deny rules)
- README added "Install Mode" section explaining 1/2 options and parameter usage
- README removed redundant "License" section
- README updated project structure comments to mark user hooks' dual identity (source file + embedded content)
- Related commit: `6f1e329` (docs: update CLAUDE.md and README.md with v1.1.0 changes, README project structure note adjustment, CHANGELOG archive v1.2.0)

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

[Unreleased]: https://github.com/ErgeAIA/claude-code-bootstrap/compare/v1.7.0...HEAD
[1.7.0]: https://github.com/ErgeAIA/claude-code-bootstrap/compare/v1.6.1...v1.7.0
[1.6.1]: https://github.com/ErgeAIA/claude-code-bootstrap/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/ErgeAIA/claude-code-bootstrap/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/ErgeAIA/claude-code-bootstrap/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/ErgeAIA/claude-code-bootstrap/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/ErgeAIA/claude-code-bootstrap/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/ErgeAIA/claude-code-bootstrap/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/ErgeAIA/claude-code-bootstrap/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/ErgeAIA/claude-code-bootstrap/releases/tag/v1.0.0
