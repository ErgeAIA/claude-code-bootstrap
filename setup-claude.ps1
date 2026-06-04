<#
.SYNOPSIS
    Claude Code 一键部署脚本（环境检测 + 安装 + hooks 部署）
.DESCRIPTION
    1. 前置环境检测：PowerShell、64 位、Git、UV（自动安装）
       Node.js 仅 npm 兜底时自动安装，native/winget 不需要
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
chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

# ============================================================
#  常量
# ============================================================
$GCS_BUCKET   = 'https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases'
$REPO_BASE = 'https://raw.githubusercontent.com/disler/claude-code-hooks-mastery/main/.claude'

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
    'auto_format.py'          = 'BAF7FA4737BAE65C23D42E24CFCE902881ABC3DE43C24F10DE34A3475D50B2C8'
    'block_dangerous.py'      = '769A7996ECD918B2611EA853330B340F8055AEEE3054B5E1F02650E47913A05F'
    'check_secrets.py'        = 'AA4127A6DA1052F5CDF61EED1960A12902494ABBD73DC631EC3ACDCE8C55192E'
    'verify_on_stop.py'       = '9E4EF09A78183EDC1833CB4794AA90959DFD32382EAF3BCA14DCF63DFD530ED5'
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
from __future__ import annotations
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


FORMAT_TIMEOUT_S = 30

# (扩展名集合, 候选命令模板列表 — 第一个可用命令胜出, "{path}" 占位符替换为文件路径)
FORMATTERS: list[tuple[frozenset[str], list[list[str]]]] = [
    (frozenset({".rs"}), [["rustfmt", "{path}"]]),
    (frozenset({".ts", ".tsx", ".js", ".jsx", ".json", ".css", ".md",
                ".vue", ".html", ".yaml", ".yml", ".scss"}),
     [["prettier", "--write", "{path}"],
      ["npx", "--no-install", "prettier", "--write", "{path}"]]),
    (frozenset({".py"}), [["ruff", "format", "{path}"],
                           ["black", "-q", "{path}"]]),
    (frozenset({".toml"}), [["taplo", "format", "{path}"]]),
]


def has_command(name: str) -> bool:
    """检查命令是否在 PATH 中可用"""
    return shutil.which(name) is not None


def run_silent(cmd: list[str], timeout: int = FORMAT_TIMEOUT_S) -> bool:
    """静默执行命令。
    Returns:
        True  = 命令返回 0
        False = 命令返回非零 / 超时 / 命令不存在
    """
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return False


def format_by_extension(path: Path) -> None:
    """根据扩展名选择 formatter"""
    ext = path.suffix.lower()
    for exts, candidates in FORMATTERS:
        if ext not in exts:
            continue
        for tmpl in candidates:
            cmd = [arg.replace("{path}", str(path)) for arg in tmpl]
            if has_command(cmd[0]):
                run_silent(cmd)
                return
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

        format_by_extension(path)

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
from __future__ import annotations
"""
拦截红线清单中的高危 bash 命令。
事件: PreToolUse (Bash)
策略: 命中红线 exit 2 阻断执行 + JSON output + stderr 反馈给 Claude
"""

import json
import re
import sys
from typing import NamedTuple


class Rule(NamedTuple):
    pattern: str
    label: str
    severity: str   # "critical" / "high" / "medium"
    why: str        # 一句话解释为什么危险


