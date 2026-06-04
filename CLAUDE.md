# CLAUDE.md — claude-code-bootstrap

## 项目概述

**claude-code-bootstrap** 是一个 Windows PowerShell 项目，目标是在 Windows 上一键拉起 Claude Code 完整工作环境。适合新机器初始化、重装系统后快速恢复、团队统一开发环境。

## 仓库结构

```
claude-code-bootstrap/
├── install.ps1              # 入口脚本：智能选源（Gitee/GitHub）+ 下载主脚本
├── setup-claude.ps1         # 主体脚本：环境检测 → 安装 → hooks 部署 → settings.json（带配置保护）
├── GeneralConfiguration.json # Claude Code settings.json 完整配置模板
├── checksums.txt            # hooks 和 status_line 的 SHA256 校验和
├── README.md                # 中文文档
├── CHANGELOG.md             # 中文更新日志
├── CHANGELOG.en.md          # English changelog
├── CLAUDE.md                # 本文件 — AI 工作指南
├── hooks/                   # 用户自写的 4 个 hooks
│   ├── auto_format.py       # 文件写入后自动格式化
│   ├── block_dangerous.py   # 拦截危险 Bash 命令
│   ├── check_secrets.py     # 检查是否泄露密钥
│   └── verify_on_stop.py    # 会话结束时验证
├── scripts/                 # 维护脚本
│   ├── refresh-user-hook-hash.ps1 # 刷新用户 hooks SHA256（已废弃，hooks 改为下载后不再需要嵌入哈希）
│   └── update-checksums.ps1 # 刷新 hooks SHA256 校验和（支持 -DryRun）
├── .github/
│   └── workflows/
│       └── update-checksums.yml # 每周自动检测上游 hooks 变更并创建 PR
├── LICENSE                  # AGPL-3.0 开源协议
└── logs/                    # hooks 运行时生成的 JSON 日志（gitignore）
```

## 核心工作流

### 安装流程（setup-claude.ps1）

1. **环境检测**：PowerShell 5.1+、64 位系统、Git、UV（自动安装）、Node.js、Claude Code；输出表格报告（通过/建议/可选/阻断）
2. **安装模式选择**：交互式选择 0（退出）/ 1（仅软件，默认）/ 2（完整安装含 hooks）
   - 可通过 `-InstallMode Minimal|Full` 参数跳过交互
   - `-SkipClaudeInstall` 仅部署 hooks（配合 Full 模式补装）
3. **现有配置检测**：`Test-ExistingConfig` 报告 settings.json / .claude.json / hooks / status_lines 是否已存在
4. **Claude Code 安装**（三级兜底）：
   - native（GCS 直连）→ winget → npm
   - native 安装默认 60 秒超时自动降级
   - SHA256 校验 + 文件大小双重验证
5. **PATH 维护**：三种安装路径都处理（`~/.local/bin`、winget 目录、npm 全局目录）
6. **自动备份**（仅 Full 模式）：`Backup-SettingsJson` 在写入 settings.json 前备份到 `~/.claude/backups/settings.json.<timestamp>.bak`，保留最近 10 个
7. **策略选择**（仅 Full 模式）：`Read-SettingsJsonStrategy` 检测到 settings.json 已存在时交互选择，覆盖 / 合并 / 跳过 / 取消（取消则 exit 0）
8. **Hooks 部署**（仅 Full 模式）：
   - 10 个 hooks（4 个本仓库 + 6 个 disler）+ status_line_v6 全部从 GitHub 下载
   - 已存在的 hooks 跳过不覆盖（`Test-Path` 跳过）
   - 下载后 SHA256 校验，不匹配则删除文件并报错
   - 校验和维护在 `checksums.txt` 和 `$CHECKSUMS` 哈希表中
