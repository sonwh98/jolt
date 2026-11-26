#!/usr/bin/env python3
"""Build the shared Gambit kernel and compiler seed for Yin."""
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import subprocess
import sys
import tempfile


INCLUDE = re.compile(r'(?m)^([ \t]*)\(##include "([^"]+)"\)')
REPO = Path(__file__).resolve().parents[2]
BOOT = REPO / "host/gambit/boot.ss"
SEEDS = {"seed/prelude.ss": ("prelude", 120), "seed/image.ss": ("compiler", 125)}


def boot_sources(path, seen):
    if path in seen:
        return
    seen.add(path)
    text = path.read_text()
    yield path, text
    for match in INCLUDE.finditer(text):
        yield from boot_sources((path.parent / match[2]).resolve(), seen)


def write_units(directory):
    units = []

    def rewrite(match):
        indent, relative = match.groups()
        path = (BOOT.parent / relative).resolve()
        if relative not in SEEDS:
            return f'{indent}(##include {json.dumps(str(path), ensure_ascii=False)})'
        prefix, chunk_size = SEEDS[relative]
        # The seed emitter writes each guarded top-level form at column zero.
        forms = re.split(r'(?m)(?=^\(guard )', path.read_text())
        if forms[0].strip():
            raise ValueError(f"Unexpected seed format in {path}")
        forms = forms[1:]
        loads = []
        for start in range(0, len(forms), chunk_size):
            unit = directory / f"{prefix}-{start // chunk_size:02d}.ss"
            unit.write_text("".join(forms[start:start + chunk_size]))
            units.append(unit)
            artifact = json.dumps(str(unit.with_suffix(".o1")), ensure_ascii=False)
            loads.append(f"{indent}(load {artifact})")
        return "\n".join(loads)

    kernel = directory / "kernel.ss"
    kernel.write_text(INCLUDE.sub(rewrite, BOOT.read_text()))
    return [kernel, *units]


def hash_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def input_key(paths, context=()):
    digest = hashlib.sha256()
    for value in context:
        digest.update(os.fsencode(value) + b"\0")
    for path in sorted(set(paths)):
        digest.update(os.fsencode(path) + b"\0" + hash_file(path).encode() + b"\n")
    return digest.hexdigest()


def kernel_key(gsc):
    prefix = gsc.parent.parent
    compiler = subprocess.check_output(["cc", "--version"], timeout=30)
    paths = [Path(__file__).resolve(), gsc, gsc.with_name("gsi"), gsc.with_name("gambuild-C"),
             *prefix.glob("include/*.h"), *prefix.glob("lib/libgambit.*")]
    paths.extend(path for path, _ in boot_sources(BOOT, set()))
    return input_key(paths, (platform.system(), platform.machine(), compiler))


def artifact_manifest(directory, artifacts):
    return {"directory": directory.name,
            "objects": {path.name: hash_file(path) for path in artifacts}}


def validated_entry(pointer, first):
    try:
        manifest = json.loads(pointer.read_text())
        directory = pointer.parent / manifest["directory"]
        objects = manifest["objects"]
        if not objects or next(iter(objects)) != first:
            return None
        if any(Path(name).name != name or hash_file(directory / name) != digest
               for name, digest in objects.items()):
            return None
        return directory / first
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return None


def publish(pointer, directory, artifacts):
    pending = directory / "cache-entry"
    pending.write_text(json.dumps(artifact_manifest(directory, artifacts)) + "\n")
    pending.replace(pointer)
    return artifacts[0]


def compile_units(gsc, directory, units, kernel=False):
    def compile_unit(unit):
        # The kernel alone expands to a large C translation unit.
        options = ["-:min-heap=768M"] if kernel and unit == units[0] else []
        with unit.with_suffix(".log").open("w") as log:
            status = subprocess.run(
                ["sh", str(REPO / "host/gambit/ffi/watchdog.sh"),
                 "1800" if kernel else "900", str(gsc),
                 *options, "-dynamic", "-cc-options", "-O0", unit.name],
                cwd=directory, stdout=log, stderr=subprocess.STDOUT).returncode
        artifact = unit.with_suffix(".o1")
        if status or not artifact.is_file():
            raise RuntimeError(f"Gambit did not compile {unit}; see {unit.with_suffix('.log')}")
        return artifact

    with ThreadPoolExecutor(max_workers=2) as executor:
        return list(executor.map(compile_unit, units))


def build(gsc, cache):
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / ".kernel.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        key = kernel_key(gsc)
        pointer = cache / key
        kernel = validated_entry(pointer, "kernel.o1")
        if kernel:
            return kernel

        directory = Path(tempfile.mkdtemp(prefix="boot-", dir=cache))
        print(f"jolt-gambit: Building Gambit kernel in {directory}", file=sys.stderr, flush=True)
        units = write_units(directory)
        artifacts = compile_units(gsc, directory, units, kernel=True)
        if kernel_key(gsc) != key:
            raise RuntimeError("Gambit kernel inputs changed during compilation")
        return publish(pointer, directory, artifacts)


if __name__ == "__main__":
    print(build(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()))