# 红线规则
DANGEROUS_RULES: list[Rule] = [
    # === CRITICAL: 不可逆数据丢失 ===
    Rule(r"\brm\s+-[a-zA-Z]*[rf][a-zA-Z]*[rf]", "rm -rf/fr 类删除", "critical",
         "递归强制删除，文件不可恢复"),
    Rule(r"\brm\s+--recursive\s+--force", "rm --recursive --force", "critical",
         "长选项等价 rm -rf"),
    Rule(r"\brm\s+--force\s+--recursive", "rm --force --recursive", "critical",
         "长选项等价 rm -rf"),
    Rule(r"\brm\s+-rf?\s+[/~]", "rm -rf / 或 ~ 根目录/家目录", "critical",
         "删除根目录或用户家目录，系统不可恢复"),
    Rule(r"\brm\s+-rf?\s+\*", "rm -rf * 通配符", "critical",
         "通配符删除当前目录所有文件"),

    # === PowerShell/Windows 删除 ===
    Rule(r"Remove-Item\s+.*(-Recurse.*-Force|-Force.*-Recurse)", "PowerShell 递归强删", "critical",
         "PowerShell 递归强制删除（参数顺序无关）"),
    Rule(r"\brd\s+/s\s+/q", "cmd rd /s /q", "critical",
         "cmd 静默递归删除目录"),
    Rule(r"\brmdir\s+/s\s+/q", "cmd rmdir /s /q", "critical",
         "cmd 静默递归删除目录"),
    Rule(r"\bdel\s+/[sf]\s+/[qf]", "cmd del /s /q", "high",
         "cmd 静默递归删除文件"),

    # === 磁盘 / 格式化 ===
    Rule(r"Format-Volume", "PowerShell 格式化卷", "critical",
         "格式化磁盘卷，所有数据丢失"),
    Rule(r"\bmkfs\.", "mkfs 格式化", "critical",
         "创建文件系统，等同格式化"),
    Rule(r"\bformat\s+[a-zA-Z]:", "format C: 格式化分区", "critical",
         "格式化分区，所有数据丢失"),
    Rule(r"\bdiskpart\b", "diskpart 磁盘分区工具", "critical",
         "磁盘分区操作，可导致数据丢失"),
    Rule(r"\bdd\s+if=", "dd 块写入", "critical",
         "底层块写入，误操作可覆盖整盘"),

    # === Git 危险操作 ===
    Rule(r"git\s+push\s+.*--force(?!-with-lease)", "git push --force (无 with-lease)", "medium",
         "覆盖远端历史，可能影响协作者"),
    Rule(r"git\s+push\s+\S*\s*-f\b", "git push -f", "medium",
         "覆盖远端历史，可能影响协作者"),
    Rule(r"git\s+reset\s+--hard", "git reset --hard", "high",
         "丢弃未提交修改，工作区不可恢复"),
    Rule(r"git\s+rebase\s+(-i\s+)?\S", "git rebase 交互", "medium",
         "重写提交历史，可能导致冲突"),
    Rule(r"git\s+clean\s+-[a-zA-Z]*f[a-zA-Z]*d", "git clean -fd", "high",
         "删除未跟踪文件和目录"),

    # === 发布 / 发布工具 ===
    Rule(r"npm\s+publish\b", "npm publish", "medium",
         "发布包到 npm 仓库，不可撤回"),
    Rule(r"cargo\s+publish\b", "cargo publish", "medium",
         "发布 crate 到 crates.io，不可撤回"),
    Rule(r"pnpm\s+publish\b", "pnpm publish", "medium",
         "发布包到 npm 仓库，不可撤回"),

    # === 敏感文件写入 ===
    Rule(r">\s*\.env\b(?!\.sample|\.example|\.template)", "覆写 .env", "high",
         "覆盖环境变量文件，可能丢失密钥配置"),
    Rule(r"Set-Content\s+.*\.env\b(?!\.sample)", "PowerShell 写入 .env", "high",
         "覆盖环境变量文件"),
    Rule(r"cat\s+\.env\b(?!\.sample|\.example)", "cat .env", "medium",
         "读取环境变量文件，可能泄露密钥"),

    # === 数据库 ===
    Rule(r"\bDROP\s+(TABLE|DATABASE|SCHEMA)\b", "SQL DROP", "critical",
         "删除数据库表/库，数据不可恢复"),
    Rule(r"\bTRUNCATE\s+TABLE\b", "SQL TRUNCATE", "high",
         "清空表数据，不可恢复"),

    # === 系统级 ===
    Rule(r"\bshutdown\s+/[srh]", "Windows shutdown", "critical",
         "关闭/重启 Windows 系统"),
    Rule(r"\bshutdown\s+-[rh]", "Unix shutdown", "critical",
         "关闭/重启 Unix 系统"),
    Rule(r"\bsudo\s+rm\b", "sudo rm", "critical",
         "以 root 权限删除文件"),
    Rule(r"\bchmod\s+-R\s+777", "chmod -R 777 危险权限", "high",
         "递归设置全开放权限，安全风险"),

    # === Pipe to shell ===
    Rule(r"curl\s+[^|]+\|\s*(sh|bash|zsh|pwsh)", "curl | sh", "critical",
         "从网络下载脚本直接执行，供应链攻击风险"),
    Rule(r"wget\s+[^|]+\|\s*(sh|bash|zsh|pwsh)", "wget | sh", "critical",
         "从网络下载脚本直接执行，供应链攻击风险"),
]

# 模块加载时预编译正则
_COMPILED_RULES: list[tuple[re.Pattern, Rule]] = [
    (re.compile(r.pattern, re.IGNORECASE), r) for r in DANGEROUS_RULES
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

        # 逐条匹配（预编译正则）
        for compiled, rule in _COMPILED_RULES:
            if compiled.search(command):
                # 截断命令显示
                display = command[:300]
                if len(command) > 300:
                    display += f"... (总 {len(command)} 字符)"

                # JSON output（与其他 hook 对齐）
                output = {
                    "decision": "block",
                    "reason": (
                        f"命中红线命令 [{rule.severity}]: {rule.label}\n"
                        f"  原因: {rule.why}\n"
                        f"  命令: {display}\n"
                        f"  如确需执行,请手动在终端运行。"
                    ),
                }
                print(json.dumps(output, ensure_ascii=False))

                # 同时输出到 stderr
                print("BLOCKED: 命中红线命令", file=sys.stderr)
                print(f"  级别: {rule.severity}", file=sys.stderr)
                print(f"  规则: {rule.label}", file=sys.stderr)
                print(f"  原因: {rule.why}", file=sys.stderr)
                print(f"  命令: {display}", file=sys.stderr)
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
from __future__ import annotations
"""
检测 Claude 写入文件时是否包含密钥。
事件: PostToolUse (Write|Edit|MultiEdit) - 注意 PostToolUse 不可阻塞
策略: 写入已完成,通过 hookSpecificOutput.additionalContext 注入上下文,
      让 Claude 下一轮主动修复(避免使用 decision=block 在 PostToolUse 阶段的语义歧义)
"""

import json
import re
import sys


# 高置信度密钥模式（大小写敏感匹配，降低误报）
SECRET_PATTERNS: list[tuple[str, str]] = [
    # OpenAI
    (r"sk-proj-[a-zA-Z0-9\-_]{20,}", "OpenAI Project Key"),
    (r"sk-(?!proj-|ant-)[a-zA-Z0-9]{20,}", "OpenAI API Key"),
    # Anthropic
    (r"sk-ant-[a-zA-Z0-9\-_]{20,}", "Anthropic API Key"),
    # GitHub
    (r"github_pat_[a-zA-Z0-9_]{80,}", "GitHub fine-grained PAT"),
    (r"ghp_[a-zA-Z0-9]{36}", "GitHub Personal Access Token"),
    (r"gho_[a-zA-Z0-9]{36}", "GitHub OAuth Token"),
    (r"ghs_[a-zA-Z0-9]{36}", "GitHub Server Token"),
    (r"ghr_[a-zA-Z0-9]{36}", "GitHub Refresh Token"),
    # AWS
    (r"AKIA[0-9A-Z]{16}", "AWS Access Key ID"),
    (r"ASIA[0-9A-Z]{16}", "AWS Session Key"),
    # Google
    (r"AIza[0-9A-Za-z_\-]{35}", "Google API Key"),
    # Slack
    (r"xox[baprs]-[0-9a-zA-Z\-]{10,}", "Slack Token"),
    # Stripe
    (r"sk_live_[0-9a-zA-Z]{24,}", "Stripe Live Key"),
    # PEM 私钥
    (r"-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----", "Private Key (PEM)"),
]

# 模块加载时预编译正则
_COMPILED_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(p), label) for p, label in SECRET_PATTERNS
]

