#!/usr/bin/env python3
"""Local provenance acceptance/refusals; synthetic hosts do not qualify an ABI."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
import toolchain

VERSION = 'v4.9.8 20261119000000 aarch64-linux-android "./configure \'--enable-single-host\'"'


class ToolchainChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.prefix = self.root / "install"
        self.records = self.root / "records"
        for name in toolchain.PATHS:
            path = self.prefix / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("synthetic input: " + name).encode())
        self.set_version(VERSION)
        self.linux = SimpleNamespace(sysname="Linux", machine="x86_64")
        self.record = self.records / "TOOLCHAIN.linux-x86_64.json"

    def set_version(self, version):
        gsi = self.prefix / "bin/gsi"
        gsi.write_text("#!/bin/sh\nprintf '%s\\n' " + shlex.quote(version) + "\n")
        gsi.chmod(0o755)

    def invoke(self, action, host=None, prefix=None):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(toolchain, "RECORD_DIR", self.records), \
                patch.object(toolchain.os, "uname", return_value=host or self.linux), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = toolchain.main([action, str(prefix or self.prefix)])
        return code, out.getvalue(), err.getvalue()

    def valid_record(self):
        code, _, err = self.invoke("record")
        self.assertEqual(code, 0, err)

    def test_record_and_accept_current_install(self):
        self.valid_record()
        record = json.loads(self.record.read_text())
        self.assertEqual(record["platform"], "linux-x86_64")
        self.assertEqual(record["install_path"], str(self.prefix))
        self.assertEqual(record["gambit_version_string"], VERSION)
        self.assertEqual(record["configure_summary_sha256"],
                         hashlib.sha256(b"./configure '--enable-single-host'").hexdigest())
        self.assertEqual(set(record["inputs_sha256"]), set(toolchain.PATHS))
        code, out, err = self.invoke("verify")
        self.assertEqual(code, 0, err)
        self.assertIn("platform=linux-x86_64", out)
        self.assertIn(str(self.record), out)
        self.assertIn("local toolchain provenance verified (7 inputs)", out)

    def test_missing_record_never_uses_another_platform(self):
        self.valid_record()
        self.record.rename(self.records / "TOOLCHAIN.darwin-arm64.json")
        code, _, err = self.invoke("verify")
        self.assertEqual(code, 1)
        self.assertIn("missing local toolchain provenance", err)
        self.assertIn("sh host/gambit/ffi/record-toolchain.sh " + str(self.prefix), err)

    def test_each_provenance_field_is_checked(self):
        self.valid_record()
        before = self.record.read_text()
        for field in json.loads(before):
            with self.subTest(field=field):
                record = json.loads(before)
                record[field] = "stale"
                self.record.write_text(json.dumps(record))
                code, _, err = self.invoke("verify")
                self.assertEqual(code, 1)
                self.assertIn("stale local toolchain provenance", err)

    def test_fresh_build_requires_record_then_is_accepted(self):
        self.valid_record()
        (self.prefix / "bin/gsc").write_bytes(b"another legitimate build")
        self.set_version(VERSION.replace("20261119000000", "20261119111111"))
        self.assertEqual(self.invoke("verify")[0], 1)
        self.valid_record()
        self.assertEqual(self.invoke("verify")[0], 0)

    def test_changed_configure_summary_is_rejected(self):
        self.valid_record()
        self.set_version(VERSION.replace("--enable-single-host", "--enable-multiple-hosts"))
        self.assertEqual(self.invoke("verify")[0], 1)

    def test_install_path_is_checked_and_explicitly_recordable(self):
        self.valid_record()
        second = self.root / "different install"
        shutil.copytree(self.prefix, second)
        self.assertEqual(self.invoke("verify", prefix=second)[0], 1)
        self.assertEqual(self.invoke("record", prefix=second)[0], 0)
        self.assertEqual(self.invoke("verify", prefix=second)[0], 0)

    def test_record_is_deterministic(self):
        self.valid_record()
        before = self.record.read_bytes()
        os.utime(self.prefix / "bin/gsc", (0, 0))
        self.valid_record()
        self.assertEqual(self.record.read_bytes(), before)

    def test_missing_input_does_not_replace_record(self):
        self.valid_record()
        before = self.record.read_bytes()
        (self.prefix / "bin/gsc").unlink()
        self.assertEqual(self.invoke("record")[0], 1)
        self.assertEqual(self.record.read_bytes(), before)

    def test_unrecognized_version_refuses(self):
        self.set_version("v4.9.9 no configure summary")
        self.assertEqual(self.invoke("record")[0], 1)
        self.assertFalse(self.record.exists())

    def test_bionic_uname_can_record_linux_arm64(self):
        host = SimpleNamespace(sysname="Linux", machine="aarch64")
        code, out, err = self.invoke("record", host)
        self.assertEqual(code, 0, err)
        self.assertIn("platform=linux-arm64", out)
        self.assertTrue((self.records / "TOOLCHAIN.linux-arm64.json").exists())
        self.assertEqual(self.invoke("verify", host)[0], 0)

    def test_unsupported_uname_refuses_clearly(self):
        for system, machine in (("FreeBSD", "amd64"), ("../Linux", "arm64"), ("Linux", "riscv64")):
            code, _, err = self.invoke("record", SimpleNamespace(sysname=system, machine=machine))
            self.assertEqual(code, 1)
            self.assertIn("unsupported uname platform", err)

    def test_real_shell_entrypoints_keep_sources_pinned_and_records_local(self):
        destination = self.root / "checkout/host/gambit/ffi"
        shutil.copytree(Path(toolchain.__file__).parent, destination)
        before = (destination / "DIGESTS.txt").read_bytes()
        command = ["sh", str(destination / "record-toolchain.sh"), str(self.prefix)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((destination / "DIGESTS.txt").read_bytes(), before)
        verify = ["sh", str(destination / "verify-digests.sh"), str(self.prefix)]
        result = subprocess.run(verify, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        records = self.root / "checkout/build/gambit-ffi/provenance"
        shutil.rmtree(records)
        result = subprocess.run(verify, capture_output=True, text=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing local toolchain provenance", result.stderr)
        # Source corruption is checked even when provenance is missing.
        with (destination / "joltffi-fixture.c").open("a") as stream:
            stream.write("\n/* changed input */\n")
        result = subprocess.run(verify, capture_output=True, text=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("joltffi-fixture.c: FAILED", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
