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