# 路径段精确匹配（目录名，避免 "test_utils.py" 误命中 "test"）
_SKIP_PATH_SEGMENTS = {
    "tests", "test", "__tests__", "spec", "specs",
    "fixtures", "mocks", "examples", "samples", "testdata",
    "docs", "documentation",
}

# 文件后缀精确匹配
_SKIP_SUFFIXES = {".env.sample", ".env.example", ".env.template", ".env.dist"}


def is_false_positive(file_path: str) -> bool:
    """排除示例/测试文件（路径段精确匹配，避免误报）"""
    norm = file_path.replace("\\", "/").lower()
    # 后缀精确匹配
    for suf in _SKIP_SUFFIXES:
        if norm.endswith(suf):
            return True
    # 路径段精确匹配
    parts = set(norm.split("/"))
    return bool(parts & _SKIP_PATH_SEGMENTS)


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
        parts = [e.get("new_string", "") for e in tool_input.get("edits", [])]
        return "\n".join(p for p in parts if p)
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

        # 扫描所有模式（预编译正则）
        hits = []
        for compiled, label in _COMPILED_PATTERNS:
            for match in compiled.finditer(content):
                # 显示行号 + 长度，不输出密钥片段
                line_num = content[: match.start()].count("\n") + 1
                snippet = f"<line {line_num}, {len(match.group(0))} chars>"
                hits.append(f"{label}: {snippet}")

        if not hits:
            sys.exit(0)

        # PostToolUse 不可阻塞写入,通过 hookSpecificOutput.additionalContext
        # 把警告注入到 Claude 上下文,让 Claude 在下一轮主动修复
        # (decision=block 在 PostToolUse 阶段语义不准:写入已完成,无法"阻止")
        reason = (
            f"SECURITY: Possible secret(s) detected in {file_path}:\n"
            + "\n".join(f"  - {h}" for h in hits)
            + "\nImmediate action: remove the value, move to .env (gitignored), "
            "or use environment variables. Then re-edit the file."
        )

        output = {
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": reason,
            }
        }
        print(json.dumps(output, ensure_ascii=False))

        # 同时输出到 stderr 让用户看到
        print(
            f"[check-secrets] {len(hits)} secret pattern(s) hit in {file_path}",
            file=sys.stderr,
        )
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
from __future__ import annotations
"""
Claude 说"完成"前轻量验证项目状态。
事件: Stop
策略: 仅在 git 仓库内运行；命中失败用 JSON decision=block 阻止结束
注意: 检查 stop_hook_active 避免无限循环
"""

import json
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


# 可通过环境变量跳过指定 checker（逗号分隔），如 VERIFY_ON_STOP_SKIP=rust,typescript
_SKIP_CHECKERS = set(
    os.environ.get("VERIFY_ON_STOP_SKIP", "").lower().split(",")
) - {""}


def has_command(name: str) -> bool:
    return shutil.which(name) is not None


def run_quiet(cmd: list[str], timeout: int = 60) -> int | None:
    """运行命令。
    Returns:
        exit code (0-255) — 命令正常结束
        None — 超时 / 命令不存在 / 系统错误
    """
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        return result.returncode
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None


def is_git_repo() -> bool:
    return run_quiet(["git", "rev-parse", "--git-dir"], timeout=5) == 0


# TypeScript 包管理器候选链（lockfile → runner 命令）
_TS_RUNNERS: list[tuple[str, list[str]]] = [
    ("pnpm-lock.yaml", ["pnpm", "exec", "tsc", "--noEmit"]),
    ("bun.lockb", ["bun", "x", "tsc", "--noEmit"]),
    ("bun.lock", ["bun", "x", "tsc", "--noEmit"]),
    ("yarn.lock", ["yarn", "run", "tsc", "--noEmit"]),
    ("package-lock.json", ["npx", "--no-install", "tsc", "--noEmit"]),
]


def _pick_ts_runner() -> list[str] | None:
    """根据 lockfile 选择 TypeScript runner"""
    for lockfile, cmd in _TS_RUNNERS:
        if Path(lockfile).exists() and has_command(cmd[0]):
            return cmd
    # 没找到 lockfile 但有 npx — 仍可跑
    if has_command("npx"):
        return ["npx", "--no-install", "tsc", "--noEmit"]
    return None


@dataclass
class Checker:
    name: str
    label: str
    markers: list[str]          # 任一存在即触发
    cmd: list[str] | None = None
    timeout: int = 60
    pick_cmd: Callable[[], list[str] | None] | None = None


# 按超时升序排列 — 短任务先跑
CHECKERS: list[Checker] = [
    Checker("python", "Python: ruff check 未通过",
            markers=["pyproject.toml", "setup.py"],
            cmd=["ruff", "check", ".", "--quiet"], timeout=30),
    Checker("typescript", "TypeScript: tsc --noEmit 未通过",
            markers=["tsconfig.json"],
            pick_cmd=_pick_ts_runner, timeout=90),
    Checker("rust", "Rust: cargo check 未通过",
            markers=["Cargo.toml"],
            cmd=["cargo", "check", "--quiet"], timeout=90),
]


def run_checker(c: Checker) -> str | None:
    """运行单个 checker，失败返回 label，通过返回 None"""
    if c.name in _SKIP_CHECKERS:
        return None
    if not any(Path(m).exists() for m in c.markers):
        return None
    cmd = c.pick_cmd() if c.pick_cmd else c.cmd
    if not cmd or not has_command(cmd[0]):
        return None
    if run_quiet(cmd, timeout=c.timeout) != 0:
        return c.label
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

        # 并行执行 checker — 三个 checker 串行最坏 30+90+90=210s 阻塞 Stop 事件
        # 改为并发后最坏 max(30,90,90)=90s；subprocess 阻塞期间释放 GIL
        # 保持 CHECKERS 顺序输出,便于用户/日志稳定解析
        with ThreadPoolExecutor(max_workers=len(CHECKERS)) as pool:
            future_to_checker = {pool.submit(run_checker, c): c for c in CHECKERS}
            for fut, checker in future_to_checker.items():
                try:
                    result = fut.result()
                    if result:
                        issues.append(result)
                except Exception:
                    pass  # checker 崩溃不影响其他 checker

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
        print(json.dumps(output, ensure_ascii=False))

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

