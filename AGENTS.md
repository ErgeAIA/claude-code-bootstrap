# AGENTS.md — claude-code-bootstrap

> Windows PowerShell 项目：在 Windows 上一键拉起 Claude Code 完整工作环境（安装 + hooks 部署 + settings.json 生成）。
> 人类文档看 [README.md](./README.md)；双语更新日志看 [CHANGELOG.md](./CHANGELOG.md)。

## 核心文件

- `install.ps1` — 入口脚本，从 GitHub 下载主脚本。**无 `param()` 块**，命令行参数经 `$args` 原样透传给 `setup-claude.ps1`（新增参数无需改它）。
- `setup-claude.ps1` — 主体（约 1300 行）：环境检测 → 三级兜底安装（native GCS → winget → npm）→ hooks 部署 → `~/.claude/settings.json` 深度合并。所有函数 `PascalCase`，日志统一用 `Write-Step/Write-Ok/Write-Warn2/Write-Err/Write-Info`。
- `hooks/` — 4 个用户自写 hook（`auto_format.py` / `block_dangerous.py` / `check_secrets.py` / `verify_on_stop.py`），Python，`uv run --script` 执行，**源文件提交到本仓库**。disler 上游 hook 不提交，安装时从 disler/claude-code-hooks-mastery 下载。
- `checksums.txt` + `setup-claude.ps1` 内 `$CHECKSUMS` — SHA256 双份，内容必须一致。
- `scripts/update-checksums.ps1` — 刷新双份校验和；`scripts/smoke-test.ps1` — 合并逻辑冒烟；`hooks/tests/test_hooks.py` — pytest 回归。
- `.github/workflows/update-checksums.yml` — 每周检测上游 hooks 哈希，**仅在哈希实际变化时**创建 PR（已修复，无变化零 PR）。

## 验证命令（改代码后必跑）

```bash
# hooks 回归测试（14 用例）
uv run --with pytest pytest hooks/tests/

# settings 合并逻辑冒烟（AST 提取 setup-claude.ps1 真实函数，无复制漂移）
pwsh -NoProfile -File scripts/smoke-test.ps1

# PowerShell 语法验证：必须用 ParseInput + UTF-8 显式读取，
# 用 ParseFile 会因 GBK 误读 UTF-8 无 BOM 中文而误报语法错误
```

## 编码与运行时规范（强制）

1. **所有文件 UTF-8 无 BOM**（.ps1 / .py / .json / .md）。修改含中文的 .ps1 必须用 `[System.IO.File]::ReadAllText/WriteAllText` + `UTF8Encoding($false)`；禁止 `Get-Content/Set-Content/Out-File`（中文 Windows 上 PowerShell 5.1 默认 GBK 会乱码）。
2. **PowerShell 7+ 是硬要求**：5.1 按系统 GBK 解码 UTF-8 无 BOM 脚本会解析失败。本地验证一律用 `pwsh`，不要用 `powershell`。
3. 脚本风格：`Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'`，输出 `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`。

## Hooks 改动三处同步（改 `hooks/*.py` 后必做）

1. `hooks/<file>.py` 源文件
2. `checksums.txt` 对应哈希（`sha256sum` 计算）
3. `setup-claude.ps1` 的 `$CHECKSUMS` 对应条目

注意：`scripts/update-checksums.ps1` 从**远程仓库**下载计算哈希，**本地未推送的改动算不出新值**——本地改 hook 后须手动同步 2+3，推送后 CI 会确认一致性。

## 已知坑

- **hooks 幂等跳过**：`~/.claude/hooks/` 下已有文件则安装时跳过且不重新校验；升级 hooks = 删除对应文件后重跑。
- **settings 合并语义**（`Merge-Hooks` / `Merge-Permissions`）：env 用户优先、hooks 按 command 去重追加、permissions allow/deny 并集、defaultMode 用户优先、其他字段保留。改动前先跑 `scripts/smoke-test.ps1`。
- **`GeneralConfiguration.json` 是 cc-switch 参考副本**，脚本实际用内嵌配置（`setup-claude.ps1` 的 `$settings`）——勿只改一处。
- **安全模型**：默认 `defaultMode=bypassPermissions`，危险命令拦截依赖 hooks 黑名单（非安全边界，hook 异常时放行）。README 有披露，改权限相关代码时保持一致。
- **`setup-claude.ps1` 交互式安装器**：错误路径 `[void][Console]::ReadLine()` 阻塞，CI/非交互场景会挂起；验证用参数化命令（如 `-Upgrade`、`-SkipClaudeInstall`、`-InstallMode`）。
- **单一仓库**：只维护 GitHub（origin），push `git push origin <branch>` 即可（gitee 镜像已停用）。
- 版本号 `vX.Y.Z` 硬编码在 `install.ps1` 和 `setup-claude.ps1` 的 banner，发版时两处都要改。
