#!/usr/bin/env python3
"""Provenance checks with synthetic files/host metadata, not Linux ABI tests."""
import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
import toolchain

INPUTS = ("bin/gsi", "bin/gsc", "bin/gambuild-C", "include/gambit.h",
          "lib/libgambit.a", "lib/libgambitgsi.a", "lib/libgambitgsc.a")


class ToolchainChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.prefix = self.root / "install"
        self.records = self.root / "records"
        self.records.mkdir()
        for name in INPUTS:
            path = self.prefix / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("synthetic input: " + name).encode())
        self.linux = SimpleNamespace(sysname="Linux", machine="x86_64")
        self.record = self.records / "TOOLCHAIN.linux-x86_64.sha256"

    def invoke(self, action, host=None):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(toolchain, "MANIFEST_DIR", self.records), \
                patch.object(toolchain.os, "uname", return_value=host or self.linux), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = toolchain.main([action, str(self.prefix)])
        return code, out.getvalue(), err.getvalue()

    def valid_record(self):
        self.record.write_text(toolchain.render_manifest(self.prefix, "linux-x86_64"))

    def test_record_and_accept_linux_manifest(self):
        with patch.object(toolchain.subprocess, "run") as refresh:
            code, out, err = self.invoke("record")
        self.assertEqual(code, 0, err)
        self.assertIn("platform=linux-x86_64", out)
        self.assertIn("manifest=host/gambit/ffi/TOOLCHAIN.linux-x86_64.sha256", out)
        self.assertIn("recorded 7 toolchain inputs", out)
        refresh.assert_called_once_with(["sh", str(self.records / "make-digests.sh")], check=True)
        lines = self.record.read_text().splitlines()
        self.assertEqual(lines[:2], ["# joltffi toolchain manifest v1", "# platform: linux-x86_64"])
        self.assertEqual(tuple(line.split("  ")[1] for line in lines[2:]), INPUTS)
        code, out, err = self.invoke("verify")
        self.assertEqual(code, 0, err)
        self.assertEqual(out.count(": OK\n"), 7)

    def test_missing_linux_manifest_never_falls_back_to_darwin(self):
        (self.records / "TOOLCHAIN.darwin-arm64.sha256").write_text(
            toolchain.render_manifest(self.prefix, "darwin-arm64"))
        code, out, err = self.invoke("verify")
        self.assertEqual(code, 1)
        self.assertIn("TOOLCHAIN.linux-x86_64.sha256", out)
        self.assertIn("missing toolchain manifest", err)

    def test_changed_binary_is_rejected(self):
        self.valid_record()
        (self.prefix / "bin/gsc").write_bytes(b"changed binary")
        code, _, err = self.invoke("verify")
        self.assertEqual(code, 1)
        self.assertIn("bin/gsc: FAILED", err)

    def test_mislabelled_platform_is_rejected(self):
        self.record.write_text(toolchain.render_manifest(self.prefix, "darwin-arm64"))
        code, _, err = self.invoke("verify")
        self.assertEqual(code, 1)
        self.assertIn("header mismatch", err)

    def test_incomplete_duplicate_or_extra_inputs_are_rejected(self):
        lines = toolchain.render_manifest(self.prefix, "linux-x86_64").splitlines()
        for rows in (lines[:-1], lines[:3] + [lines[2]] + lines[4:], lines + [lines[-1]]):
            with self.subTest(rows=rows):
                self.record.write_text("\n".join(rows) + "\n")
                code, _, err = self.invoke("verify")
                self.assertEqual(code, 1)
                self.assertIn("seven ordered inputs", err)

    def test_unrecorded_platform_is_rejected(self):
        code, out, err = self.invoke("verify", SimpleNamespace(sysname="FreeBSD", machine="amd64"))
        self.assertEqual(code, 1)
        self.assertIn("platform=freebsd-x86_64", out)
        self.assertIn("missing toolchain manifest", err)

    def test_record_is_deterministic_and_install_path_independent(self):
        second = self.root / "other-install"
        shutil.copytree(self.prefix, second)
        os.utime(second / "bin/gsc", (0, 0))
        self.assertEqual(toolchain.render_manifest(self.prefix, "linux-x86_64"),
                         toolchain.render_manifest(second, "linux-x86_64"))

    def test_missing_input_does_not_replace_existing_pins(self):
        self.valid_record()
        before = self.record.read_bytes()
        (self.prefix / "bin/gsi").unlink()
        with patch.object(toolchain.subprocess, "run") as refresh:
            code, _, _ = self.invoke("record")
        self.assertEqual(code, 1)
        self.assertEqual(self.record.read_bytes(), before)
        refresh.assert_not_called()

    def test_invalid_platform_key_is_rejected(self):
        code, _, err = self.invoke("verify", SimpleNamespace(sysname="../Linux", machine="x86_64"))
        self.assertEqual(code, 1)
        self.assertIn("invalid uname platform key", err)

    def test_unindexed_manifest_is_rejected_by_full_verifier(self):
        # Exercise the actual shell entry points in an isolated checkout slice.
        destination = self.root / "checkout/host/gambit/ffi"
        shutil.copytree(Path(toolchain.__file__).parent, destination)
        record = subprocess.run(["sh", str(destination / "record-toolchain.sh"), str(self.prefix)],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(record.returncode, 0, record.stdout + record.stderr)
        verify = ["sh", str(destination / "verify-digests.sh"), str(self.prefix)]
        good = subprocess.run(verify, capture_output=True, text=True, timeout=20)
        self.assertEqual(good.returncode, 0, good.stdout + good.stderr)
        (destination / "TOOLCHAIN.unindexed.sha256").write_text("unreviewed pins\n")
        bad = subprocess.run(verify, capture_output=True, text=True, timeout=20)
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("catalog is stale", bad.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