function ConvertFrom-JsonToHashtable {
    param([string]$Json)
    $parsed = $Json | ConvertFrom-Json
    if ($null -eq $parsed) { return $null }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return $Json | ConvertFrom-Json -AsHashtable
    }
    # PS 5.1 兼容：手动转换 PSCustomObject → Hashtable
    $ht = [System.Collections.Hashtable]::new()
    foreach ($prop in $parsed.PSObject.Properties) {
        $ht[$prop.Name] = $prop.Value
    }
    return $ht
}

# ============================================================
#  安装模式选择
# ============================================================
function Read-InstallMode {
    Write-Host ''
    Write-Host '  请选择安装模式：' -ForegroundColor White
    Write-Host ''
    Write-Host '    [0] 退出安装' -ForegroundColor Red
    Write-Host ''
    Write-Host '    [1] 仅安装 Claude Code（默认）' -ForegroundColor Green
    Write-Host '        安装 Claude Code 本体 + PATH 配置' -ForegroundColor Gray
    Write-Host '        不下载任何 hooks 或 status_line' -ForegroundColor Gray
    Write-Host ''
    Write-Host '    [2] 完整安装（软件 + hooks）' -ForegroundColor Yellow
    Write-Host '        安装 Claude Code + 从第三方仓库下载 6 个 hooks 和 status_line' -ForegroundColor Gray
    Write-Host '        注意：hooks 来自 disler/claude-code-hooks-mastery，会自动校验 SHA256' -ForegroundColor Gray
    Write-Host ''

    while ($true) {
        Write-Host '  请输入选择 [0/1/2]（默认 1）：' -ForegroundColor Cyan -NoNewline
        $choice = (Read-Host).Trim()
        if ([string]::IsNullOrEmpty($choice)) { $choice = '1' }
        switch ($choice) {
            '0' { Write-Host '  已退出安装' -ForegroundColor Yellow; exit 0 }
            '1' { return 'Minimal' }
            '2' { return 'Full' }
            default { Write-Host '  无效输入，请输入 0、1 或 2' -ForegroundColor Red }
        }
    }
}

# ============================================================
#  现有配置检测（Full 模式写入前报告 + 自动备份）
# ============================================================
function Test-ExistingConfig {
    $hasSettings   = Test-Path (Join-Path $CLAUDE_HOME 'settings.json')
    $hasClaudeJson = Test-Path $CONFIG_PATH
    $hooks  = @(Get-ChildItem $HOOK_DIR -Filter *.py -ErrorAction SilentlyContinue)
    $sls    = @(Get-ChildItem $SL_DIR -Filter *.py -ErrorAction SilentlyContinue)
    $hasHooks       = $hooks.Count -gt 0
    $hasStatusLines = $sls.Count -gt 0

    $found = $false
    Write-Step '检测现有 Claude Code 配置'

    if ($hasSettings) {
        $sz = (Get-Item (Join-Path $CLAUDE_HOME 'settings.json')).Length
        Write-Info "  [FOUND] ~/.claude/settings.json ($sz bytes)"
        $found = $true
    }
    if ($hasClaudeJson) {
        Write-Info '  [FOUND] ~/.claude.json'
        $found = $true
    }
    if ($hasHooks) {
        Write-Info "  [FOUND] ~/.claude/hooks/ ($($hooks.Count) 个 .py)"
        $found = $true
    }
    if ($hasStatusLines) {
        Write-Info "  [FOUND] ~/.claude/status_lines/ ($($sls.Count) 个 .py)"
        $found = $true
    }
    if (-not $found) {
        Write-Info '  [CLEAN] 首次部署，无冲突'
    }
    return $found
}

function Backup-SettingsJson {
    $SETTINGS_PATH = Join-Path $CLAUDE_HOME 'settings.json'
    if (-not (Test-Path $SETTINGS_PATH)) { return $null }

    $BACKUP_DIR = Join-Path $CLAUDE_HOME 'backups'
    New-Item -ItemType Directory -Force -Path $BACKUP_DIR | Out-Null

    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $BACKUP_DIR "settings.json.$stamp.bak"
    Copy-Item $SETTINGS_PATH $backup -Force
    Write-Ok "  备份到 $backup"

    # 保留最近 10 个备份，清理更早的
    $oldBackups = Get-ChildItem $BACKUP_DIR -Filter 'settings.json.*.bak' |
                  Sort-Object Name -Descending |
                  Select-Object -Skip 10
    foreach ($ob in $oldBackups) {
        Remove-Item $ob.FullName -Force -ErrorAction SilentlyContinue
    }

    return $backup
}

