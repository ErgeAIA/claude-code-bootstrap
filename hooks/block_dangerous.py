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

