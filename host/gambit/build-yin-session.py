#!/usr/bin/env python3
"""Resolve the verified kernel and optionally build the native Yin startup code."""
import fcntl
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile

HOST = Path(__file__).resolve().parent
REPO = HOST.parents[1]
WATCHDOG = HOST / "ffi/watchdog.sh"
BOOT = runpy.run_path(str(HOST / "build-yin-boot.py"))
SOURCE_SUFFIXES = {".clj", ".cljc", ".jolt"}
UNIT_BYTES = 512 * 1024


def source_tree(root):
    """Include symlinked source directories as the namespace loader does."""
    def walk(directory, parents):
        target = directory.resolve()
        if target in parents:
            raise ValueError(f"cycle in Yin source paths at {directory}")
        for path in directory.iterdir():
            if path.is_dir():
                yield from walk(path, parents | {target})
            elif path.suffix in SOURCE_SUFFIXES and path.is_file():
                yield path

    if root.is_dir():
        yield from walk(root, set())


def session_key(kernel, runtime, datomworld):
    # These are the loader's complete candidate roots, including shadowed
    # sources. Hash names as well as bytes so insertion/removal changes the key.
    roots = [runtime / "host/gambit/yin", *(datomworld / "src" / name
             for name in ("jolt", "cljc", "clj")), runtime / "stdlib", runtime / "jolt-core",
             REPO / "jolt-core"]
    paths = [kernel, REPO / "Makefile", *HOST.glob("yin-*.ss"), HOST / "source-loader.ss",
             HOST / "host-apply.ss", HOST / "unbound-vars-lib.ss",
             *HOST.joinpath("yin").glob("*.ss"),
             HOST / "build-yin-session.py", HOST / "gen-seed.ss",
             REPO / "host/chez/emit-image.ss", *HOST.joinpath("ffi").glob("*.*"),
             runtime / "build/gambit-ffi/joltffi-bridge.o1"]
    paths.extend(path for root in roots for path in source_tree(root))
    return BOOT["input_key"](paths, (str(runtime), str(datomworld)))


def write_units(directory, captured):
    """Bundle complete namespace initializers into bounded translation units."""
    units = []
    pending = bytearray()
    for path in sorted(captured.glob("*.ss")):
        initializer = path.read_bytes()
        if pending and len(pending) + len(initializer) > UNIT_BYTES:
            unit = directory / f"yin-{len(units):02d}.ss"
            unit.write_bytes(pending)
            units.append(unit)
            pending.clear()
        pending.extend(initializer)
    if pending:
        unit = directory / f"yin-{len(units):02d}.ss"
        unit.write_bytes(pending)
        units.append(unit)
    return units


def build_session(gsi, kernel, cache, runtime, datomworld):
    with (cache / ".session.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        key = session_key(kernel, runtime, datomworld)
        pointer = cache / f"session-{key}"
        if (cache / f"session-{key}.rejected").exists():
            raise RuntimeError(f"Yin boot {key} failed equivalence")
        cached = BOOT["validated_entry"](pointer, "session.ss")
        if cached:
            return cached, key

        directory = Path(tempfile.mkdtemp(prefix="session-", dir=cache))
        print(f"jolt-gambit: Capturing Yin startup code in {directory}",
              file=sys.stderr, flush=True)
        captured = directory / "namespaces"
        captured.mkdir()
        env = dict(os.environ, JOLT_GAMBIT_YIN_BOOT=str(kernel),
                   JOLT_GAMBIT_YIN_CAPTURE=str(captured), JOLT_TRACE_SOURCE="1")
        for name in ("JOLT_CHECK", "JOLT_TRACE", "JOLT_YIN_AUDIT"):
            env.pop(name, None)
        with (directory / "capture.log").open("w") as log:
            status = subprocess.run(
                ["sh", str(WATCHDOG), "2400", str(gsi), str(HOST / "yin-capture.ss"),
                 str(datomworld)], cwd=runtime, env=env, stdout=log,
                stderr=subprocess.STDOUT).returncode
        if status:
            raise RuntimeError(f"Yin source capture exited {status}; see {directory / 'capture.log'}")

        names = {path.stem for path in captured.glob("*.ss")}
        if not {"jolt.gambit.yin", "dao.space.dht"}.issubset(names):
            raise RuntimeError("Yin capture did not complete")
        units = write_units(directory, captured)
        print(f"jolt-gambit: Compiling {len(names)} Yin namespaces in {len(units)} units",
              file=sys.stderr, flush=True)
        objects = BOOT["compile_units"](gsi.with_name("gsc"), directory, units)
        entry = directory / "session.ss"
        entry.write_text("".join(f"(load {json.dumps(str(obj), ensure_ascii=False)})\n"
                                 for obj in objects))
        if session_key(kernel, runtime, datomworld) != key:
            raise RuntimeError("Yin boot inputs changed during compilation")
        return BOOT["publish"](pointer, directory, [entry, *objects]), key


def resolve(gsi, datomworld):
    runtime = Path.cwd()
    mode = os.environ.get("JOLT_GAMBIT_YIN_MODE", "auto")
    hint = os.environ.get("JOLT_GAMBIT_YIN_BOOT")
    default = Path(hint).parent.parent if hint else runtime / "build/gambit-yin"
    cache = Path(os.environ.get("JOLT_GAMBIT_YIN_CACHE", default)).resolve()
    if mode not in {"auto", "compiled", "source"}:
        raise ValueError("JOLT_GAMBIT_YIN_MODE must be auto, compiled, or source")

    kernel = entry = key = None
    try:
        kernel = BOOT["build"](gsi.with_name("gsc"), cache)
        # These options inspect the compiler's live source traversal.
        debug = any(os.environ.get(name) for name in ("JOLT_CHECK", "JOLT_TRACE", "JOLT_YIN_AUDIT"))
        if mode == "compiled" or (mode == "auto" and not debug):
            entry, key = build_session(gsi, kernel, cache, runtime, datomworld)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as e:
        if mode == "compiled":
            raise
        print(f"jolt-gambit: Using source Yin boot ({e})", file=sys.stderr, flush=True)
    return (kernel, entry, key)


if __name__ == "__main__":
    try:
        items = resolve(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
        print("(" + " ".join(json.dumps(str(item), ensure_ascii=False) if item else "#f"
                             for item in items) + ")")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"jolt-gambit: {error}", file=sys.stderr)
        sys.exit(1)
