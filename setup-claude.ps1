<#
.SYNOPSIS
    Claude Code 一键部署脚本（环境检测 + 安装 + hooks 部署）
.DESCRIPTION
    1. 前置环境检测：PowerShell、64 位、Git、UV（自动安装）、Node.js
    2. Claude Code 安装：native (GCS) → winget → npm 三级兜底
    3. 可选：下载 disler 仓库的 6 个 hooks + status_line_v6
    4. 检查用户自写 hooks 就位情况
    5. 统一处理 PATH（任何安装方式都跑）

    通常由 install.ps1 拉取并调用，不建议直接运行。
.PARAMETER InstallTimeout
    native 安装的超时秒数。默认 60 秒
.PARAMETER SkipClaudeInstall
    仅部署 hooks，跳过 Claude Code 安装
.PARAMETER ClaudeVersion
    指定安装版本，'latest' 或具体版本号如 '2.1.153'。默认 latest
.PARAMETER InstallMode
    安装模式：Minimal（仅安装软件，默认）或 Full（安装软件 + hooks）
    未指定时交互式提示用户选择
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-claude.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-claude.ps1 -InstallMode Full
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-claude.ps1 -SkipClaudeInstall
#>

[CmdletBinding()]
param(
    [int]$InstallTimeout = 60,
    [switch]$SkipClaudeInstall,
    [ValidatePattern('^(stable|latest|\d+\.\d+\.\d+(-[^\s]+)?)$')]
    [string]$ClaudeVersion = 'latest',
    [ValidateSet('Minimal', 'Full')]
    [string]$InstallMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

# ============================================================
#  常量
# ============================================================
$GCS_BUCKET   = 'https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases'
$REPO_BASES   = @(
    'https://gitee.com/ErgeAIA/claude-code-bootstrap/raw/main/.claude',
    'https://raw.githubusercontent.com/disler/claude-code-hooks-mastery/main/.claude'
)

# SHA256 checksums（与仓库根目录 checksums.txt 同步）
$CHECKSUMS = @{
    'pre_tool_use.py'         = '78006866F793CCD394BC52011582CE48707CEEF9D3496E474AB7BCB63365A5DA'
    'post_tool_use.py'        = '6C3F0AA03CABC68670490A7CDAD6FC2364C94B074F9D6E317EA7C8ABE04C9449'
    'session_start.py'        = 'E48E3D8F6D50A14DBBE4635E461C956A55F338D1DCA67ED39CACDBBF336C6DB8'
    'user_prompt_submit.py'   = 'E5EFBCE941746900D9EF88706D865F2693DA721C6046330D954278939EB988A8'
    'post_tool_use_failure.py'= '46BA935B917E7F8EAD0273E968BE09201E51016913F41A6E9E8DB908BE06D822'
    'session_end.py'          = 'F316D341AE6A3A60E3E5A0DDD0DFD3360DA793A31E80B4B7B44C00F755E15426'
    'status_line_v6.py'       = 'B71DEB25E7C2308B1AB134DFE686E4E6A50612AA4FB91C98CA98327B78A19803'
    # 用户自写 hooks（嵌入在脚本中，离线部署）— 哈希对应嵌入内容（非源文件）
    'auto_format.py'          = '3751F9BE9839A4831914023B831423E25884D047886CBCEA5C6C4E7B012B641F'
    'block_dangerous.py'      = '49591B5A010E010C32754B9D208C4F3D3C6AA69AB7C1805B6B0952A1137BC7E4'
    'check_secrets.py'        = '82C735D924124D872FA0541E70807B5EA02433BBFA241C0F9384078195012592'
    'verify_on_stop.py'       = '3457058851DB01103C8EA0C2F5FF4EA46513282715676C2395E17BCF38DF2E33'
}

$CLAUDE_HOME  = Join-Path $env:USERPROFILE '.claude'
$HOOK_DIR     = Join-Path $CLAUDE_HOME 'hooks'
$SL_DIR       = Join-Path $CLAUDE_HOME 'status_lines'
$LOG_DIR      = Join-Path $CLAUDE_HOME 'logs'

$INSTALL_BASE = Join-Path $env:USERPROFILE '.local\share\claude'
$VERSIONS_DIR = Join-Path $INSTALL_BASE 'versions'
$BIN_DIR      = Join-Path $env:USERPROFILE '.local\bin'
$LINK_PATH    = Join-Path $BIN_DIR 'claude.exe'
$CONFIG_PATH  = Join-Path $env:USERPROFILE '.claude.json'

$DISLER_HOOKS = @(
    'pre_tool_use.py',
    'post_tool_use.py',
    'session_start.py',
    'user_prompt_submit.py',
    'post_tool_use_failure.py',
    'session_end.py'
)
$USER_HOOKS = @(
    'auto_format.py',
    'block_dangerous.py',
    'check_secrets.py',
    'verify_on_stop.py'
)
$STATUS_LINE = 'status_line_v6.py'

# ============================================================
#  用户自写 hooks 内容（嵌入 here-string，离线部署）
#  修改仓库 hooks/ 目录后需重新计算 SHA256 并更新本节 + $CHECKSUMS
# ============================================================
$USER_HOOKS_CONTENT = @{
    'auto_format.py' = @'
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.8"
# ///
"""
Claude 改完文件后按扩展名自动跑 formatter。
事件: PostToolUse (Write|Edit|MultiEdit)
策略: 静默执行，任何失败都不阻塞 Claude (exit 0)
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path


def has_command(name: str) -> bool:
    """检查命令是否在 PATH 中可用"""
    return shutil.which(name) is not None


def run_silent(cmd: list[str], timeout: int = 30) -> None:
    """静默执行命令，吞掉所有输出和异常"""
    try:
        subprocess.run(
            cmd,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass


def format_by_extension(file_path: str, ext: str) -> None:
    """根据扩展名选择 formatter"""
    # Rust
    if ext == ".rs":
        if has_command("rustfmt"):
            run_silent(["rustfmt", file_path])
        return

    # JS/TS/Web 系列 - prettier
    web_exts = {".ts", ".tsx", ".js", ".jsx", ".json", ".css", ".md", ".vue", ".html", ".yaml", ".yml", ".scss"}
    if ext in web_exts:
        if has_command("prettier"):
            run_silent(["prettier", "--write", file_path])
        elif has_command("npx"):
            run_silent(["npx", "--no-install", "prettier", "--write", file_path])
        return

    # Python - ruff 优先，fallback 到 black
    if ext == ".py":
        if has_command("ruff"):
            run_silent(["ruff", "format", file_path])
        elif has_command("black"):
            run_silent(["black", "-q", file_path])
        return

    # TOML
    if ext == ".toml":
        if has_command("taplo"):
            run_silent(["taplo", "format", file_path])
        return


def main() -> None:
    try:
        input_data = json.load(sys.stdin)
        tool_input = input_data.get("tool_input", {})
        file_path = tool_input.get("file_path", "")

        if not file_path:
            sys.exit(0)

        path = Path(file_path)
        if not path.exists():
            sys.exit(0)

        ext = path.suffix.lower()
        format_by_extension(str(path), ext)

        sys.exit(0)
    except json.JSONDecodeError:
        sys.exit(0)
    except Exception:
        sys.exit(0)


if __name__ == "__main__":
    main()
'@

    'block_dangerous.py' = @'
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.8"
# ///
"""
拦截红线清单中的高危 bash 命令。
事件: PreToolUse (Bash)
策略: 命中红线 exit 2 阻断执行 + stderr 反馈给 Claude
"""

import json
import re
import sys


# 红线规则: (正则, 标签)
DANGEROUS_PATTERNS = [
    # === 递归强制删除 ===
    (r"\brm\s+-[a-zA-Z]*r[a-zA-Z]*f", "rm -rf 类删除"),
    (r"\brm\s+-[a-zA-Z]*f[a-zA-Z]*r", "rm -fr 类删除"),
    (r"\brm\s+--recursive\s+--force", "rm --recursive --force"),
    (r"\brm\s+--force\s+--recursive", "rm --force --recursive"),
    (r"\brm\s+-rf?\s+[/~]", "rm -rf / 或 ~ 根目录/家目录"),
    (r"\brm\s+-rf?\s+\*", "rm -rf * 通配符"),

    # === PowerShell/Windows 删除 ===
    (r"Remove-Item\s+.*-Recurse.*-Force", "PowerShell 递归强删"),
    (r"\brd\s+/s\s+/q", "cmd rd /s /q"),
    (r"\brmdir\s+/s\s+/q", "cmd rmdir /s /q"),
    (r"\bdel\s+/[sf]\s+/[qf]", "cmd del /s /q"),

    # === 磁盘 / 格式化 ===
    (r"Format-Volume", "PowerShell 格式化卷"),
    (r"\bmkfs\.", "mkfs 格式化"),
    (r"\bformat\s+[a-zA-Z]:", "format C: 格式化分区"),
    (r"\bdiskpart\b", "diskpart 磁盘分区工具"),
    (r"\bdd\s+if=", "dd 块写入"),

    # === Git 危险操作 ===
    (r"git\s+push\s+.*--force(?!-with-lease)", "git push --force (无 with-lease)"),
    (r"git\s+push\s+.*\s-f(\s|$)", "git push -f"),
    (r"git\s+reset\s+--hard", "git reset --hard"),
    (r"git\s+rebase\s+(-i\s+)?\S", "git rebase 交互"),
    (r"git\s+clean\s+-[a-zA-Z]*f[a-zA-Z]*d", "git clean -fd"),

    # === 发布 / 发布工具 ===
    (r"npm\s+publish\b", "npm publish"),
    (r"cargo\s+publish\b", "cargo publish"),
    (r"pnpm\s+publish\b", "pnpm publish"),

    # === 敏感文件写入 ===
    (r">\s*\.env\b(?!\.sample|\.example|\.template)", "覆写 .env"),
    (r"Set-Content\s+.*\.env\b(?!\.sample)", "PowerShell 写入 .env"),
    (r"cat\s+\.env\b(?!\.sample|\.example)", "cat .env"),

    # === 数据库 ===
    (r"\bDROP\s+(TABLE|DATABASE|SCHEMA)\b", "SQL DROP"),
    (r"\bTRUNCATE\s+TABLE\b", "SQL TRUNCATE"),

    # === 系统级 ===
    (r"\bshutdown\s+/[srh]", "Windows shutdown"),
    (r"\bshutdown\s+-[rh]", "Unix shutdown"),
    (r"\bsudo\s+rm\b", "sudo rm"),
    (r"\bchmod\s+-R\s+777", "chmod -R 777 危险权限"),

    # === Pipe to shell ===
    (r"curl\s+[^|]+\|\s*(sh|bash|zsh|pwsh)", "curl | sh"),
    (r"wget\s+[^|]+\|\s*(sh|bash|zsh|pwsh)", "wget | sh"),
]


def main() -> None:
    try:
        input_data = json.load(sys.stdin)
        tool_name = input_data.get("tool_name", "")

        # 只检查 Bash 工具
        if tool_name != "Bash":
            sys.exit(0)

        command = input_data.get("tool_input", {}).get("command", "")
        if not command:
            sys.exit(0)

        # 逐条匹配
        for pattern, label in DANGEROUS_PATTERNS:
            if re.search(pattern, command, re.IGNORECASE):
                print("BLOCKED: 命中红线命令", file=sys.stderr)
                print(f"  规则: {label}", file=sys.stderr)
                print(f"  命令: {command[:300]}", file=sys.stderr)
                print("  如确需执行,请手动在终端运行。", file=sys.stderr)
                sys.exit(2)  # exit 2 阻断 PreToolUse 并反馈 Claude

        sys.exit(0)
    except json.JSONDecodeError:
        sys.exit(0)
    except Exception:
        sys.exit(0)


if __name__ == "__main__":
    main()
'@

    'check_secrets.py' = @'
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.8"
# ///
"""
检测 Claude 写入文件时是否包含密钥。
事件: PostToolUse (Write|Edit|MultiEdit) - 注意 PostToolUse 不可阻塞
策略: 写入已完成，输出 stderr 警告 + JSON decision=block 让 Claude 知道密钥泄露
关键升级: PostToolUse 用 exit 2 无法回滚写入，改用 JSON 输出告知 Claude
"""

import json
import re
import sys


# 高置信度密钥模式（大小写敏感匹配，降低误报）
SECRET_PATTERNS = [
    (r"sk-[a-zA-Z0-9]{20,}", "OpenAI/Anthropic API Key"),
    (r"sk-ant-[a-zA-Z0-9\-_]{20,}", "Anthropic Key (new format)"),
    (r"ghp_[a-zA-Z0-9]{36}", "GitHub Personal Access Token"),
    (r"github_pat_[a-zA-Z0-9_]{80,}", "GitHub fine-grained PAT"),
    (r"gho_[a-zA-Z0-9]{36}", "GitHub OAuth Token"),
    (r"AKIA[0-9A-Z]{16}", "AWS Access Key ID"),
    (r"AIza[0-9A-Za-z_\-]{35}", "Google API Key"),
    (r"xox[baprs]-[0-9a-zA-Z\-]{10,}", "Slack Token"),
    (r"-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----", "Private Key (PEM)"),
]


def is_false_positive(file_path: str) -> bool:
    """排除示例/测试文件"""
    lowered = file_path.lower()
    skip_keywords = [".env.sample", ".env.example", ".env.template",
                     "test", "spec", "mock", "fixture", "example", "sample"]
    return any(kw in lowered for kw in skip_keywords)


def extract_content(tool_input: dict) -> str:
    """从 tool_input 提取写入内容 (Write/Edit/MultiEdit 字段不同)"""
    # Write 用 content
    if "content" in tool_input and tool_input["content"]:
        return tool_input["content"]
    # Edit 用 new_string
    if "new_string" in tool_input and tool_input["new_string"]:
        return tool_input["new_string"]
    # MultiEdit 用 edits 数组
    if "edits" in tool_input:
        return "\n".join(
            edit.get("new_string", "")
            for edit in tool_input.get("edits", [])
        )
    return ""


def main() -> None:
    try:
        input_data = json.load(sys.stdin)
        tool_input = input_data.get("tool_input", {})
        file_path = tool_input.get("file_path", "")

        if is_false_positive(file_path):
            sys.exit(0)

        content = extract_content(tool_input)
        if not content:
            sys.exit(0)

        # 扫描所有模式
        hits = []
        for pattern, label in SECRET_PATTERNS:
            match = re.search(pattern, content)
            if match:
                # 显示前 8 字符 + 长度，避免日志再次泄露完整密钥
                snippet = match.group(0)[:8] + f"...({len(match.group(0))} chars)"
                hits.append(f"{label}: {snippet}")

        if not hits:
            sys.exit(0)

        # PostToolUse 不可阻塞写入,但可以用 JSON 输出告知 Claude 立刻修复
        reason = (
            f"SECURITY: Possible secret(s) detected in {file_path}:\n"
            + "\n".join(f"  - {h}" for h in hits)
            + "\nImmediate action: remove the value, move to .env (gitignored), "
              "or use environment variables. Then re-edit the file."
        )

        output = {
            "decision": "block",
            "reason": reason,
        }
        print(json.dumps(output))

        # 同时输出到 stderr 让用户看到
        print(f"[check-secrets] {len(hits)} secret pattern(s) hit in {file_path}",
              file=sys.stderr)
        for h in hits:
            print(f"  - {h}", file=sys.stderr)

        sys.exit(0)
    except json.JSONDecodeError:
        sys.exit(0)
    except Exception:
        sys.exit(0)


if __name__ == "__main__":
    main()
'@

    'verify_on_stop.py' = @'
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.8"
# ///
"""
Claude 说"完成"前轻量验证项目状态。
事件: Stop
策略: 仅在 git 仓库内运行；命中失败用 JSON decision=block 阻止结束
注意: 检查 stop_hook_active 避免无限循环
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path


def has_command(name: str) -> bool:
    return shutil.which(name) is not None


def run_quiet(cmd: list[str], timeout: int = 60) -> int:
    """运行命令并返回 exit code,失败返回 -1"""
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        return result.returncode
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return -1


def is_git_repo() -> bool:
    return run_quiet(["git", "rev-parse", "--git-dir"], timeout=5) == 0


def check_rust() -> str | None:
    if not Path("Cargo.toml").exists():
        return None
    if not has_command("cargo"):
        return None
    if run_quiet(["cargo", "check", "--quiet"], timeout=90) != 0:
        return "Rust: cargo check 未通过"
    return None


def check_typescript() -> str | None:
    if not Path("tsconfig.json").exists():
        return None

    # 选包管理器
    if Path("pnpm-lock.yaml").exists() and has_command("pnpm"):
        cmd = ["pnpm", "exec", "tsc", "--noEmit"]
    elif Path("bun.lockb").exists() and has_command("bun"):
        cmd = ["bun", "x", "tsc", "--noEmit"]
    elif has_command("npx"):
        cmd = ["npx", "--no-install", "tsc", "--noEmit"]
    else:
        return None

    if run_quiet(cmd, timeout=90) != 0:
        return "TypeScript: tsc --noEmit 未通过"
    return None


def check_python() -> str | None:
    if not (Path("pyproject.toml").exists() or Path("setup.py").exists()):
        return None
    if not has_command("ruff"):
        return None
    if run_quiet(["ruff", "check", ".", "--quiet"], timeout=30) != 0:
        return "Python: ruff check 未通过"
    return None


def main() -> None:
    try:
        input_data = json.load(sys.stdin)
        stop_hook_active = input_data.get("stop_hook_active", False)

        # 防止无限循环: 上轮 Stop hook 已经触发过验证,本轮直接放行
        if stop_hook_active:
            sys.exit(0)

        # 不在 git 仓库内则跳过
        if not is_git_repo():
            sys.exit(0)

        issues: list[str] = []

        # 逐项检查 (跳过 None,只收集有问题的)
        for checker in (check_rust, check_typescript, check_python):
            result = checker()
            if result:
                issues.append(result)

        if not issues:
            sys.exit(0)

        # 用 JSON 输出阻止 Claude 结束 + 给出可读 reason
        reason = (
            "完成前发现未通过的验证,请先修复:\n"
            + "\n".join(f"  - {i}" for i in issues)
        )
        output = {
            "decision": "block",
            "reason": reason,
        }
        print(json.dumps(output))

        # 同时输出到 stderr 给用户看
        print("[verify-on-stop] 验证未通过:", file=sys.stderr)
        for i in issues:
            print(f"  - {i}", file=sys.stderr)

        sys.exit(0)
    except json.JSONDecodeError:
        sys.exit(0)
    except Exception:
        sys.exit(0)


if __name__ == "__main__":
    main()
'@
}

# ============================================================
#  日志工具
# ============================================================
function Write-Step  { param($M) Write-Host "`n==> $M" -ForegroundColor Cyan }
function Write-Ok    { param($M) Write-Host "  [OK]    $M" -ForegroundColor Green }
function Write-Warn2 { param($M) Write-Host "  [WARN]  $M" -ForegroundColor Yellow }
function Write-Err   { param($M) Write-Host "  [ERROR] $M" -ForegroundColor Red }
function Write-Info  { param($M) Write-Host "  $M" -ForegroundColor Gray }

function Has-Command {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# ============================================================
#  安装模式选择
# ============================================================
function Read-InstallMode {
    Write-Host ''
    Write-Host '  请选择安装模式：' -ForegroundColor White
    Write-Host ''
    Write-Host '    [1] 仅安装 Claude Code（推荐）' -ForegroundColor Green
    Write-Host '        安装 Claude Code 本体 + PATH 配置' -ForegroundColor Gray
    Write-Host '        不下载任何 hooks 或 status_line' -ForegroundColor Gray
    Write-Host ''
    Write-Host '    [2] 完整安装（软件 + hooks）' -ForegroundColor Yellow
    Write-Host '        安装 Claude Code + 从第三方仓库下载 6 个 hooks 和 status_line' -ForegroundColor Gray
    Write-Host '        注意：hooks 来自 disler/claude-code-hooks-mastery，会自动校验 SHA256' -ForegroundColor Gray
    Write-Host ''

    while ($true) {
        Write-Host '  请输入选择 [1/2]（默认 1）：' -ForegroundColor Cyan -NoNewline
        $choice = (Read-Host).Trim()
        if ([string]::IsNullOrEmpty($choice)) { $choice = '1' }
        switch ($choice) {
            '1' { return 'Minimal' }
            '2' { return 'Full' }
            default { Write-Host '  无效输入，请输入 1 或 2' -ForegroundColor Red }
        }
    }
}

# ============================================================
#  阶段 1：前置环境检测
# ============================================================
function Test-Prerequisites {
    Write-Step '前置环境检测'

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Err "需要 PowerShell 5.1+，当前 $($PSVersionTable.PSVersion)"
        exit 1
    }
    Write-Ok "PowerShell $($PSVersionTable.PSVersion)"

    if (-not [Environment]::Is64BitOperatingSystem) {
        Write-Err 'Claude Code 不支持 32 位 Windows'
        exit 1
    }
    Write-Ok '64 位 Windows'

    if (Has-Command 'git') {
        $gitVer = (& git --version) -replace 'git version ', ''
        Write-Ok "Git $gitVer"
    } else {
        Write-Warn2 'Git 未安装。verify_on_stop.py / session_start.py 依赖 Git'
        Write-Info '  建议安装：winget install Git.Git'
    }

    if (Has-Command 'uv') {
        $uvVer = (& uv --version) -replace 'uv ', ''
        Write-Ok "UV $uvVer"
    } else {
        Write-Warn2 'UV 未安装，正在自动安装...'
        try {
            # trust-on-first-use: 官方安装脚本内容随版本变化，无法 pin 固定哈希
            # 安全依赖 HTTPS 传输层保护 + 安装后二进制验证
            $uvInstallScript = Invoke-RestMethod 'https://astral.sh/uv/install.ps1' -TimeoutSec 30
            $uvInstallScript | Invoke-Expression
            if (Has-Command 'uv') {
                Write-Ok 'UV 安装成功'
            } else {
                Write-Err 'UV 自动安装失败，请手动运行：irm https://astral.sh/uv/install.ps1 | iex'
                exit 1
            }
        } catch {
            Write-Err "UV 自动安装失败：$_"
            exit 1
        }
    }

    if (Has-Command 'node') {
        $nodeVer = (& node --version)
        Write-Ok "Node.js $nodeVer（npm 兜底备用）"
    } else {
        Write-Info 'Node.js 未安装（仅 npm 兜底需要）'
    }
}

# ============================================================
#  阶段 2a：Claude Code 安装
# ============================================================
function Install-Native {
    Write-Info '方式 1/3：原生二进制（GCS 直连）'

    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win32-arm64' } else { 'win32-x64' }
    Write-Info "  架构: $arch"

    New-Item -ItemType Directory -Force -Path $VERSIONS_DIR, $BIN_DIR | Out-Null
    $tmpDir = Join-Path $env:TEMP 'claude-install'
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

    $job = Start-Job -ScriptBlock {
        param($GCS, $arch, $tmpDir, $VERSIONS_DIR, $BIN_DIR, $LINK_PATH, $Target)
        $ProgressPreference = 'SilentlyContinue'

        # 决定目标版本
        if ($Target -eq 'latest' -or $Target -eq 'stable') {
            $version = (Invoke-RestMethod "$GCS/latest" -TimeoutSec 30).ToString().Trim()
        } else {
            $version = $Target
        }

        $manifest = Invoke-RestMethod "$GCS/$version/manifest.json" -TimeoutSec 30
        $checksum = $manifest.platforms.$arch.checksum
        $size     = $manifest.platforms.$arch.size
        if (-not $checksum) { throw "Platform $arch not in manifest" }

        $binaryPath  = Join-Path $tmpDir "claude-$version-$arch.exe"
        $downloadUrl = "$GCS/$version/$arch/claude.exe"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $binaryPath -TimeoutSec 60 -ErrorAction Stop

        if ($size -and ((Get-Item $binaryPath).Length -ne [int64]$size)) {
            throw "Size mismatch: expected $size, got $((Get-Item $binaryPath).Length)"
        }

        $actual = (Get-FileHash -Path $binaryPath -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $checksum) {
            throw "SHA256 mismatch: expected $checksum, got $actual"
        }

        $finalPath = Join-Path $VERSIONS_DIR "$version.exe"
        Move-Item -Force $binaryPath $finalPath
        Copy-Item -Force $finalPath $LINK_PATH

        return @{ Version = $version }
    } -ArgumentList $GCS_BUCKET, $arch, $tmpDir, $VERSIONS_DIR, $BIN_DIR, $LINK_PATH, $ClaudeVersion

    $finished = Wait-Job $job -Timeout $InstallTimeout
    if ($null -eq $finished) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        throw "Native 安装超时（$InstallTimeout 秒）"
    }

    if ($job.State -eq 'Failed') {
        $reason = $job.ChildJobs[0].JobStateInfo.Reason.Message
        Remove-Job $job -Force
        throw "Native 安装失败：$reason"
    }

    $result = Receive-Job $job
    Remove-Job $job -Force

    # 写 .claude.json 标记 native
    $cfg = @{}
    if (Test-Path $CONFIG_PATH) {
        try { $cfg = Get-Content -Raw $CONFIG_PATH | ConvertFrom-Json -AsHashtable } catch {}
    }
    if ($null -eq $cfg) { $cfg = @{} }
    $cfg['installMethod'] = 'native'
    $cfg['autoUpdates']   = $false
    if (-not $cfg.ContainsKey('firstStartTime')) {
        $cfg['firstStartTime'] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $CONFIG_PATH -Encoding UTF8

    Write-Ok "Native 安装成功 v$($result.Version)"
    return 'native'
}

function Install-Winget {
    Write-Info '方式 2/3：winget'
    if (-not (Has-Command 'winget')) {
        throw 'winget 不可用（需要 Windows 10 1809+ 或手动安装 App Installer）'
    }
    & winget install --id Anthropic.ClaudeCode -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget 退出码 $LASTEXITCODE" }
    Write-Ok 'winget 安装成功'
    return 'winget'
}

function Install-Npm {
    Write-Info '方式 3/3：npm 全局（官方已不推荐，仅作兜底）'
    if (-not (Has-Command 'npm')) {
        throw 'npm 未安装。请先安装 Node.js: winget install OpenJS.NodeJS.LTS'
    }
    & npm install -g @anthropic-ai/claude-code
    if ($LASTEXITCODE -ne 0) { throw "npm 退出码 $LASTEXITCODE" }
    Write-Ok 'npm 安装成功'
    return 'npm'
}

# ============================================================
#  阶段 2b：PATH 健康检查（任何安装方式都跑）
# ============================================================
function Add-DirToUserPath {
    param(
        [string]$Dir,
        [string]$Reason
    )
    if ([string]::IsNullOrEmpty($Dir) -or -not (Test-Path $Dir)) { return }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -like "*$Dir*") {
        Write-Info "    PATH 已有：$Dir"
        return
    }
    $newPath = "$userPath;$Dir"
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    $env:Path = "$env:Path;$Dir"
    Write-Ok "    PATH 已添加（$Reason）：$Dir"
}