9. **settings.json 生成**（仅 Full 模式）：根据策略 `Install-SettingsJson -Strategy <fresh|overwrite|merge|skip>` 写入 `~/.claude/settings.json`
   - `merge` 策略调用 `Merge-Hooks` / `Merge-Permissions` 实现深度合并：
     - `env`：用户优先（保护 API key / base URL），缺失 key 用项目补
     - `enabledPlugins`：双方合并，用户开关优先
     - `hooks`：按事件追加去重（按 command 去重，用户 hooks 保留 + 项目 hooks 追加）
     - `permissions.allow/deny`：并集去重；`defaultMode` / `skipDangerousModePermissionPrompt` 用户优先
     - `statusLine` / `autoConnectIde`：项目优先
     - 其他字段（ccmManaged / ccmProvider 等）：用户优先保留
   - 损坏文件优雅降级为整体覆盖
   - 原子写（.tmp + Move-Item + UTF-8 无 BOM），写入前确保 `~/.claude/` 目录存在
10. **onboarding 预填**（仅 Full 模式）：在 `~/.claude.json` 中合并写入 `hasCompletedOnboarding: true`，跳过主题/欢迎向导。原子写（.tmp + Move-Item），保留 installMethod / autoUpdates / projects 等其他字段。`hasTrustDialogAccepted` 和 `hasCompletedProjectOnboarding` 不处理（前者涉及 CVE-2026-33068 类工作区信任风险，后者反幂等）

### 入口流程（install.ps1）

1. 依次尝试 Gitee（国内）→ GitHub（国外），10 秒超时
2. 下载成功后移交控制权给 setup-claude.ps1
3. 优先使用 `pwsh.exe`（PowerShell 7+），回退到 `powershell.exe`
4. 临时脚本执行后自动清理

## 配置说明

`GeneralConfiguration.json` 包含完整的 Claude Code 配置模板：

- **enabledPlugins**: `feature-dev@claude-plugins-official`
- **env**: 禁用自动压缩、禁用非必要流量
- **statusLine**: 使用 `uv run --script` 运行 status_line_v6.py
- **hooks**: 7 个 hook 事件（SessionStart、UserPromptSubmit、PreToolUse、PostToolUse、PostToolUseFailure、Stop、SessionEnd）
- **permissions**: allow/deny 列表 + bypassPermissions 默认模式

## 开发规范

### 脚本风格
- PowerShell 脚本使用 `Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'`
- 输出编码统一 UTF8：`[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`
- 日志函数：`Write-Step`（青色）、`Write-Ok`（绿）、`Write-Warn2`（黄）、`Write-Err`（红）、`Write-Info`（灰）

### 编码规范（防乱码）

**根因教训：** 中文 Windows 上 PowerShell 5.1 默认使用 GBK 编码，处理 UTF-8 文件会导致乱码（mojibake）。

**强制规则：**
- 所有项目文件（.ps1 / .py / .json / .md）必须以 **UTF-8 无 BOM** 保存
- 修改 .ps1 文件时，必须用 `[System.IO.File]::ReadAllText($path, $utf8NoBom)` 读取，`[System.IO.File]::WriteAllText($path, $content, $utf8NoBom)` 写入
- 禁止使用 PowerShell 5.1 的 `Get-Content` / `Set-Content` / `Out-File` 处理含中文的文件（这些 cmdlet 在中文 Windows 上默认使用 GBK 编码）
- Git 配置建议（手动设置，非强制）：`core.quotepath=false`（避免中文文件名显示为八进制转义）

### Hooks 规范
- 所有 hooks 用 `uv run --script` 执行（零依赖管理）
- 所有 hooks（含用户自写和 disler）均从 GitHub 仓库下载，**不嵌入脚本**
- 用户自写的 hooks 放在 `hooks/` 目录，**源文件提交到本仓库**
- disler 仓库的 hooks **不提交到本仓库**，从 disler/claude-code-hooks-mastery 下载
- 修改用户 hooks 后必须同时更新：
  1. `hooks/<file>.py` 源文件
  2. `checksums.txt` 中对应哈希值
  3. `setup-claude.ps1` 中 `$CHECKSUMS` 对应条目
  4. 运行 `scripts/update-checksums.ps1` 可自动刷新 2+3
