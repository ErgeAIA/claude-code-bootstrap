# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **scripts/refresh-user-hook-hash.ps1**: 用户自写 hooks 哈希刷新工具，解决 GBK 编码导致的 SHA256 计算错误
- **CLAUDE.md**: 新增"完整提交流程"工作流约定

### Changed
- **hooks/verify_on_stop.py**: 
  - 使用 `ThreadPoolExecutor` 并行执行 3 个 checker，最坏情况从 210s 降至 90s
  - 重构为 `Checker` dataclass 数据驱动架构
  - TypeScript runner 扩展为 5 种 lockfile（pnpm/bun/yarn/npm + npx fallback）
  - 按超时升序排列（Python 30s → TS/Rust 90s）
  - 新增 `VERIFY_ON_STOP_SKIP` 环境变量跳过指定 checker
- **hooks/auto_format.py**: 数据驱动架构，`FORMATTERS` 列表替代 if-elif 链，`run_silent` 返回 `bool`
- **hooks/block_dangerous.py**: 规则升级为 `Rule` NamedTuple（含 severity/why），正则预编译，JSON+stderr 双通道输出
- **hooks/check_secrets.py**: PostToolUse 语义修正（改用 `hookSpecificOutput.additionalContext`），路径匹配精确化，正则预编译，密钥模式扩展至 15 种
- **setup-claude.ps1**: Node.js 从硬依赖降级为可选依赖；`Install-Npm` 改为 npm 不可用时自动用 winget 安装 Node.js LTS 并刷新 PATH
- **scripts/update-checksums.ps1**: `$REPO_BASE` 改为 `$REPO_BASES` 数组，Gitee 优先 + GitHub 备源；`Get-Content` 改为 `[System.IO.File]::ReadAllText`（防乱码）

### Fixed
- **install.ps1**: 内容校验阈值 100→1000+CmdletBinding 特征；UTF-8 无 BOM 写入；每个镜像源 3 次重试；退出码在 finally 前捕获
- **scripts/update-checksums.ps1**: 正则支持大写文件名；UTF-8 无 BOM；新增用户 hook 校验和保留逻辑
- **setup-claude.ps1**: 嵌入块内容更新同步
- **setup-claude.ps1**: 从 git 历史恢复全部乱码中文（183 行，UTF-8→GBK→UTF-8→GBK 多重误读）
- **GeneralConfiguration.json**: 移除 `Read(**/id_rsa)` 和 `Read(**/id_ed25519)` 中的零宽空格（U+200B）
- **install.ps1**: 注释中的 `iex -InstallMode Full` 错误示例（参数会被 iex 解析）

### Security
- **CLAUDE.md**: 新增"编码规范（防乱码）"章节，强制 UTF-8 无 BOM；禁止使用 `Get-Content`/`Set-Content`/`Out-File` 处理含中文文件

### Performance
- **hooks/verify_on_stop.py**: Stop 事件 checker 并行化，阻塞时间降低 57%（210s → 90s）

## [1.4.0] - 2026-06-03

### Added
- 新增 `Test-ExistingConfig` 函数：扫描 settings.json / .claude.json / hooks / status_lines，报告已有配置
- 新增 `Backup-SettingsJson` 函数：写入前自动备份到 `~/.claude/backups/settings.json.<timestamp>.bak`，保留最近 10 个
- 新增 `Read-SettingsJsonStrategy` 函数：检测到 settings.json 已存在时交互选择策略（覆盖 / 合并 / 跳过 / 取消）
- 新增 `Merge-Hooks` 函数：按事件合并 hooks，每个事件内用户 hooks 保留 + 项目 hooks 追加（按 command 去重）
- 新增 `Merge-Permissions` 函数：allow/deny 数组并集去重，defaultMode 用户优先
- `Install-SettingsJson` 支持 `-Strategy` 参数（fresh / overwrite / merge / skip），merge 策略实现深度合并：
  - `env`：用户优先（保护 API key / base URL），缺失 key 用项目补
  - `enabledPlugins`：双方合并，用户开关优先
  - `hooks`：按事件追加去重（用户保留 + 项目追加）
  - `permissions`：allow/deny 并集去重，defaultMode 用户优先
  - `statusLine`：项目优先（统一 status_line_v6）
  - 其他字段（ccmManaged / ccmProvider 等）：用户优先保留
- settings.json 写入改为原子写（.tmp + Move-Item + UTF-8 无 BOM），与 .claude.json 一致
- `Show-Summary` 显示策略类型（合并 / 覆盖 / 跳过）
- README 更新"与 cc-switch 配合"和"已有配置保护"章节
- CLAUDE.md 更新安装流程步骤 6-8 和注意事项

### Changed
- Full 模式主流程：`Backup-SettingsJson` → `Read-SettingsJsonStrategy` → 取消则 exit 0 → `Install-SettingsJson -Strategy`
- settings.json 写入前确保 `~/.claude/` 目录存在（修复全新环境 WriteAllText 路径不存在问题）

### Documentation
- README.md 修正策略选项 3 → 4（补 `4. 取消`），加深度合并语义表（10 个字段）
- README.md `~/.claude/` 部署结构加 `backups/` 目录
- README.md 项目结构加 `CHANGELOG.en.md` / `CLAUDE.md` / `LICENSE` / `logs/`
- README.md 加原子写说明（.tmp + Move-Item + UTF-8 无 BOM）
- CLAUDE.md 加步骤 7（策略选择 `Read-SettingsJsonStrategy`）
- CLAUDE.md 步骤 9 加深度合并详细语义
- CLAUDE.md 步骤 8 加 hooks "Test-Path 跳过" 说明
- CLAUDE.md 仓库结构加 `LICENSE` 缺失项
- CLAUDE.md 注意事项加深合字段细节 + `~/.claude/backups/` 维护说明
- 关联 commit：`9fe4bca` (docs: align README.md and CLAUDE.md with v1.4.0 config protection)

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

### Documentation
- README.md 加 "Onboarding 跳过（Full 模式默认行为）" 小节，说明仅 `hasCompletedOnboarding` 被预填、`hasTrustDialogAccepted` / `hasCompletedProjectOnboarding` 不处理的原因（CVE-2026-33068 风险 + 反幂等）
- CLAUDE.md 安装流程新增第 7 步 "onboarding 预填" 说明
- 关联 commit：`042f49e` (feat: skip global onboarding wizard in Full mode (v1.3.0))

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

### Documentation
- README 新增执行流程图（Mermaid 格式），展示镜像源选择 → 安装模式分支 → Full 模式 hooks 部署流程
- README 新增 `GeneralConfiguration.json` 完整字段说明表（7 个顶层字段 + 5 类白名单 + 6 条黑名单）
- README 新增"安装模式"章节，说明 1/2 选项及参数用法
- README 删除冗余的"协议说明"部分
- README 调整仓库结构注释，标注用户 hooks 的双重身份（源文件 + 嵌入内容）
- 关联 commit：`6f1e329` (docs: update CLAUDE.md and README.md with v1.1.0 changes, README 项目结构注释调整、CHANGELOG 归档 v1.2.0)

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
