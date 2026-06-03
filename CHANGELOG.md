# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.0] - 2026-06-03

### Added
- Full 模式自动在 `~/.claude.json` 中合并写入 `hasCompletedOnboarding: true`，首次启动不再弹主题选择 / 欢迎向导
- 新增 `Install-ClaudeJson` 函数：读取现有 `.claude.json` → 合并 `hasCompletedOnboarding` → 原子写（.tmp + Move-Item）→ 保留 `installMethod` / `autoUpdates` / `projects` 等其他字段
- `Show-Summary` 在 Full 模式新增 `~/.claude.json: hasCompletedOnboarding = true ✓` 状态行
- README 新增 "Onboarding 跳过（Full 模式默认行为）" 小节，说明仅 `hasCompletedOnboarding` 被预填、`hasTrustDialogAccepted` / `hasCompletedProjectOnboarding` 不处理的原因
- CLAUDE.md 安装流程新增第 7 步"onboarding 预填"说明

### Security
- `hasTrustDialogAccepted`（工作区信任大门）**不**被预填 — 该标记会绕过所有项目的信任对话框，关联 CVE-2026-33068 类风险，保持默认弹出让用户决策更安全
- `hasCompletedProjectOnboarding` **不**被预填 — 需按项目绝对路径写入，反幂等、用户友好度低
- `.claude.json` 写入采用 UTF-8 无 BOM + 原子替换，崩溃不会留半截文件

## [1.2.0] - 2026-06-03

### Added
- 新增 `-InstallMode` 参数（`Minimal`/`Full`），支持交互式选择安装模式，默认 `Minimal`（仅安装软件）
- 4 个用户自写 hooks 嵌入到 `setup-claude.ps1` 的 `$USER_HOOKS_CONTENT` 中，Full 模式自动写入 `~/.claude/hooks/`，**无需用户手动放置**
- 新增 `Install-UserHooks` 函数：从嵌入内容写入用户 hooks，UTF-8 无 BOM 跨 PS 5.1/7+ 一致
- 新增 `Install-SettingsJson` 函数：合并 `GeneralConfiguration.json` 写入 `~/.claude/settings.json`，Full 模式安装后**立即启用所有 hooks**
- 嵌入内容 SHA256 校验加入 `$CHECKSUMS` 哈希表（auto_format / block_dangerous / check_secrets / verify_on_stop）
- README 新增执行流程图（Mermaid 格式）
- README 新增 `GeneralConfiguration.json` 完整字段说明表（7 个顶层字段 + 5 类白名单 + 6 条黑名单）
- README 新增"安装模式"章节，说明 1/2 选项及参数用法

### Changed
- `setup-claude.ps1` 主流程根据 `InstallMode` 决定是否执行 hooks 部署和 settings.json 生成
- 用户 hooks 写入方式从 `Set-Content -Encoding UTF8` 改为 `[IO.File]::WriteAllText` + UTF-8 无 BOM，避免 BOM 影响 SHA256
- `Install-Hooks` 函数移除"检查用户自写 hooks"逻辑（已被 `Install-UserHooks` 替代）
- `Show-Summary` 函数根据安装模式显示不同内容，Full 模式额外展示 settings.json 状态
- README 删除冗余的"协议说明"部分
- README 调整仓库结构注释，标注用户 hooks 的双重身份（源文件 + 嵌入内容）

### Security
- 用户 hooks 嵌入内容 + SHA256 校验，篡改会被检测并拒绝写入
- settings.json 写入使用 `[ordered]@{}` 确保字段顺序与 `GeneralConfiguration.json` 一致

## [1.1.0] - 2026-06-03

### Fixed
- 修复 `$cfg` 变量空初始化导致 native 安装后写入配置崩溃的问题
- 修复 `$methods` 安装方式数组语法损坏导致脚本无法解析的问题
- 修复 `install.ps1` 硬编码 `powershell.exe` 导致 `ConvertFrom-Json -AsHashtable` 在 PS5.1 下不可用的问题
- 修复 native 安装 Job 返回值为空导致版本号丢失的问题

### Changed
- hooks 下载源从 GitHub 单源改为 Gitee + GitHub 双源，国内用户优先走 Gitee
- 移除 UV 安装脚本和 setup-claude.ps1 下载中无效的内容匹配校验，改为显式 trust-on-first-use 声明
- `install.ps1` 优先使用 `pwsh.exe`（PowerShell 7+），回退到 `powershell.exe`

### Added
- hooks 和 status_line 下载后增加 SHA256 完整性校验，校验失败自动删除文件
- 新增 `checksums.txt` 维护 hooks 和 status_line 的 SHA256 哈希值
- 新增 `scripts/update-checksums.ps1` 本地刷新校验和脚本（支持 `-DryRun` 预览）
- 新增 `.github/workflows/update-checksums.yml` GitHub Actions 每周自动检测上游 hooks 变更并创建 PR
- 新增双平台同步约定（GitHub + Gitee）到 CLAUDE.md
- `install.ps1` 临时脚本执行后自动清理

### Security
- hooks 下载增加 SHA256 校验，防止供应链攻击导致 RCE
- 移除可被绕过的弱内容校验（`-match 'astral|uv'`、`-match 'Claude Code'`），避免虚假安全感

## [1.0.0] - 2026-06-03

### Added
- 初始版本发布
- Claude Code 一键安装脚本
- Windows PowerShell 工作流自动化
- hooks 工作流部署
- 国内网络环境优化配置

[Unreleased]: https://github.com/ErgeAIA/claude-code-bootstrap/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/ErgeAIA/claude-code-bootstrap/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/ErgeAIA/claude-code-bootstrap/releases/tag/v1.0.0