- 每个 hook 有独立超时设置（10-120 秒）
- hooks 下载后必须通过 SHA256 校验，校验值维护在 `checksums.txt` 和 `$CHECKSUMS` 中
- 上游 disler hooks 更新时，运行 `scripts/update-checksums.ps1` 刷新校验和
- GitHub Actions 每周自动检测上游变更并创建 PR
- **Full 模式自动生成 `~/.claude/settings.json`**，用户无需手动配置 cc-switch 即可启用 hooks

### 版本管理
- 遵循 Semantic Versioning
- 更新日志遵循 Keep a Changelog 格式
- 双语维护（zh + en）

### 双平台同步
- 仓库同时维护 GitHub（origin）和 Gitee 两个远程
- 每次推送到云端时，必须同时推送到两个平台：`git push origin <branch> && git push gitee <branch>`
- 新建分支、标签同理，需同步到两个远程
- 如果 Gitee 远程尚未配置，执行：`git remote add gitee https://gitee.com/ErgeAIA/claude-code-bootstrap.git`

### 完整提交流程
所有代码修改完成后，按以下顺序完成提交，**缺一不可**：

1. **更新 CHANGELOG**（中英双语）
   - 在 `CHANGELOG.md` 和 `CHANGELOG.en.md` 的 `[Unreleased]` 段追加条目
   - 按类别归入 `Added` / `Changed` / `Fixed` / `Security` / `Performance` / `Documentation`
   - 涉及安全修复必须有 `Security` 段；涉及性能优化必须有 `Performance` 段
2. **同步 README**（如有可见变化）
   - 新增功能：在"功能特性"表格加一行，必要时在"包含内容"补 hook 列表
   - 移除/废弃功能：从表格和说明中删除对应条目
   - 架构调整（目录结构、新增 scripts、新增 GitHub Actions 等）：更新"项目结构"代码块
   - 安装流程/参数变化：更新"快速开始"步骤、"高级用法"参数说明
   - 系统要求变化（硬/软依赖增减）：更新"系统要求"段
   - 纯内部重构（不影响用户）：可跳过 README
3. **运行复审检查**
   - PowerShell 脚本：用 `Parser::ParseFile` 做语法检查，确保 0 errors
   - hooks 哈希：修改 hooks 后运行 `scripts/update-checksums.ps1` 刷新校验和
   - 乱码检查：用 `Select-String` 搜索典型乱码字符（`閸` `鐎` 等）
4. **生成 commit 信息**
   - 格式：`type(scope): subject`（conventional commit）
   - 关联版本号（如 v1.5.0），参考 CLAUDE.md 顶部历史记录
5. **双平台推送**
   - `git push origin <branch> && git push gitee <branch>`
   - 推送失败时**禁止**跳过，必须解决网络或权限问题后再推

**反例**：
- 改完代码直接 commit，没更新 CHANGELOG
- 改了安装流程但没同步 README 的"快速开始"和"高级用法"
- 推送了 GitHub 忘了 Gitee（违反双平台同步约定）
- hooks 改了但没更新 `checksums.txt` 和 `$CHECKSUMS`，部署时 SHA256 校验失败

## 注意事项

- 本项目**会**在 Full 模式下自动生成 `~/.claude/settings.json`，已有配置时交互选择策略（覆盖/合并/跳过/取消）
- 合并策略：`env` 用户优先 / `hooks` 按事件追加去重（按 command）/ `permissions.allow/deny` 并集去重 / `defaultMode` 用户优先 / `statusLine`+`autoConnectIde` 项目优先 / 其他字段保留
- `~/.claude/backups/` 目录由 `Backup-SettingsJson` 自动维护，保留最近 10 个 `settings.json.<timestamp>.bak`
- `~/.claude.json`（状态文件）在 Full 模式下仅预填 `hasCompletedOnboarding`，其他字段（installMethod / autoUpdates / projects）由 Claude Code 自己管理
- native 安装的二进制存放在 `~/.local/share/claude/versions/`，符号链接到 `~/.local/bin/claude.exe`
- `.claude.json` 标记安装方式（`installMethod: native/winget/npm`）
- `logs/` 目录由 hooks 运行时自动生成，已加入 .gitignore
