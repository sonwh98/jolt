#!/usr/bin/env python3
"""Drive distinct Yin processes and assert persisted bytes and UDP replication."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time


REPO = Path(__file__).resolve().parents[2]
TIMEOUT = int(os.environ.get("GAMBIT_DHT_TIMEOUT_SECONDS", "2400"))
ADDRESS = r":segment/blake3-[0-9a-f]{64}"
VALUE = r'\{:p2 "durable-gambit", :count 7331\}'
# A transport event can take the prompt on the same tick as a reply.
REPLIES = re.compile(
    rf"^(?:yin> )*('p2\.probe|{ADDRESS}|{VALUE}|:missing|nil|"
    r"'p2-(?:file|dht)-witness|7331|Bye|Error: .*?)\n", re.M
)
PROBE = "(p2.probe/run :{})\n"


class Session:
    def __init__(self, run, name, command, cwd, env, args):
        self.name = name
        self.out = run / f"{name}.stdout"
        self.err = run / f"{name}.stderr"
        self.deadline = time.monotonic() + TIMEOUT
        with self.out.open("w") as out, self.err.open("w") as err:
            self.process = subprocess.Popen(
                [*command, *args], stdin=subprocess.PIPE, stdout=out, stderr=err,
                cwd=cwd, env=env, text=True, start_new_session=True,
            )
        self.offset = 0

    def __enter__(self):
        return self

    def __exit__(self, *_):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait()
        self.process.stdin.close()

    def send(self, text):
        self.process.stdin.write(text)
        self.process.stdin.flush()

    def output(self):
        return self.out.read_text(errors="replace")

    def await_output(self, pattern, deadline=None):
        deadline = min(deadline or self.deadline, self.deadline)
        while True:
            match = re.search(pattern, self.output(), re.M)
            if match:
                return match
            if self.process.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError(f"{self.name}: missing {pattern!r}; see {self.out} and {self.err}")
            time.sleep(0.2)

    def reply(self, pattern):
        self.await_output(r"^yin> ")
        while True:
            replies = REPLIES.findall(self.output())
            if len(replies) > self.offset:
                reply = replies[self.offset]
                self.offset += 1
                if not re.fullmatch(pattern, reply):
                    raise RuntimeError(f"{self.name}: expected {pattern!r}, got {reply!r}")
                return reply
            if self.process.poll() is not None or time.monotonic() >= self.deadline:
                raise RuntimeError(f"{self.name}: missing reply {pattern!r}; see {self.out} and {self.err}")
            time.sleep(0.2)

    def probe(self, operation, expected):
        self.send(PROBE.format(operation))
        return self.reply(expected)

    def status(self, expected):
        status = self.process.wait(timeout=max(0.1, self.deadline - time.monotonic()))
        if status != expected:
            raise RuntimeError(f"{self.name}: exit {status}, expected {expected}; see {self.out} and {self.err}")

    def quit(self):
        self.send("(quit)\n")
        self.reply("Bye")
        self.status(0)

    def require_probe(self):
        self.send("(require 'p2.probe)\n")
        self.reply(r"'p2\.probe")


def reserve_ports():
    # Reserve distinct loopback ports before launching the two UDP peers.
    with ExitStack() as cleanup:
        sockets = [cleanup.enter_context(socket.socket(socket.AF_INET, socket.SOCK_DGRAM))
                   for _ in range(2)]
        for udp in sockets:
            udp.bind(("127.0.0.1", 0))
        return [udp.getsockname()[1] for udp in sockets]


def read_head(directory):
    text = (directory / "HEAD").read_text()
    match = re.search(ADDRESS, text)
    if not match:
        raise RuntimeError(f"{directory}: HEAD contains no manifest: {text!r}")
    return match[0]


def exercise(launch, run, kind, ports):
    state_dir = run / f"{kind}-state"
    directory = run / f"{kind}-store"
    selected = f"{kind}:{directory}"
    args = ["--dir", str(state_dir), "--index-store", selected]
    with ExitStack() as cleanup:
        peer = None
        if kind == "dht":
            source_port, peer_port = ports
            peer = cleanup.enter_context(launch("dht-peer", [
                "--no-state", "--index-store", f"dht:{run / 'peer-store'}",
                "--dht-peer", f"127.0.0.1:{source_port}", "--dht-port", str(peer_port),
            ]))
            args += ["--dht-peer", f"127.0.0.1:{peer_port}",
                     "--dht-port", str(source_port), "--dht-publish"]

        writer = cleanup.enter_context(launch(f"{kind}-write", args))
        writer.require_probe()
        if peer is not None:
            peer.require_probe()
            peer.probe("get", ":missing")
        address = writer.probe("put", ADDRESS)
        writer.probe("get", VALUE)
        writer.send(f"(def p2-{kind}-witness 7331)\n")
        writer.reply(r"(?:'p2-(?:file|dht)-witness|7331)")
        head = read_head(directory)
        if selected not in (state_dir / "state.edn").read_text():
            raise RuntimeError(f"{kind}: state.edn failed to save {selected}")

        if kind == "file":
            # A different spelling takes the same kernel lock. Keep the
            # writer alive until the rival really reports the refusal.
            alias = run / "alias"
            alias.symlink_to(directory, target_is_directory=True)
            rival = cleanup.enter_context(launch("file-rival", [
                "--no-state", "--index-store", f"file:{alias}",
            ]))
            rival.status(1)
            rival.await_output(rf"^{re.escape(str(alias))} is locked by another process$")
            if read_head(directory) != head:
                raise RuntimeError("the refused launcher changed the writer's HEAD")
        else:
            replication_deadline = time.monotonic() + 120
            while True:
                peer.send(PROBE.format("get"))
                answer = peer.reply(VALUE + r"|:missing")
                if answer != ":missing":
                    break
                if time.monotonic() >= replication_deadline:
                    raise RuntimeError("replicated value never appeared in the second durable store")
                time.sleep(0.5)
            peer.quit()
            if not (run / "peer-store" / "content.jing").stat().st_size:
                raise RuntimeError("the receiving peer left an empty content log")

        writer.quit()
        # Compare after shutdown in case draining published a later HEAD.
        head = read_head(directory)

    with launch(f"{kind}-restart", ["--dir", str(state_dir)]) as reader:
        reader.require_probe()
        reader.await_output(rf"^state: resumed from {re.escape(str(state_dir / 'state.edn'))} ")
        reader.probe("recovered", re.escape(head))
        reader.probe("get", VALUE)
        reader.quit()
    print(f"{kind}: {address} survived restart with HEAD {head}", flush=True)


def main(gsi, datomworld, boot):
    receipts = REPO / "build" / "gambit-dht-durable"
    receipts.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(dir=receipts, prefix="run."))
    print(f"gambitdht-durable receipts: {run}", flush=True)
    overlay = run / "jolt"
    yin = overlay / "host" / "gambit" / "yin"
    shutil.copytree(REPO / "host" / "gambit" / "yin", yin)
    with (yin / "jolt" / "gambit" / "yin.jolt").open("a") as launcher:
        launcher.write((REPO / "test" / "gambit" / "fixtures" / "yin-durable.jolt").read_text())
    for name in ("build", "stdlib", "jolt-core"):
        (overlay / name).symlink_to(REPO / name, target_is_directory=True)
    env = dict(os.environ, JOLT_GAMBIT_YIN_BOOT=str(Path(boot).resolve()), JOLT_TRACE_SOURCE="1")
    command = [gsi, REPO / "host" / "gambit" / "yin-repl-native.ss", datomworld]

    def launch(name, args):
        return Session(run, name, command, overlay, env, args)

    ports = reserve_ports()
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = [pool.submit(exercise, launch, run, kind, ports) for kind in ("file", "dht")]
        for result in results:
            result.result()
    print("gambitdht-durable: PASS — persisted bytes and HEAD, state.edn resume, rival lock refusal, replicated peer bytes")


if __name__ == "__main__":
    main(*sys.argv[1:])
