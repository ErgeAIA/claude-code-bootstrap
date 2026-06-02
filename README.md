<div align="center">

# Claude Code Bootstrap

**一键拉起 Claude Code 工作环境（Windows PowerShell）​**

[![GitHub](https://img.shields.io/badge/GitHub-ErgeAIA-181717?logo=github)](https://github.com/ErgeAIA/claude-code-bootstrap)
[![Gitee](https://img.shields.io/badge/Gitee-镜像仓库-C71D23?logo=gitee)](https://gitee.com/ErgeAIA/claude-code-bootstrap)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)
[![Stars](https://img.shields.io/github/stars/ErgeAIA/claude-code-bootstrap?style=social)](https://github.com/ErgeAIA/claude-code-bootstrap)

[快速开始](#-快速开始) · [功能特性](#-功能特性) · [作者信息](#-作者信息) · [更新日志](CHANGELOG.md)

</div>

---

## 这是什么

在 Windows 上一行命令安装 Claude Code 并部署完整的 hooks 工作流，**免去手动配环境、写 settings.json、拉脚本的繁琐**。

适合以下场景：

- 🆕 刚拿到新电脑，想 5 分钟内用上 Claude Code
- 🔄 旧机器重装系统，需要快速恢复工作流
- 👥 团队内部统一开发环境
- 🇨🇳 国内网络环境，规避 GCS 直连超时、GitHub raw 卡顿

## 🚀 快速开始

**以管理员身份打开 PowerShell**，执行：

\`\`\`powershell
iwr https://raw.githubusercontent.com/ErgeAIA/claude-code-bootstrap/main/install.ps1 | iex
\`\`\`

国内网络推荐（自动测速，优先 Gitee）：

\`\`\`powershell
iwr https://gitee.com/ErgeAIA/claude-code-bootstrap/raw/main/install.ps1 | iex
\`\`\`

脚本会自动：
1. 测速选择最快镜像源
2. 下载主脚本 `setup-claude.ps1`
3. 检测 PowerShell、Git、UV、Node.js（缺啥补啥）
4. 三级兜底安装 Claude Code（native → winget → npm）
5. 自动配置 PATH（立即生效）
6. 下载 6 个 disler 仓库 hooks + status_line_v6
7. 验证安装结果

**全程约 2-5 分钟**，取决于网络。

## ✨ 功能特性

| 类别                 | 说明                                      |
| -------------------- | ----------------------------------------- |
| 🛡️ **三级兜底安装**   | native (GCS) → winget → npm，任一成功即停 |
| ⏱️ **超时自动切换**   | native 60 秒无响应自动降级，避免卡死      |
| 🔐 **SHA256 校验**    | 二进制大小 + 校验和双重验证，防中间人     |
| 🔄 **幂等运行**       | 已装组件自动跳过，可重复执行              |
| 🪞 **智能镜像选源**   | Gitee / GitHub 自动测速，优先最快         |
| 🔁 **下载重试**       | 网络抖动自动重试 3 次                     |
| 🛣️ **PATH 自动维护**  | native / winget / npm 三种位置都处理      |
| 🪝 **hooks 一键部署** | disler 6 个核心 hooks + status_line_v6    |
| 📋 **依赖自检**       | PowerShell、Git、UV、Node.js 缺啥补啥     |

## 📦 包含内容

部署完成后，`~/.claude/` 目录结构如下：

\`\`\`
~/.claude/
├── hooks/
│   ├── pre_tool_use.py              # 工具调用前安全检查
│   ├── post_tool_use.py             # 工具调用后日志记录
│   ├── session_start.py             # 会话开始加载上下文
│   ├── user_prompt_submit.py        # 用户输入日志
│   ├── post_tool_use_failure.py     # 工具失败日志
│   └── session_end.py               # 会话结束清理
├── status_lines/
│   └── status_line_v6.py            # 上下文窗口使用率监控
└── logs/                            # hooks 自动生成的 JSON 日志
\`\`\`

## ⚙️ 高级用法

### 指定安装版本

\`\`\`powershell
# 安装最新稳定版（默认）
.\setup-claude.ps1

# 安装具体版本
.\setup-claude.ps1 -ClaudeVersion 2.1.153

# 仅部署 hooks（跳过 Claude Code 安装）
.\setup-claude.ps1 -SkipClaudeInstall

# 自定义 native 安装超时时间
.\setup-claude.ps1 -InstallTimeout 120
\`\`\`

### 与 cc-switch 配合

本项目不写 `settings.json`，因为这部分由 [cc-switch](https://github.com/farion1231/cc-switch) 的"通用配置片段"统一管理，避免冲突。

部署完成后，在 cc-switch 里粘贴通用配置（hooks、permissions、statusLine 等），切换供应商即可生效。

## 🔧 三种安装方式对比

| 方式              | 文件位置                               | 是否自动配 PATH | 何时使用                     |
| ----------------- | -------------------------------------- | --------------- | ---------------------------- |
| **native (GCS)​** | `~/.local/bin/claude.exe`              | ✅ 我们处理      | **默认首选**（官方推荐）     |
| **winget**        | `%LocalAppData%\Programs\claude-code\` | ✅ 通常自动      | native 超时/被墙时           |
| **npm**           | `%AppData%\Roaming\npm\claude.cmd`     | ✅ 通常自动      | 上面都失败时（官方已不推荐） |

## 📋 系统要求

- Windows 10 1809+ / Windows 11
- PowerShell 5.1+（Win10 自带 5.1，Win11 自带 7.x）
- 64 位系统
- 网络可访问 GitHub / Gitee（至少一个）

可选依赖（脚本会自动检测，缺失会警告或自动安装）：

- **Git**：hooks 中部分脚本需要
- **UV**：hooks 全部用 `uv run --script` 执行
- **Node.js**：仅 npm 兜底安装时需要

## 🗂️ 项目结构

\`\`\`
claude-code-bootstrap/
├── install.ps1          # 入口脚本（智能选源 + 自动重试）
├── setup-claude.ps1     # 主体脚本（环境检测 + 安装 + 部署）
├── README.md            # 本文件
├── LICENSE              # AGPL-3.0 协议
└── CHANGELOG.md         # 更新日志
\`\`\`

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

如果你的环境遇到问题，请提供：
- Windows 版本（`winver`）
- PowerShell 版本（`$PSVersionTable.PSVersion`）
- 网络环境（是否能访问 GitHub / Gitee）
- 完整错误输出

## 📜 协议

本项目采用 [AGPL-3.0](LICENSE) 协议开源。

简单说：

- ✅ 允许自由使用、修改、分发
- ✅ 允许商业使用
- ⚠️ **修改后必须开源**（包括网络服务部署场景）
- ⚠️ 衍生作品必须采用相同协议

完整条款见 [LICENSE](LICENSE) 文件。

## 👤 作者信息

<table>
<tr>
<td align="center" width="200">
<img src="https://github.com/ErgeAIA.png" width="100" style="border-radius: 50%"><br>
<b>宝藏二哥AIA / ErgeAIA</b><br>
<sub>生命不息，折腾不止</sub>
</td>
<td>

**定位**：AI 软件创造者 / 全栈工程师 / 产品经理 / Vibe Coding 实践者

**技术栈**：Tauri · Rust · React · Python · Claude · Cursor · Trae

**理念**：三无分享 — 无门槛、无套路、无保留

**链接**：
- 📺 [B 站](https://space.bilibili.com/67221461) · 知乎 · 微信
- 🐙 [GitHub](https://github.com/ErgeAIA) · [Gitee](https://gitee.com/ErgeAIA)
- 📦 精选项目：[ErgeAIA-skills](https://github.com/ErgeAIA/ErgeAIA-skills) · [ErgeMD](https://github.com/ErgeAIA/ErgeMD) · [catapult-cn](https://github.com/ErgeAIA/catapult-cn)

</td>
</tr>
</table>

---

<div align="center">

如果这个项目帮到了你，欢迎点个 ⭐ 鼓励一下！

<sub>用 ❤️ 和 PowerShell 制作</sub>

</div>