function Ensure-ClaudeOnPath {
    param([string]$InstallMethod)

    Write-Info '  PATH 健康检查...'

    if (Has-Command 'claude') {
        $cmd = (Get-Command 'claude').Source
        Write-Ok "    claude 可执行：$cmd"
        return $true
    }

    switch ($InstallMethod) {
        'native' {
            Add-DirToUserPath -Dir $BIN_DIR -Reason 'native 安装目录'
        }
        'winget' {
            $candidates = @(
                (Join-Path $env:ProgramFiles 'Claude Code'),
                (Join-Path $env:LOCALAPPDATA 'Programs\claude-code'),
                (Join-Path $env:LOCALAPPDATA 'Programs\Claude Code')
            )
            foreach ($d in $candidates) {
                if (Test-Path (Join-Path $d 'claude.exe')) {
                    Add-DirToUserPath -Dir $d -Reason 'winget 安装目录'
                    break
                }
            }
        }
        'npm' {
            if (Has-Command 'npm') {
                $npmPrefix = (& npm config get prefix).Trim()
                if ($npmPrefix -and (Test-Path (Join-Path $npmPrefix 'claude.cmd'))) {
                    Add-DirToUserPath -Dir $npmPrefix -Reason 'npm 全局目录'
                } else {
                    Write-Warn2 "    npm prefix 不含 claude：$npmPrefix"
                }
            }
        }
    }

    # 刷新当前进程 PATH 后再校验
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')

    if (Has-Command 'claude') {
        Write-Ok "    PATH 校验通过：$((Get-Command 'claude').Source)"
        return $true
    } else {
        Write-Warn2 "    claude 仍不可见，建议重开 PowerShell"
        return $false
    }
}

