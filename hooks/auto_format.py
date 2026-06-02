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

