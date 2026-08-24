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


def format_by_extension(path: Path) -> str | None:
    """根据扩展名选择 formatter。

    Returns:
        formatter 名称（如 "rustfmt"），未匹配或未执行返回 None
    """
    ext = path.suffix.lower()
    for exts, candidates in FORMATTERS:
        if ext not in exts:
            continue
        for tmpl in candidates:
            cmd = [arg.replace("{path}", str(path)) for arg in tmpl]
            if has_command(cmd[0]):
                run_silent(cmd)
                return cmd[0]
        return None
    return None


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

        formatter = format_by_extension(path)

        # PostToolUse 阶段文件已被 formatter 改写，Claude 内存中的内容与磁盘失配
        # 会导致后续 Edit/MultiEdit 基于旧内容失败；显式告知让 Claude 重新读取
        if formatter:
            output = {
                "hookSpecificOutput": {
                    "hookEventName": "PostToolUse",
                    "additionalContext": (
                        f"Auto-formatted {file_path} with {formatter}. "
                        "The file content on disk changed; re-read it before further edits."
                    ),
                }
            }
            print(json.dumps(output, ensure_ascii=False))

        sys.exit(0)
    except json.JSONDecodeError:
        sys.exit(0)
    except Exception:
        sys.exit(0)


if __name__ == "__main__":
    main()
