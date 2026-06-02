# CLAUDE.md — claude-code-bootstrap

## 项目概述

**claude-code-bootstrap** 是一个 Windows PowerShell 项目，目标是在 Windows 上一键拉起 Claude Code 完整工作环境。适合新机器初始化、重装系统后快速恢复、团队统一开发环境。

## 仓库结构

```
claude-code-bootstrap/
├── install.ps1              # 入口脚本：智能选源（Gitee/GitHub）+ 下载主脚本
├── setup-claude.ps1         # 主体脚本：环境检测 → 安装 → hooks 部署
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
│   └── update-checksums.ps1 # 刷新 hooks SHA256 校验和（支持 -DryRun）
├── .github/
│   └── workflows/
│       └── update-checksums.yml # 每周自动检测上游 hooks 变更并创建 PR
└── logs/                    # hooks 运行时生成的 JSON 日志（gitignore）
```

## 核心工作流

### 安装流程（setup-claude.ps1）

1. **前置检测**：PowerShell 5.1+、64 位系统、Git、UV（自动安装）、Node.js
2. **Claude Code 安装**（三级兜底）：
   - native（GCS 直连）→ winget → npm
   - native 安装默认 60 秒超时自动降级
   - SHA256 校验 + 文件大小双重验证
3. **PATH 维护**：三种安装路径都处理（`~/.local/bin`、winget 目录、npm 全局目录）
4. **Hooks 部署**：从 disler/claude-code-hooks-mastery 下载 6 个 hooks + status_line_v6
   - Gitee + GitHub 双源下载，国内优先 Gitee
   - 下载后 SHA256 校验，不匹配则删除文件并报错
   - 校验和维护在 `checksums.txt` 和 `$CHECKSUMS` 哈希表中
5. **用户 hooks 检查**：提示缺失的自写 hooks

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

### Hooks 规范
- 所有 hooks 用 `uv run --script` 执行（零依赖管理）
- disler 仓库的 hooks 通过脚本自动下载，**不提交到本仓库**
- 用户自写的 hooks 放在 `hooks/` 目录，**提交到本仓库**
- 每个 hook 有独立超时设置（10-120 秒）
- hooks 下载后必须通过 SHA256 校验，校验值维护在 `checksums.txt` 和 `$CHECKSUMS` 中
- 上游 hooks 更新时，运行 `scripts/update-checksums.ps1` 刷新校验和
- GitHub Actions 每周自动检测上游变更并创建 PR

### 版本管理
- 遵循 Semantic Versioning
- 更新日志遵循 Keep a Changelog 格式
- 双语维护（zh + en）

### 双平台同步
- 仓库同时维护 GitHub（origin）和 Gitee 两个远程
- 每次推送到云端时，必须同时推送到两个平台：`git push origin <branch> && git push gitee <branch>`
- 新建分支、标签同理，需同步到两个远程
- 如果 Gitee 远程尚未配置，执行：`git remote add gitee https://gitee.com/ErgeAIA/claude-code-bootstrap.git`

## 注意事项

- 本项目不写 `settings.json`，该部分由 cc-switch 的"通用配置片段"管理，避免冲突
- native 安装的二进制存放在 `~/.local/share/claude/versions/`，符号链接到 `~/.local/bin/claude.exe`
- `.claude.json` 标记安装方式（`installMethod: native/winget/npm`）
- `logs/` 目录由 hooks 运行时自动生成，已加入 .gitignore
