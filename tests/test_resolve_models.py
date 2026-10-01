import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RESOLVER = ROOT / "tools" / "Resolve-CodexModels.ps1"
CODEX = ROOT / ".codex"


def catalog_items(include_terra=True):
    items = [
        {"slug": "gpt-6.2-sol", "visibility": "list", "supportedReasoningEfforts": ["medium", "high"]},
        {"slug": "gpt-6.10-sol", "visibility": "list", "supportedReasoningEfforts": ["medium", "high"]},
        {"id": "gpt-99-sol", "visibility": "private", "supportedReasoningEfforts": ["medium", "high"]},
        {"model": "gpt-7-sol-preview", "visibility": "list", "supportedReasoningEfforts": ["medium", "high"]},
        {"model": "prefix-gpt-9-sol-suffix", "visibility": "list", "supportedReasoningEfforts": ["medium", "high"]},
    ]
    if include_terra:
        items.append({"id": "gpt-6.1-terra", "visibility": "list", "supportedReasoningEfforts": ["low", "medium", "high"]})
    return items


class ResolverIntegrationTests(unittest.TestCase):
    def fixture(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / ".codex").mkdir()
        shutil.copy(CODEX / "model-policy.json", root / ".codex/model-policy.json")
        shutil.copy(CODEX / "apply_models.py", root / ".codex/apply_models.py")
        shutil.copytree(CODEX / "templates", root / ".codex/templates")
        return root

    def run_resolver(self, root, catalog, *switches):
        catalog_path = root / "catalog.json"
        catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
        return subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(RESOLVER), "-RepoRoot", str(root), "-CatalogPath", str(catalog_path), *switches],
            capture_output=True, text=True,
        )

    def fake_codex(self, *, account_type="chatgpt", rpc_error=False):
        # The resolver starts this script with app-server arguments and speaks JSON-RPC over stdio.
        script = f'''$ErrorActionPreference = 'Stop'
while ($line = [Console]::In.ReadLine()) {{
  $request = $line | ConvertFrom-Json
  $method = [string]$request.method
  $id = $request.id
  if ($method -eq 'initialize') {{ $response = @{{ jsonrpc = '2.0'; id = $id; result = @{{}} }} }}
  elseif ($method -eq 'initialized') {{ continue }}
  elseif ($method -eq 'account/read') {{ $response = @{{ jsonrpc = '2.0'; id = $id; result = @{{ account = @{{ type = '{account_type}' }} }} }} }}
  elseif ($method -eq 'model/list') {{
    $cursor = $request.params.cursor
    if ([string]::IsNullOrWhiteSpace([string]$cursor)) {{
      $data = @(@{{ model = 'gpt-6.10-sol'; id = 'wrong-sol-id'; visibility = 'list'; supportedReasoningEfforts = @('medium','high') }})
      $response = @{{ jsonrpc = '2.0'; id = $id; result = @{{ data = $data; nextCursor = 'page-2' }} }}
    }} else {{
      $data = @(@{{ id = 'gpt-6.1-terra'; visibility = 'list'; supportedReasoningEfforts = @('low','medium','high') }})
      $response = @{{ jsonrpc = '2.0'; id = $id; result = @{{ data = $data; nextCursor = $null }} }}
    }}
  }} else {{ $response = @{{ jsonrpc = '2.0'; id = $id; error = @{{ code = -32601; message = 'unknown method' }} }} }}
  $response | ConvertTo-Json -Depth 12 -Compress
  [Console]::Out.Flush()
}}
'''
        if rpc_error:
            script = script.replace(
                f"$response = @{{{{ jsonrpc = '2.0'; id = $id; result = @{{{{ account = @{{{{ type = '{account_type}' }}}} }}}} }}}}",
                "$response = @{{ jsonrpc = '2.0'; id = $id; error = @{{ code = -32000; message = 'fixture failure' }} }}",
            )
        return script

    def run_live_fixture(self, root, script_text):
        fake = root / "fake-codex.ps1"
        fake.write_text(script_text, encoding="utf-8")
        env = dict(__import__("os").environ)
        env.pop("ACCESS_TOKEN", None)
        return subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(RESOLVER), "-RepoRoot", str(root), "-CodexPath", str(fake), "-WhatIf"],
            capture_output=True, text=True, env=env,
        )

    def test_whatif_supports_array_models_and_data_shapes_without_mutation(self):
        for payload in (catalog_items(), {"models": catalog_items()}, {"data": catalog_items()}):
            with self.subTest(shape="array" if isinstance(payload, list) else next(iter(payload))):
                root = self.fixture()
                sentinel = "sentinel\n"
                (root / ".codex/config.toml").write_text(sentinel, encoding="utf-8")
                before = {path: path.read_bytes() for path in (root / ".codex/config.toml",)}
                result = self.run_resolver(root, payload, "-WhatIf")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Catalog source:          file", result.stdout)
                self.assertIn("gpt-6.10-sol", result.stdout)
                self.assertIn("gpt-6.1-terra", result.stdout)
                self.assertEqual(before[root / ".codex/config.toml"], (root / ".codex/config.toml").read_bytes())

    def test_generation_check_is_idempotent_and_uses_effort_filtered_numeric_versions(self):
        root = self.fixture()
        items = catalog_items()
        items.insert(1, {"model": "gpt-6.99-sol", "visibility": "list", "supportedReasoningEfforts": ["high"]})
        first = self.run_resolver(root, items)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("gpt-6.10-sol", first.stdout)
        self.assertIn("reviewer", first.stdout)
        self.assertIn("gpt-6.99-sol (high)", first.stdout)
        self.assertIn("gpt-6.1-terra", first.stdout)
        check = self.run_resolver(root, items, "-Check")
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertEqual((root / ".codex/resolved-models.json").exists(), True)

    def test_missing_effort_metadata_preserves_requested_effort(self):
        root = self.fixture()
        items = catalog_items()
        items[-1].pop("supportedReasoningEfforts")
        result = self.run_resolver(root, items, "-WhatIf")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"test_runner\s+gpt-6\.1-terra \(low\)")

    def test_generic_gpt_family_selects_suffixless_gpt_5_5_and_manifest_lists_catalog(self):
        root = self.fixture()
        payload = [
            {"model": "gpt-5.5", "visibility": "list", "supportedReasoningEfforts": ["low", "medium", "high"]},
            {"model": "gpt-4.0", "visibility": "private", "supportedReasoningEfforts": ["low", "medium", "high"]},
        ]
        result = self.run_resolver(root, payload, "-WhatIf")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Main model:             gpt-5.5 (medium)", result.stdout)
        self.assertIn("reviewer                 gpt-5.5 (high)", result.stdout)
        generated = self.run_resolver(root, payload)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        manifest = json.loads((root / ".codex/resolved-models.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["available_models"], ["gpt-5.5"])
        self.assertEqual(manifest["catalog_source"], "file")

    def test_app_server_stdio_discovers_paginated_catalog_and_prefers_model_field(self):
        root = self.fixture()
        result = self.run_live_fixture(root, self.fake_codex())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Catalog source:          codex-app-server", result.stdout)
        self.assertIn("Main model:             gpt-6.10-sol", result.stdout)
        self.assertNotIn("wrong-sol-id", result.stdout)
        self.assertIn("gpt-6.1-terra", result.stdout)

    def test_app_server_auth_failure_leaves_existing_outputs_unchanged(self):
        root = self.fixture()
        self.assertEqual(self.run_resolver(root, catalog_items()).returncode, 0)
        generated = [root / ".codex/config.toml", *sorted((root / ".codex/agents").glob("*.toml")), root / ".codex/resolved-models.json"]
        before = {path: path.read_bytes() for path in generated}
        result = self.run_live_fixture(root, self.fake_codex(account_type="api"))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(path.read_bytes() == content for path, content in before.items()))

    def test_failed_resolution_leaves_existing_runtime_files_unchanged(self):
        root = self.fixture()
        self.assertEqual(self.run_resolver(root, catalog_items()).returncode, 0)
        generated = [root / ".codex/config.toml", *sorted((root / ".codex/agents").glob("*.toml")), root / ".codex/resolved-models.json"]
        before = {path: path.read_bytes() for path in generated}
        failed = self.run_resolver(root, catalog_items(include_terra=False))
        self.assertNotEqual(failed.returncode, 0)
        self.assertTrue(all(path.read_bytes() == content for path, content in before.items()))


if __name__ == "__main__":
    unittest.main()