# ============================================================
#  阶段 1：前置环境检测（收集结果 → 打印报告 → 返回是否可继续）
# ============================================================
function Test-Prerequisites {
    Write-Step '环境检测报告'
    Write-Host ''

    $results = [System.Collections.ArrayList]::new()
    $blockers = 0

    # 1. PowerShell 版本
    $psVer = $PSVersionTable.PSVersion
    if ($psVer.Major -lt 5) {
        [void]$results.Add(@{ Name = 'PowerShell'; Value = "$psVer"; Status = 'FAIL'; Note = '需要 5.1+' })
        $blockers++
    } elseif ($psVer.Major -ge 7) {
        [void]$results.Add(@{ Name = 'PowerShell'; Value = "$psVer"; Status = 'OK'; Note = '推荐版本' })
    } else {
        [void]$results.Add(@{ Name = 'PowerShell'; Value = "$psVer"; Status = 'WARN'; Note = '建议升级到 7.x' })
    }

    # 2. 系统架构
    if ([Environment]::Is64BitOperatingSystem) {
        [void]$results.Add(@{ Name = '系统架构'; Value = '64 位'; Status = 'OK'; Note = '' })
    } else {
        [void]$results.Add(@{ Name = '系统架构'; Value = '32 位'; Status = 'FAIL'; Note = '不支持 32 位' })
        $blockers++
    }

    # 3. Git
    if (Has-Command 'git') {
        $gitVer = (& git --version) -replace 'git version ', ''
        [void]$results.Add(@{ Name = 'Git'; Value = $gitVer; Status = 'OK'; Note = '' })
    } else {
        [void]$results.Add(@{ Name = 'Git'; Value = '未安装'; Status = 'WARN'; Note = 'hooks 部分功能需要' })
    }

    # 4. UV（缺失时自动安装）
    if (Has-Command 'uv') {
        $uvVer = (& uv --version) -replace 'uv ', ''
        [void]$results.Add(@{ Name = 'UV'; Value = $uvVer; Status = 'OK'; Note = '' })
    } else {
        [void]$results.Add(@{ Name = 'UV'; Value = '安装中...'; Status = 'AUTO'; Note = '自动安装' })
        try {
            # 用同步子进程执行 UV 安装脚本，避免其内部 exit 终止父进程
            # 用 -Command 而非 -File，因为安装脚本是管道表达式
            $uvProc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
                'irm https://astral.sh/uv/install.ps1 | iex'
            ) -NoNewWindow -Wait -PassThru -ErrorAction Stop
            # 刷新 PATH 以识别新安装的 uv
            $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
            if (Has-Command 'uv') {
                $uvVer = (& uv --version) -replace 'uv ', ''
                $results[$results.Count - 1] = @{ Name = 'UV'; Value = $uvVer; Status = 'OK'; Note = '自动安装完成' }
            } else {
                $results[$results.Count - 1] = @{ Name = 'UV'; Value = '安装失败'; Status = 'FAIL'; Note = "手动: irm https://astral.sh/uv/install.ps1 | iex (exit $($uvProc.ExitCode))" }
                $blockers++
            }
        } catch {
            $results[$results.Count - 1] = @{ Name = 'UV'; Value = '安装失败'; Status = 'FAIL'; Note = "手动安装 ($_)" }
            $blockers++
        }
    }

    # 5. Node.js（可选）
    if (Has-Command 'node') {
        $nodeVer = (& node --version)
        [void]$results.Add(@{ Name = 'Node.js'; Value = $nodeVer; Status = 'OK'; Note = 'npm 兜底' })
    } else {
        [void]$results.Add(@{ Name = 'Node.js'; Value = '未安装'; Status = 'SKIP'; Note = '仅 npm 兜底需要' })
    }

    # 6. Claude Code（即将安装）
    if (Has-Command 'claude') {
        $claudeVer = (& claude --version 2>$null) -join ''
        [void]$results.Add(@{ Name = 'Claude Code'; Value = $claudeVer; Status = 'OK'; Note = '已安装' })
    } else {
        [void]$results.Add(@{ Name = 'Claude Code'; Value = '未安装'; Status = 'SKIP'; Note = '即将安装' })
    }

    # ── 打印报告 ──
    Write-Host '  ┌────────────────────────────────────────────────────────┐' -ForegroundColor Cyan
    foreach ($r in $results) {
        $icon = switch ($r.Status) {
            'OK'   { '✓' }
            'WARN' { '○' }
            'FAIL' { '✗' }
            'AUTO' { '↓' }
            'SKIP' { '○' }
        }
        $color = switch ($r.Status) {
            'OK'   { 'Green' }
            'WARN' { 'Yellow' }
            'FAIL' { 'Red' }
            'AUTO' { 'Cyan' }
            'SKIP' { 'Gray' }
        }
        $nameCol = $r.Name.PadRight(14)
        $valCol = $r.Value.PadRight(18)
        $notePart = if ($r.Note) { " ($($r.Note))" } else { '' }
        Write-Host "  │  $icon  $nameCol $valCol$notePart" -ForegroundColor $color
    }
    Write-Host '  └────────────────────────────────────────────────────────┘' -ForegroundColor Cyan

    # ── 汇总 ──
    $okCount   = @($results | Where-Object { $_.Status -eq 'OK' }).Count
    $warnCount = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
    $skipCount = @($results | Where-Object { $_.Status -eq 'SKIP' }).Count
    $failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
    Write-Host ''
    $summaryColor = if ($blockers -gt 0) { 'Red' } else { 'Green' }
    Write-Host "  $okCount 通过 / $warnCount 建议 / $skipCount 可选 / $failCount 阻断" -ForegroundColor $summaryColor

    if ($blockers -gt 0) {
        Write-Host ''
        Write-Err '环境不满足要求，请先修复上述阻断项后重试'
        return $false
    }
    return $true
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
        try {
            $utf8NoBomLocal = [System.Text.UTF8Encoding]::new($false)
            $cfg = ConvertFrom-JsonToHashtable ([System.IO.File]::ReadAllText($CONFIG_PATH, $utf8NoBomLocal))
        } catch {}
    }
    if ($null -eq $cfg) { $cfg = @{} }
    $cfg['installMethod'] = 'native'
    $cfg['autoUpdates']   = $false
    if (-not $cfg.ContainsKey('firstStartTime')) {
        $cfg['firstStartTime'] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($CONFIG_PATH, ($cfg | ConvertTo-Json -Depth 10), $utf8NoBom)

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
    Write-Info '方式 3/3：npm 全局（仅作兜底）'

    # npm 不可用时，尝试用 winget 自动安装 Node.js LTS
    if (-not (Has-Command 'npm')) {
        Write-Info 'npm 不可用，尝试自动安装 Node.js LTS...'
        if (Has-Command 'winget') {
            & winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
            if ($LASTEXITCODE -ne 0) { throw "winget 安装 Node.js 失败，退出码 $LASTEXITCODE" }
            # 刷新当前会话 PATH（winget 安装的 Node.js 通常写入 Program Files）
            $nodePaths = @(
                "${env:ProgramFiles}\nodejs",
                "${env:ProgramFiles(x86)}\nodejs"
            )
            foreach ($p in $nodePaths) {
                if ((Test-Path $p) -and $env:Path -notlike "*$p*") {
                    $env:Path = "$p;$env:Path"
                }
            }
            if (-not (Has-Command 'npm')) {
                throw 'Node.js 已安装但 npm 仍不可用，请重启终端后重试'
            }
            Write-Ok 'Node.js LTS 自动安装成功'
        } else {
            throw 'npm 和 winget 均不可用，无法自动安装 Node.js。请手动安装 Node.js LTS 后重试'
        }
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
#  阶段 3.4：预填 ~/.claude.json onboarding 标记（仅 hasCompletedOnboarding）
# ============================================================
function Install-ClaudeJson {
    Write-Step '预填 ~/.claude.json onboarding 标记（跳过全局引导）'

    # 读取现有 .claude.json，合并后回写（避免覆盖 installMethod / autoUpdates / projects 等关键字段）
    $cfg = @{}
    if (Test-Path $CONFIG_PATH) {
        try {
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            $raw = [System.IO.File]::ReadAllText($CONFIG_PATH, $utf8NoBom)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = ConvertFrom-JsonToHashtable $raw
                if ($null -ne $parsed) { $cfg = $parsed }
            }
        } catch {
            Write-Warn2 "  现有 .claude.json 解析失败，将以空对象为基础重新构建：$_"
            $cfg = @{}
        }
    }
    if ($null -eq $cfg) { $cfg = @{} }

    # 仅预填全局 onboarding 标记（刚需、首启向导、零安全风险）
    # hasTrustDialogAccepted / hasCompletedProjectOnboarding 不在脚本处理：
    #   - 前者是工作区信任大门，CVE-2026-33068 后保持默认弹出让用户决策更安全
    #   - 后者需按项目绝对路径写入，反幂等、用户友好度低
    $cfg['hasCompletedOnboarding'] = $true
    Write-Info '    [SET] hasCompletedOnboarding = true（跳过主题选择 / 欢迎向导）'

    # 原子写：先写 .tmp 再 Move-Item，避免崩溃留半截
    $tmp = "$CONFIG_PATH.tmp"
    $json = $cfg | ConvertTo-Json -Depth 10
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -Force $tmp $CONFIG_PATH
        Write-Ok "  $CONFIG_PATH"
    } catch {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        Write-Err "  .claude.json 写入失败：$_"
    }
}

