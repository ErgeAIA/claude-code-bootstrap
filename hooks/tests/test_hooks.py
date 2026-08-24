"""hooks 最小回归测试（纯逻辑部分）。

运行方式（项目根目录）：
    uv run --with pytest pytest hooks/tests/
"""

import io
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import auto_format
import block_dangerous
import check_secrets
import verify_on_stop


def capture_main(monkeypatch, capsys, module, payload: dict) -> tuple[str, str]:
    """调用 module.main() 并捕获 (退出码, stdout)"""
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    code = 0
    try:
        module.main()
    except SystemExit as e:
        code = e.code or 0
    out = capsys.readouterr().out
    return str(code), out


class TestBlockDangerous:
    def test_rm_rf_blocked(self, monkeypatch, capsys):
        code, out = capture_main(monkeypatch, capsys, block_dangerous,
                                 {"tool_name": "Bash", "tool_input": {"command": "rm -rf /tmp/foo"}})
        assert code == "2"
        assert json.loads(out)["decision"] == "block"

    def test_safe_command_passes(self, monkeypatch, capsys):
        code, out = capture_main(monkeypatch, capsys, block_dangerous,
                                 {"tool_name": "Bash", "tool_input": {"command": "ls -la"}})
        assert code == "0"
        assert out == ""

    def test_non_bash_ignored(self, monkeypatch, capsys):
        code, out = capture_main(monkeypatch, capsys, block_dangerous,
                                 {"tool_name": "Read", "tool_input": {"file_path": "/tmp/foo"}})
        assert code == "0"
        assert out == ""


class TestCheckSecrets:
    def test_false_positive_paths(self):
        assert check_secrets.is_false_positive("proj/tests/test_x.py")
        assert check_secrets.is_false_positive("proj/.env.sample")
        assert not check_secrets.is_false_positive("proj/src/main.py")

    def test_extract_content_write(self):
        ti = {"content": "hello", "new_string": "ignored"}
        assert check_secrets.extract_content(ti) == "hello"

    def test_extract_content_multi_edit(self):
        ti = {"edits": [{"new_string": "a"}, {"new_string": "b"}]}
        assert check_secrets.extract_content(ti) == "a\nb"

    def test_main_hits_anthropic_key(self, monkeypatch, capsys):
        code, out = capture_main(monkeypatch, capsys, check_secrets, {
            "tool_input": {"file_path": "proj/src/key.py",
                           "content": "sk-ant-123456789012345678901234567890"},
        })
        assert code == "0"  # PostToolUse 不阻断
        data = json.loads(out)
        assert "hookSpecificOutput" in data
        assert "Anthropic" in data["hookSpecificOutput"]["additionalContext"]


class TestAutoFormat:
    def test_formatters_cover_common_exts(self):
        exts = {e for exts, _ in auto_format.FORMATTERS for e in exts}
        assert {".py", ".rs", ".ts", ".json", ".md"} <= exts

    def test_unknown_ext_returns_none(self, monkeypatch, tmp_path):
        monkeypatch.setattr(auto_format, "has_command", lambda n: False)
        f = tmp_path / "x.unknownext"
        f.write_text("a")
        assert auto_format.format_by_extension(f) is None

    def test_py_uses_ruff_when_available(self, monkeypatch, tmp_path):
        monkeypatch.setattr(auto_format, "has_command", lambda n: n == "ruff")
        monkeypatch.setattr(auto_format, "run_silent", lambda cmd, timeout=30: True)
        f = tmp_path / "x.py"
        f.write_text("a=1")
        assert auto_format.format_by_extension(f) == "ruff"


class TestVerifyOnStop:
    def test_skip_checker_via_env(self, monkeypatch, tmp_path):
        monkeypatch.chdir(tmp_path)
        (tmp_path / "pyproject.toml").write_text("")
        monkeypatch.setattr(verify_on_stop, "_SKIP_CHECKERS", {"python"})
        c = verify_on_stop.Checker("python", "x", markers=["pyproject.toml"],
                                   cmd=["ruff", "check", "."])
        assert verify_on_stop.run_checker(c) is None

    def test_no_marker_skipped(self, monkeypatch, tmp_path):
        monkeypatch.chdir(tmp_path)
        c = verify_on_stop.Checker("python", "x", markers=["pyproject.toml"],
                                   cmd=["ruff", "check", "."])
        assert verify_on_stop.run_checker(c) is None

    def test_pick_ts_runner_pnpm(self, monkeypatch, tmp_path):
        monkeypatch.chdir(tmp_path)
        (tmp_path / "pnpm-lock.yaml").write_text("")
        monkeypatch.setattr(verify_on_stop, "has_command", lambda n: n == "pnpm")
        assert verify_on_stop._pick_ts_runner() == ["pnpm", "exec", "tsc", "--noEmit"]

    def test_pick_ts_runner_fallback_npx(self, monkeypatch, tmp_path):
        monkeypatch.chdir(tmp_path)
        monkeypatch.setattr(verify_on_stop, "has_command", lambda n: n == "npx")
        assert verify_on_stop._pick_ts_runner() == ["npx", "--no-install", "tsc", "--noEmit"]
