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