# ============================================================
#  深度合并辅助函数
# ============================================================

# 从 hook 条目中提取 command 字符串（用于去重）
function Get-HookCommand {
    param([hashtable]$HookEntry)
    if ($HookEntry.ContainsKey('command')) { return $HookEntry['command'] }
    return $null
}

# 从 hook matcher 组中提取所有 command（用于去重）
function Get-MatcherCommands {
    param([hashtable]$MatcherEntry)
    $cmds = @()
    if ($MatcherEntry.ContainsKey('hooks')) {
        foreach ($h in $MatcherEntry['hooks']) {
            $c = Get-HookCommand $h
            if ($null -ne $c) { $cmds += $c }
        }
    }
    return $cmds
}

# 合并 hooks：按事件合并，每个事件内用户 hooks 保留 + 我们的 hooks 追加（按 command 去重）
function Merge-Hooks {
    param(
        [hashtable]$Ours,
        [hashtable]$Theirs
    )
    $result = @{}
    # 先复制用户的所有事件
    foreach ($evt in $Theirs.Keys) {
        $result[$evt] = $Theirs[$evt]
    }
    # 遍历我们的 hooks，按事件追加
    foreach ($evt in $Ours.Keys) {
        $ourMatchers = @($Ours[$evt])
        if (-not $result.ContainsKey($evt)) {
            # 用户没有这个事件，直接用我们的
            $result[$evt] = $ourMatchers
            continue
        }
        # 用户已有该事件：收集用户已有的 command 集合
        $userMatcherList = @($result[$evt])
        $existingCmds = @{}
        foreach ($um in $userMatcherList) {
            foreach ($c in (Get-MatcherCommands $um)) {
                $existingCmds[$c] = $true
            }
        }
        # 追加我们的 matcher（按 command 去重）
        foreach ($om in $ourMatchers) {
            $ourCmds = Get-MatcherCommands $om
            $hasNew = $false
            foreach ($oc in $ourCmds) {
                if (-not $existingCmds.ContainsKey($oc)) {
                    $hasNew = $true
                    break
                }
            }
            if ($hasNew) {
                $userMatcherList = @($userMatcherList) + @($om)
                foreach ($oc in $ourCmds) {
                    $existingCmds[$oc] = $true
                }
            }
        }
        $result[$evt] = $userMatcherList
    }
    return $result
}

# 合并 permissions：allow/deny 数组并集去重，defaultMode 用户优先
function Merge-Permissions {
    param(
        [hashtable]$Ours,
        [hashtable]$Theirs
    )
    $result = @{}

    # allow: 并集去重
    $allowSet = [System.Collections.Generic.HashSet[string]]::new()
    if ($Theirs.ContainsKey('allow')) {
        foreach ($a in $Theirs['allow']) { $allowSet.Add($a) | Out-Null }
    }
    if ($Ours.ContainsKey('allow')) {
        foreach ($a in $Ours['allow']) { $allowSet.Add($a) | Out-Null }
    }
    $result['allow'] = @($allowSet)

    # deny: 并集去重
    $denySet = [System.Collections.Generic.HashSet[string]]::new()
    if ($Theirs.ContainsKey('deny')) {
        foreach ($d in $Theirs['deny']) { $denySet.Add($d) | Out-Null }
    }
    if ($Ours.ContainsKey('deny')) {
        foreach ($d in $Ours['deny']) { $denySet.Add($d) | Out-Null }
    }
    $result['deny'] = @($denySet)

    # defaultMode: 用户优先
    if ($Theirs.ContainsKey('defaultMode')) {
        $result['defaultMode'] = $Theirs['defaultMode']
    } elseif ($Ours.ContainsKey('defaultMode')) {
        $result['defaultMode'] = $Ours['defaultMode']
    }

    # skipDangerousModePermissionPrompt: 用户优先
    if ($Theirs.ContainsKey('skipDangerousModePermissionPrompt')) {
        $result['skipDangerousModePermissionPrompt'] = $Theirs['skipDangerousModePermissionPrompt']
    } elseif ($Ours.ContainsKey('skipDangerousModePermissionPrompt')) {
        $result['skipDangerousModePermissionPrompt'] = $Ours['skipDangerousModePermissionPrompt']
    }

    # 保留用户的其他 permissions 字段
    foreach ($key in $Theirs.Keys) {
        if (-not $result.ContainsKey($key)) {
            $result[$key] = $Theirs[$key]
        }
    }

    return $result
}