function Install-ClaudeCode {
    Write-Step 'Claude Code 安装（三级兜底）'

    if (Has-Command 'claude') {
        $existing = (& claude --version 2>$null) -join ''
        Write-Ok "已检测到 Claude Code: $existing，跳过安装"
        Ensure-ClaudeOnPath -InstallMethod 'native' | Out-Null
        return
    }

    $methods = @(
        @{ Name = 'Native (GCS 直连)'; Action = { Install-Native } },
        @{ Name = 'winget';            Action = { Install-Winget } },
        @{ Name = 'npm';               Action = { Install-Npm } }
    )

    $succeeded = $null
    foreach ($m in $methods) {
        try {
            $succeeded = & $m.Action
            break
        } catch {
            Write-Warn2 "$($m.Name) 失败：$_"
        }
    }

    if (-not $succeeded) {
        Write-Err '三种安装方式全部失败，请手动安装后重试（可加 -SkipClaudeInstall）'
        exit 1
    }

    # 统一做 PATH 处理（无论哪种方式都跑）
    Ensure-ClaudeOnPath -InstallMethod $succeeded | Out-Null
}

# ============================================================
#  阶段 3：用户自写 hooks 部署（从嵌入内容写入，离线可用）
# ============================================================
function Install-UserHooks {
    Write-Step '部署用户自写 hooks（来自仓库嵌入内容）'

    New-Item -ItemType Directory -Force -Path $HOOK_DIR | Out-Null
    Write-Info "  hooks 目录：$HOOK_DIR"

    foreach ($f in $USER_HOOKS) {
        $dest = Join-Path $HOOK_DIR $f
        if (Test-Path $dest) {
            Write-Info "    [SKIP] $f（已存在，不覆盖）"
            continue
        }
        if (-not $USER_HOOKS_CONTENT.ContainsKey($f)) {
            Write-Warn2 "    [SKIP] $f（嵌入内容缺失）"
            continue
        }
        Write-Info "    [WRITE] $f"
        try {
            $content = $USER_HOOKS_CONTENT[$f]
            # 用 UTF-8 无 BOM 写入（跨 PS 5.1/7+ 一致），保证 SHA256 跨平台一致
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($dest, $content, $utf8NoBom)
            # SHA256 校验
            if ($CHECKSUMS.ContainsKey($f)) {
                $actual = (Get-FileHash -Path $dest -Algorithm SHA256).Hash.ToUpper()
                $expected = $CHECKSUMS[$f].ToUpper()
                if ($actual -ne $expected) {
                    Remove-Item $dest -Force -ErrorAction SilentlyContinue
                    throw "SHA256 mismatch: expected $expected, got $actual"
                }
                Write-Ok "    $f (SHA256 verified)"
            } else {
                Write-Warn2 "    $f (no checksum - skip verification)"
            }
        } catch {
            Write-Err "    $f 写入失败：$_"
        }
    }
}

