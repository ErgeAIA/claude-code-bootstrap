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