# ============================================================
#  settings.json 写入策略选择（检测到已有配置时交互）
# ============================================================
function Read-SettingsJsonStrategy {
    $SETTINGS_PATH = Join-Path $CLAUDE_HOME 'settings.json'
    if (-not (Test-Path $SETTINGS_PATH)) {
        return 'fresh'   # 不存在，直接创建
    }

    Write-Host ''
    Write-Host '  ┌─────────────────────────────────────────────────────────┐' -ForegroundColor Yellow
    Write-Host '  │  检测到现有的 ~/.claude/settings.json                    │' -ForegroundColor Yellow
    Write-Host '  │  选择处理策略：                                         │' -ForegroundColor Yellow
    Write-Host '  │                                                         │' -ForegroundColor Yellow
    Write-Host '  │  1. 覆盖  备份后整体替换（最简单，但丢失用户 env/MCP 等）│' -ForegroundColor Yellow
    Write-Host '  │  2. 合并  保留用户 env/permissions，添加 hooks/statusLine│' -ForegroundColor Green
    Write-Host '  │  3. 跳过  仅部署 hooks 文件，不动 settings.json         │' -ForegroundColor Cyan
    Write-Host '  │  4. 取消  保留所有现有配置，退出安装                     │' -ForegroundColor Red
    Write-Host '  └─────────────────────────────────────────────────────────┘' -ForegroundColor Yellow
    Write-Host ''

    $choice = Read-Host '  请选择 [1/2/3/4]（默认 2: 合并）'

    switch ($choice) {
        '1' { return 'overwrite' }
        '2' { return 'merge' }
        '3' { return 'skip' }
        '4' { return 'cancel' }
        default { return 'merge' }
    }
}

# ============================================================
#  阶段 3.5：写入 ~/.claude/settings.json（合并 GeneralConfiguration）
# ============================================================
function Install-SettingsJson {
    param(
        [ValidateSet('fresh', 'overwrite', 'merge', 'skip')]
        [string]$Strategy = 'fresh'
    )

    $SETTINGS_PATH = Join-Path $CLAUDE_HOME 'settings.json'

    # 跳过策略：仅报告，不写入
    if ($Strategy -eq 'skip') {
        Write-Step 'settings.json：已跳过（用户选择）'
        Write-Info '  hooks 文件已部署，但 settings.json 未更新'
        Write-Info '  需手动合并或通过 cc-switch 启用 hooks'
        return
    }

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

    # 根据策略决定写入方式
    $stepLabel = switch ($Strategy) {
        'fresh'     { '生成 ~/.claude/settings.json（启用 hooks）' }
        'overwrite' { '覆盖 ~/.claude/settings.json（备份已完成）' }
        'merge'     { '合并 ~/.claude/settings.json（保留用户配置 + 添加 hooks）' }
    }
    Write-Step $stepLabel

    if ($Strategy -eq 'merge') {
        $existing = @{}
        if (Test-Path $SETTINGS_PATH) {
            try {
                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                $raw = [System.IO.File]::ReadAllText($SETTINGS_PATH, $utf8NoBom)
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $parsed = ConvertFrom-JsonToHashtable $raw
                    if ($null -ne $parsed) { $existing = $parsed }
                }
            } catch {
                Write-Warn2 "  现有 settings.json 解析失败，将整体覆盖：$_"
            }
        }

        # ── 深度合并各字段 ──

        # 1. enabledPlugins: 双方合并，用户的开关优先
        if ($settings.Keys -contains 'enabledPlugins' -and $existing.ContainsKey('enabledPlugins')) {
            foreach ($pk in $settings['enabledPlugins'].Keys) {
                if (-not $existing['enabledPlugins'].ContainsKey($pk)) {
                    $existing['enabledPlugins'][$pk] = $settings['enabledPlugins'][$pk]
                }
            }
            $settings['enabledPlugins'] = $existing['enabledPlugins']
        }

        # 2. env: 用户优先（保护 API key / base URL），缺失 key 用我们补
        if ($existing.ContainsKey('env') -and $settings.Keys -contains 'env') {
            foreach ($ek in $settings['env'].Keys) {
                if (-not $existing['env'].ContainsKey($ek)) {
                    $existing['env'][$ek] = $settings['env'][$ek]
                }
            }
            $settings['env'] = $existing['env']
        }

        # 3. hooks: 按事件合并，每个事件内的 hooks 列表追加我们的（按 command 去重）
        if ($settings.Keys -contains 'hooks' -and $existing.ContainsKey('hooks')) {
            $settings['hooks'] = Merge-Hooks -Ours $settings['hooks'] -Theirs $existing['hooks']
        }

        # 4. permissions: allow/deny 数组并集去重，defaultMode 用户优先
        if ($settings.Keys -contains 'permissions' -and $existing.ContainsKey('permissions')) {
            $settings['permissions'] = Merge-Permissions -Ours $settings['permissions'] -Theirs $existing['permissions']
        }

        # 5. statusLine: 项目优先（统一 status_line_v6）
        # （已在 $settings 中，无需额外处理）

        # 6. autoConnectIde: 项目优先
        # （已在 $settings 中，无需额外处理）

        # 7. 保留用户的其他字段（如 ccmManaged, ccmProvider, $schema 等）
        foreach ($key in $existing.Keys) {
            if ($settings.Keys -notcontains $key) {
                $settings[$key] = $existing[$key]
            }
        }
        Write-Info '  深度合并：env 用户优先 / hooks 按事件追加去重 / permissions 并集 / 其他字段保留'
    }

    try {
        # 确保目录存在
        $settingsDir = Split-Path $SETTINGS_PATH -Parent
        if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null }

        $json = $settings | ConvertTo-Json -Depth 10
        # 原子写：先 .tmp 再 Move-Item
        $tmp = "$SETTINGS_PATH.tmp"
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -Force $tmp $SETTINGS_PATH
        Write-Ok "  $SETTINGS_PATH"
        $label = if ($Strategy -eq 'merge') { '合并' } else { '写入' }
        Write-Info "  已${label}：enabledPlugins + env + statusLine + 7 个 hooks 事件 + permissions"
    } catch {
        if (Test-Path "$SETTINGS_PATH.tmp") { Remove-Item "$SETTINGS_PATH.tmp" -Force -ErrorAction SilentlyContinue }
        Write-Err "  settings.json 写入失败：$_"
    }
}