# ============================================================
#  阶段 3.5：写入 ~/.claude/settings.json（合并 GeneralConfiguration）
# ============================================================
function Install-SettingsJson {
    Write-Step '生成 ~/.claude/settings.json（启用 hooks）'

    $SETTINGS_PATH = Join-Path $CLAUDE_HOME 'settings.json'

    # 基础配置：插件 + 状态行 + hooks + 权限
    $settings = [ordered]@{
        '$schema'                  = 'https://json.schemastore.org/claude-code-settings.json'
        'enabledPlugins'           = [ordered]@{
            'feature-dev@claude-plugins-official' = $true
        }
        'env'                      = [ordered]@{
            'DISABLE_AUTO_COMPACT'                       = '1'
            'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'   = '1'
        }
        'autoConnectIde'           = $true
        'statusLine'               = [ordered]@{
            'type'    = 'command'
            'command' = 'uv run --script ~/.claude/status_lines/status_line_v6.py'
        }
        'hooks'                    = [ordered]@{
            'SessionStart'        = @(
                [ordered]@{
                    'hooks' = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/session_start.py --load-context'
                            'timeout' = 15
                        }
                    )
                }
            )
            'UserPromptSubmit'    = @(
                [ordered]@{
                    'hooks' = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/user_prompt_submit.py --log-only'
                            'timeout' = 10
                        }
                    )
                }
            )
            'PreToolUse'          = @(
                [ordered]@{
                    'matcher' = 'Bash'
                    'hooks'   = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/block_dangerous.py'
                            'timeout' = 15
                        },
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/pre_tool_use.py'
                            'timeout' = 10
                        }
                    )
                },
                [ordered]@{
                    'matcher' = 'Read|Edit|MultiEdit|Write'
                    'hooks'   = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/pre_tool_use.py'
                            'timeout' = 10
                        }
                    )
                }
            )
            'PostToolUse'         = @(
                [ordered]@{
                    'matcher' = 'Write|Edit|MultiEdit'
                    'hooks'   = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/auto_format.py'
                            'timeout' = 30
                        },
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/check_secrets.py'
                            'timeout' = 15
                        },
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/post_tool_use.py'
                            'timeout' = 10
                        }
                    )
                }
            )
            'PostToolUseFailure'  = @(
                [ordered]@{
                    'hooks' = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/post_tool_use_failure.py'
                            'timeout' = 10
                        }
                    )
                }
            )
            'Stop'                = @(
                [ordered]@{
                    'hooks' = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/verify_on_stop.py'
                            'timeout' = 120
                        }
                    )
                }
            )
            'SessionEnd'          = @(
                [ordered]@{
                    'hooks' = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/session_end.py'
                            'timeout' = 10
                        }
                    )
                }
            )
        }
        'permissions'              = [ordered]@{
            'allow'                              = @(
                'Bash(cargo check*)', 'Bash(cargo build*)', 'Bash(cargo test*)',
                'Bash(cargo fmt*)', 'Bash(cargo tauri*)',
                'Bash(npm run*)', 'Bash(pnpm*)', 'Bash(bun*)',
                'Bash(uv run*)', 'Bash(uv pip*)', 'Bash(ruff*)',
                'Bash(rg*)', 'Bash(fd*)',
                'Bash(git status*)', 'Bash(git diff*)', 'Bash(git log*)',
                'Bash(git add*)', 'Bash(git commit*)', 'Bash(git push*)',
                'Bash(git pull*)', 'Bash(git checkout*)', 'Bash(git branch*)'
            )
            'deny'                               = @(
                'Read(./.env)', 'Read(./.env.*)', 'Read(./secrets/**)',
                'Read(**/id_rsa)', 'Read(**/id_ed25519)',
                'Bash(curl http://*)'
            )
            'defaultMode'                        = 'bypassPermissions'
            'skipDangerousModePermissionPrompt'  = $true
        }
    }

    try {
        $json = $settings | ConvertTo-Json -Depth 10
        Set-Content -Path $SETTINGS_PATH -Value $json -Encoding UTF8
        Write-Ok "  $SETTINGS_PATH"
        Write-Info '  包含：enabledPlugins + env + statusLine + 7 个 hooks 事件 + permissions'
    } catch {
        Write-Err "  settings.json 写入失败：$_"
    }
}

