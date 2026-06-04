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
    "tests",
    "test",
    "__tests__",
    "spec",
    "specs",
    "fixtures",
    "mocks",
    "examples",
    "samples",
    "testdata",
    "docs",
    "documentation",
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
