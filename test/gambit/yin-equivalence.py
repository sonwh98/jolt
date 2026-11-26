"""Run both native Yin startup paths and compare the actual reply bytes."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

GSI, DATOMWORLD = sys.argv[1:]
CACHE = Path(os.environ["JOLT_GAMBIT_YIN_CACHE"]).resolve()
CACHE.mkdir(parents=True, exist_ok=True)
RUN = Path(tempfile.mkdtemp(prefix="equivalence-", dir=CACHE))
KEY = re.compile(rb"^jolt-gambit: compiled Yin boot ([0-9a-f]{64})$", re.M)


def exercise(mode, corpus):
    directory = RUN / mode / corpus
    directory.mkdir(parents=True)
    env = dict(os.environ, JOLT_GAMBIT_YIN_MODE=mode, JOLT_TRACE_SOURCE="1")
    if corpus == "repl":
        script = "test/gambit/yin-repl-session.sh"
        args = []
        reply_path = directory / "repl.stdout"
        env["JOLT_YIN_REPL_TRANSCRIPT"] = str(reply_path)
        launcher_log = directory / "gate.stderr"
    else:
        script = "test/gambit/yin-dht-probe.sh"
        args = [corpus]
        reply_path = directory / f"{corpus}.stdout"
        env["JOLT_YIN_DHT_RECEIPTS"] = str(directory)
        launcher_log = directory / f"{corpus}.stderr"
    with (directory / "gate.stdout").open("wb") as out, (directory / "gate.stderr").open("wb") as err:
        status = subprocess.run(["sh", script, GSI, DATOMWORLD, *args],
                                env=env, stdout=out, stderr=err).returncode
    log = launcher_log.read_bytes() if launcher_log.exists() else b""
    match = KEY.search(log)
    source_root_loaded = b"ready jolt.gambit.yin\n" in log
    if mode == "compiled" and (match is None or source_root_loaded):
        status = status or 1
    if mode == "source" and (match or not source_root_loaded):
        status = status or 1
    print(f"gambityinequivalence: {mode} {corpus} exited {status}", flush=True)

    if reply_path.exists():
        output = reply_path.read_bytes()
        prompt = re.search(rb"^yin> ", output, re.M)
        if prompt:
            (directory / "replies").write_bytes(output[prompt.start():])
    return status, match[1].decode() if match else None, directory / "replies"


def main():
    print(f"gambityinequivalence receipts: {RUN}", flush=True)
    corpora = ("repl", "stock", "diagnostics")
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = {(mode, corpus): pool.submit(exercise, mode, corpus)
                   for mode in ("source", "compiled") for corpus in corpora}
    failed = False
    for corpus in corpora:
        source, _, expected = results["source", corpus].result()
        compiled, key, actual = results["compiled", corpus].result()
        different = (expected.is_file() and actual.is_file()
                     and subprocess.run(["diff", "-u", expected, actual]).returncode != 0)
        if source or compiled or different or not actual.is_file() or not expected.is_file():
            failed = True
            reference_complete = (expected.is_file() and
                                  b"yin> Bye\n" in expected.read_bytes())
            if key and (not source or (reference_complete and different)):
                # Only reject the exact key used by this process. A later
                # launch sees the mismatch and selects source automatically.
                (CACHE / f"session-{key}.rejected").touch()
                print(f"gambityinequivalence: rejected {key}", flush=True)
        else:
            print(f"gambityinequivalence: {corpus} replies match byte-for-byte", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