# ============================================================
#  阶段 3：hooks 与 status_line 部署
# ============================================================
function Invoke-DownloadFile {
    param(
        [string[]]$Urls,
        [string]$Dest,
        [int]$MaxRetry = 3
    )
    foreach ($url in $Urls) {
        for ($i = 1; $i -le $MaxRetry; $i++) {
            try {
                Invoke-WebRequest -Uri $url -OutFile $Dest -TimeoutSec 30 -ErrorAction Stop
                if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 0) {
                    return $true
                }
                throw '下载文件为空'
            } catch {
                if ($i -eq $MaxRetry) {
                    Write-Warn2 "    源 $url 失败：$_"
                    break
                }
                Start-Sleep -Seconds 2
            }
        }
    }
    throw "所有源均下载失败：$($Urls -join ', ')"
}

function Install-Hooks {
    Write-Step '部署 hooks 与 status_line'

    New-Item -ItemType Directory -Force -Path $HOOK_DIR, $SL_DIR, $LOG_DIR | Out-Null
    Write-Ok "目录就绪：$CLAUDE_HOME"

    Write-Info '  下载 disler 仓库的 6 个 hooks:'
    foreach ($f in $DISLER_HOOKS) {
        $dest = Join-Path $HOOK_DIR $f
        if (Test-Path $dest) {
            Write-Info "    [SKIP] $f（已存在）"
            continue
        }
        Write-Info "    [GET ] $f"
        try {
            $urls = $REPO_BASES | ForEach-Object { "$_/hooks/$f" }
            Invoke-DownloadFile -Urls $urls -Dest $dest
            # SHA256 校验
            if ($CHECKSUMS.ContainsKey($f)) {
                $actual = (Get-FileHash -Path $dest -Algorithm SHA256).Hash.ToUpper()
                $expected = $CHECKSUMS[$f].ToUpper()
                if ($actual -ne $expected) {
                    Remove-Item $dest -Force -ErrorAction SilentlyContinue
                    throw "SHA256 mismatch: expected $expected, got $actual"
                }
                Write-Ok "    $f (SHA256 verified)"
            } else {
                Write-Warn2 "    $f (no checksum - skip verification)"
            }
        } catch {
            Write-Err "    $f 下载失败：$_"
        }
    }

    $slDest = Join-Path $SL_DIR $STATUS_LINE
    if (Test-Path $slDest) {
        Write-Info "  [SKIP] $STATUS_LINE（已存在）"
    } else {
        Write-Info "  [GET ] $STATUS_LINE"
        try {
            $slUrls = $REPO_BASES | ForEach-Object { "$_/status_lines/$STATUS_LINE" }
            Invoke-DownloadFile -Urls $slUrls -Dest $slDest
            # SHA256 校验
            if ($CHECKSUMS.ContainsKey($STATUS_LINE)) {
                $actual = (Get-FileHash -Path $slDest -Algorithm SHA256).Hash.ToUpper()
                $expected = $CHECKSUMS[$STATUS_LINE].ToUpper()
                if ($actual -ne $expected) {
                    Remove-Item $slDest -Force -ErrorAction SilentlyContinue
                    throw "SHA256 mismatch: expected $expected, got $actual"
                }
                Write-Ok "  $STATUS_LINE (SHA256 verified)"
            } else {
                Write-Warn2 "  $STATUS_LINE (no checksum - skip verification)"
            }
        } catch {
            Write-Err "  $STATUS_LINE 下载失败：$_"
        }
    }
}

