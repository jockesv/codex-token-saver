import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest


CODEX = Path(__file__).resolve().parents[1] / ".codex"
SPEC = importlib.util.spec_from_file_location("apply_models", CODEX / "apply_models.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
ROLES = ("bulk_editor", "code_worker", "log_analyst", "researcher", "reviewer", "test_runner")


def selection(model_prefix="6.10"):
    return {
        "main": {"model": f"gpt-{model_prefix}-sol", "reasoning_effort": "medium"},
        "default_subagent": {"model": f"gpt-{model_prefix}-terra", "reasoning_effort": "medium"},
        "roles": {
            role: {
                "model": f"gpt-{model_prefix}-sol" if role == "reviewer" else f"gpt-{model_prefix}-terra",
                "reasoning_effort": "high" if role == "reviewer" else "low" if role in {"bulk_editor", "test_runner"} else "medium",
            }
            for role in ROLES
        },
        "catalog_source": "file",
    }


class ModelRendererTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(CODEX / "templates", self.root / "templates")

    def test_render_resolves_main_fallback_and_all_template_roles(self):
        original = {path.relative_to(self.root / "templates"): path.read_text(encoding="utf-8") for path in (self.root / "templates").rglob("*.toml")}
        outputs = MODULE.render(self.root, selection())
        self.assertEqual({path.stem for path in outputs if path.parent.name == "agents"}, set(ROLES))
        config = tomllib.loads(outputs[self.root / "config.toml"])
        self.assertEqual(config["model"], "gpt-6.10-sol")
        self.assertEqual(config["model_reasoning_effort"], "medium")
        self.assertEqual(config["agents"]["default_subagent_model"], "gpt-6.10-terra")
        self.assertEqual(config["agents"]["default_subagent_reasoning_effort"], "medium")
        for role in ROLES:
            path = self.root / "agents" / f"{role}.toml"
            rendered = tomllib.loads(outputs[path])
            self.assertEqual(rendered["model"], selection()["roles"][role]["model"])
            self.assertEqual(rendered["model_reasoning_effort"], selection()["roles"][role]["reasoning_effort"])
            self.assertTrue(outputs[path].endswith(original[Path("agents") / f"{role}.toml"]))
            source = tomllib.loads(original[Path("agents") / f"{role}.toml"])
            self.assertEqual(rendered["sandbox_mode"], source["sandbox_mode"])
            self.assertEqual(rendered["developer_instructions"], source["developer_instructions"])

    def test_model_settings_in_templates_are_rejected(self):
        path = self.root / "templates" / "agents" / "researcher.toml"
        path.write_text('model = "gpt-9-sol"\n' + path.read_text(encoding="utf-8"), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "keep model settings"):
            MODULE.render(self.root, selection())

    def test_missing_role_and_invalid_choice_fail_before_any_write(self):
        invalid = selection()
        del invalid["roles"]["reviewer"]
        with self.assertRaisesRegex(ValueError, "exactly match"):
            MODULE.render(self.root, invalid)
        invalid = selection()
        invalid["main"]["model"] = "not-a-model"
        with self.assertRaisesRegex(ValueError, "invalid resolved model ID"):
            MODULE.render(self.root, invalid)
        self.assertFalse((self.root / "config.toml").exists())

    def test_cli_check_is_deterministic_and_reports_stale_selection(self):
        selection_path = self.root / "selection.json"
        selection_path.write_text(json.dumps(selection()), encoding="utf-8")
        command = [sys.executable, str(CODEX / "apply_models.py"), "--selection", str(selection_path), "--root", str(self.root)]
        check = subprocess.run(command + ["--check"], capture_output=True, text=True)
        self.assertEqual(check.returncode, 1, check.stderr)
        generated = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        stable = subprocess.run(command + ["--check"], capture_output=True, text=True)
        self.assertEqual(stable.returncode, 0, stable.stderr)
        changed = selection()
        changed["main"]["model"] = "gpt-6.2-sol"
        selection_path.write_text(json.dumps(changed), encoding="utf-8")
        stale = subprocess.run(command + ["--check"], capture_output=True, text=True)
        self.assertEqual(stale.returncode, 1, stale.stderr)


if __name__ == "__main__":
    unittest.main()