# ============================================================
#  阶段 3：hooks 与 status_line 部署
# ============================================================
function Invoke-DownloadFile {
    param(
        [string]$Url,
        [string]$Dest,
        [int]$MaxRetry = 3
    )
    for ($i = 1; $i -le $MaxRetry; $i++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Dest -TimeoutSec 30 -ErrorAction Stop
            if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 0) {
                return $true
            }
            throw '下载文件为空'
        } catch {
            if ($i -eq $MaxRetry) {
                throw "下载失败（重试 $MaxRetry 次）：$Url — $_"
            }
            Write-Warn2 "    重试 $i/$MaxRetry：$_"
            Start-Sleep -Seconds 2
        }
    }
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
            $url = "$REPO_BASE/hooks/$f"
            Invoke-DownloadFile -Url $url -Dest $dest
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
            $slUrl = "$REPO_BASE/status_lines/$STATUS_LINE"
            Invoke-DownloadFile -Url $slUrl -Dest $slDest
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
        $onboardingDone = $false
        if (Test-Path $CONFIG_PATH) {
            try {
                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                $cfgRaw = [System.IO.File]::ReadAllText($CONFIG_PATH, $utf8NoBom)
                $cfgObj = $cfgRaw | ConvertFrom-Json
                $onboardingDone = [bool]$cfgObj.hasCompletedOnboarding
            } catch {}
        }

        Write-Info ''
        Write-Host '  已部署文件：' -ForegroundColor White
        Write-Info "    hooks 目录：$hookCount 个 .py（含 4 个用户自写）"
        Write-Info "    status_line 目录：$slCount 个 .py"
        Write-Info "    settings.json：$(if ($settingsExists) { '已生成 ✓' } else { '未生成（跳过）' })"
        if ($settingsExists -and $settingsStrategy -eq 'merge') {
            Write-Info '      策略：合并（保留用户 env + 项目 hooks）'
        } elseif ($settingsExists -and $settingsStrategy -eq 'overwrite') {
            Write-Info '      策略：覆盖（备份在 ~/.claude/backups/）'
        }
        Write-Info "    ~/.claude.json: hasCompletedOnboarding = $(if ($onboardingDone) { 'true ✓' } else { 'false ✗' })"
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
    Write-Host '                                          ████  ███   ████  ███    ██  ██  ██' -ForegroundColor Cyan
    Write-Host '                                          █     █  █  █     █  █  █  █ ██ █  █' -ForegroundColor Cyan
    Write-Host '                                          ███   ███   █ ██  ███   ███  ██ ███' -ForegroundColor Cyan
    Write-Host '                                          █     █ █   █  █  █     █  █ ██ █  █' -ForegroundColor Cyan
    Write-Host '                                          ████  █  █  ████  ████  █  █ ██ █  █' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '                                          Claude Code Bootstrap  v1.6.0' -ForegroundColor White
    Write-Host '                                          by ' -ForegroundColor DarkCyan -NoNewline
    Write-Host '宝藏二哥AIA' -ForegroundColor Yellow

    # 先检测环境，再选择安装模式
    try {
        $prereqOk = Test-Prerequisites
    } catch {
        Write-Err "环境检测失败: $_"
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        $prereqOk = $false
    }
    if (-not $prereqOk) {
        Write-Host ''
        Write-Host '  按回车键退出...' -ForegroundColor Gray
        [void][Console]::ReadLine()
        exit 1
    }

    # 确定安装模式
    if (-not $InstallMode) {
        $InstallMode = Read-InstallMode
    }
    Write-Host ''
    Write-Host "  安装模式：$InstallMode" -ForegroundColor $(if ($InstallMode -eq 'Full') { 'Yellow' } else { 'Green' })

    # 防御性初始化
    $settingsStrategy = 'fresh'

    # 检测现有配置（报告给用户，返回是否有冲突）
    $hasExisting = Test-ExistingConfig

    if (-not $SkipClaudeInstall) { Install-ClaudeCode }
    else { Write-Step 'Claude Code 安装：已跳过（-SkipClaudeInstall）' }

    if ($InstallMode -eq 'Full') {
        # 写入 settings.json 前自动备份
        Backup-SettingsJson

        # 检测策略（已有配置时交互选择，全新环境直接创建）
        $settingsStrategy = Read-SettingsJsonStrategy
        if ($settingsStrategy -eq 'cancel') {
            Write-Host ''
            Write-Host '  [CANCEL] 用户取消安装，所有现有配置保持不变' -ForegroundColor Yellow
            Write-Host ''
            exit 0
        }

        Install-UserHooks
        Install-Hooks
        Install-ClaudeJson
        Install-SettingsJson -Strategy $settingsStrategy
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
    Write-Host ''
    Write-Host '  Press Enter to exit...' -ForegroundColor Gray
    [void][Console]::ReadLine()
    exit 1
}