# ============================================================
#  阶段 4：完成总结
# ============================================================
function Show-Summary {
    Write-Step '部署完成'

    if ($InstallMode -eq 'Full') {
        $hookCount = (Get-ChildItem $HOOK_DIR -Filter *.py -ErrorAction SilentlyContinue).Count
        $slCount   = (Get-ChildItem $SL_DIR -Filter *.py -ErrorAction SilentlyContinue).Count
        $settingsExists = Test-Path (Join-Path $CLAUDE_HOME 'settings.json')

        Write-Info ''
        Write-Host '  已部署文件：' -ForegroundColor White
        Write-Info "    hooks 目录：$hookCount 个 .py（含 4 个用户自写）"
        Write-Info "    status_line 目录：$slCount 个 .py"
        Write-Info "    settings.json：$(if ($settingsExists) { '已生成 ✓' } else { '未生成 ✗' })"
    } else {
        Write-Info ''
        Write-Host '  已部署文件：' -ForegroundColor White
        Write-Info '    Claude Code 本体（hooks 未安装）'
    }

    Write-Info ''
    Write-Host '  后续步骤：' -ForegroundColor White
    Write-Info '    1. 打开 cc-switch 切换到任意供应商（hooks 已自动启用）'
    Write-Info '    2. 启动 Claude Code 验证：第一次会话应看到 status line 进度条'
    if ($InstallMode -eq 'Full') {
        Write-Info '    3. 测试：写一个 .py 文件，应自动 ruff format'
    } else {
        Write-Info '    3. 如需 hooks，运行：.\setup-claude.ps1 -InstallMode Full -SkipClaudeInstall'
    }

    Write-Info ''
    Write-Host '  验证命令：' -ForegroundColor White
    Write-Info '    claude --version'
    Write-Info '    uv --version'
    if ($InstallMode -eq 'Full') {
        Write-Info "    cat $((Join-Path $CLAUDE_HOME 'settings.json')) | ConvertFrom-Json"
    }

    Write-Host ''
    Write-Host '  [OK] 一切就绪' -ForegroundColor Green
    Write-Host ''
}

# ============================================================
#  主流程
# ============================================================
try {
    Write-Host ''
    Write-Host '  Claude Code 一键部署脚本' -ForegroundColor Cyan
    Write-Host '  =========================' -ForegroundColor Cyan

    # 确定安装模式
    if (-not $InstallMode) {
        $InstallMode = Read-InstallMode
    }
    Write-Host ''
    Write-Host "  安装模式：$InstallMode" -ForegroundColor $(if ($InstallMode -eq 'Full') { 'Yellow' } else { 'Green' })

    Test-Prerequisites
    if (-not $SkipClaudeInstall) { Install-ClaudeCode }
    else { Write-Step 'Claude Code 安装：已跳过（-SkipClaudeInstall）' }

    if ($InstallMode -eq 'Full') {
        Install-UserHooks
        Install-Hooks
        Install-SettingsJson
    } else {
        Write-Step 'hooks 部署：已跳过（Minimal 模式）'
        Write-Info '  如需后续安装 hooks，可重新运行并选择 Full 模式：'
        Write-Info '    .\setup-claude.ps1 -InstallMode Full -SkipClaudeInstall'
    }

    Show-Summary
} catch {
    Write-Host ''
    Write-Host "  [FATAL] $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}
