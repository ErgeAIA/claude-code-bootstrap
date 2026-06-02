# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
