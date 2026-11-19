#!/usr/bin/env python3
"""Compile Jolt's existing Gambit boot for the Yin loaded-source gate."""
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
import json
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


def build(gsc, cache):
    digest = hashlib.sha256(Path(__file__).read_bytes())
    digest.update(gsc.read_bytes())
    for path, text in sorted(boot_sources(BOOT, set())):
        digest.update(str(path).encode())
        digest.update(text.encode())
    key = digest.hexdigest()
    cache.mkdir(parents=True, exist_ok=True)
    pointer = cache / key

    with (cache / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if pointer.exists():
            kernel = Path(pointer.read_text().strip())
            if kernel.is_file():
                return kernel

        directory = Path(tempfile.mkdtemp(prefix="boot-", dir=cache))
        units = write_units(directory)

        def compile_unit(unit):
            # The kernel alone expands to a large C translation unit.
            options = ["-:min-heap=768M"] if unit == units[0] else []
            subprocess.run([str(gsc), *options, "-dynamic", "-cc-options", "-O0", unit.name],
                           cwd=directory, stdout=sys.stderr, check=True)
            if not unit.with_suffix(".o1").is_file():
                raise RuntimeError(f"Gambit did not produce an object for {unit}")

        with ThreadPoolExecutor(max_workers=2) as executor:
            list(executor.map(compile_unit, units))

        kernel = units[0].with_suffix(".o1")
        pending = directory / "cache-entry"
        pending.write_text(f"{kernel}\n")
        pending.replace(pointer)
        return kernel


if __name__ == "__main__":
    print(build(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()))
