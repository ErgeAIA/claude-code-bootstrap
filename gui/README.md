# Claude Code Bootstrap GUI

原生 Win32 小工具，给 `setup-claude.ps1` 套一个图形界面。C++17 + Win32 API，
MinGW 静态编译后是 **单个 exe（约 280 KB）**，无 .NET / Electron / 运行时依赖。

## 功能

| 按钮 | 行为 | 底层调用 |
| --- | --- | --- |
| **安装** | 安装 Claude Code 本体 + PATH 配置 | `setup-claude.ps1 -InstallMode Minimal` |
| **完整安装** | 安装本体 + 部署 10 个 hooks + status_line | `setup-claude.ps1 -InstallMode Full` |
| **检查更新** | 检测本机 `claude --version`，并查询官方 GCS `/latest` | WinHTTP + 子进程 |
| **更新** | 升级到最新稳定版（仅在检测到新版本时可点击） | `setup-claude.ps1 -Upgrade` |
| **卸载** | 移除 native / winget / npm 安装，清理本工具部署的 hooks、status_line 与 `settings.json` 中的对应条目 | `setup-claude.ps1 -Uninstall` |

界面提供实时日志（按 `[OK]` / `[WARN]` / `[ERROR]` 着色）、运行状态卡片和忙碌进度条。
关闭窗口时若有任务在运行，会先确认；确认退出后 PowerShell 子进程随 Job Object 一起结束。

## 构建

要求：Windows 10/11 x64，MinGW-w64（`g++` + `windres`，已测试 13.1）。

```powershell
pwsh -NoProfile -File gui/build.ps1
# 产物：gui/dist/ClaudeBootstrap.exe
```

如果 `g++` / `windres` 不在 PATH，可显式指定：

```powershell
pwsh -NoProfile -File gui/build.ps1 -Cxx D:\mingw64\bin\g++.exe
```

图标可用 `gui/make-icon.ps1` 重新生成（256×256 PNG-compressed ICO）。

## 运行

直接把 `ClaudeBootstrap.exe` 和 `setup-claude.ps1` 放在同一目录即可。
GUI 按以下顺序查找主脚本：

1. exe 同目录
2. 上 1~4 级目录（方便直接从 `gui/dist/` 运行）
3. `%LOCALAPPDATA%\claude-bootstrap\setup-claude.ps1`
4. 仍未找到时，从 GitHub raw 下载到上述缓存目录

PowerShell 优先使用 `pwsh.exe`（PowerShell 7+，项目硬要求），找不到时回退到 Windows PowerShell。

## 设计说明

- 纯 Win32：自绘深色界面、owner-draw 按钮、DWM 圆角/深色标题栏、PerMonitorV2 DPI 缩放。
- 日志用 RichEdit（`Msftedit.dll`）显示，自动剥离 ANSI 转义，支持选中复制。
- 版本检查在 GUI 内完成，不依赖脚本参数；安装/更新/卸载复用现有 PowerShell 引擎，保持逻辑单一来源。
- 为 GUI 新增的脚本参数：
  - `-NoUpdateCheck`：安装时跳过"发现新版本，是否升级"交互
  - `-SettingsStrategy merge`：已有 `settings.json` 时直接按合并策略处理
  - `-Uninstall`：卸载（见根目录 README）
- 所有子进程使用隐藏窗口 + NUL stdin，脚本中的 `Read-Host` 不会阻塞界面。

## 卸载行为

`-Uninstall` 会：

1. 检测并移除 native（`~/.local/share/claude` + `~/.local/bin/claude.exe`）、winget、npm 安装；
2. 删除本工具部署的 10 个 hooks 与 `status_line_v6.py`；
3. 从 `settings.json` 删除引用这些文件的 hook 组与 statusLine，保留用户其他字段；
4. 从 `.claude.json` 删除 `installMethod` 标记；
5. 仅当 `~/.local/bin` 已空时，才删除该目录并移除用户 PATH 中的对应项。

删除前统一备份到 `~/.claude/backups/uninstall-<时间戳>/`。Claude Code 进程运行中会中止卸载。