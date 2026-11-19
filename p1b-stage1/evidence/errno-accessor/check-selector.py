"""Check make selection only; Linux execution remains the orchestrator's leg."""
from pathlib import Path
import subprocess

out = Path(__file__).resolve().parent
base = ['make', '--dry-run', 'gambitffi-abi',
        'GAMBIT_PREFIX=/Users/sto/.local/share/mise/installs/gambit/4.9.8',
        'CHEZ=/Users/sto/.local/share/mise/installs/chezscheme/10.4.1/bin/scheme',
        'TMPDIR=' + str(Path('build/p1b-linux-r3/tmp').resolve())]


def plan(label, extra=()):
    result = subprocess.run(base + list(extra), capture_output=True, text=True, timeout=20)
    (out / (label + '.log')).write_text(result.stdout + result.stderr)
    assert result.returncode == 0, result.stderr
    return result.stdout


def links(text):
    lines = iter(text.splitlines())
    commands = []
    for line in lines:
        if line.startswith('sh host/gambit/ffi/watchdog.sh 60 cc '):
            command = [line]
            while command[-1].endswith('\\'):
                command.append(next(lines))
            commands.append('\n'.join(command))
    assert len(commands) == 4
    return commands


darwin = plan('darwin-plan')
linux = plan('linux-plan', ['GAMBIT-FFI-HOST-OS=Linux'])
assert 'JOLT_FFI_ERRNO_ACCESSOR="__error"' in darwin
assert 'JOLT_FFI_ERRNO_ACCESSOR="__errno_location"' not in darwin
assert 'JOLT_FFI_ERRNO_ACCESSOR="__errno_location"' in linux
assert 'JOLT_FFI_ERRNO_ACCESSOR="__error"' not in linux
original = Path('p1b-stage1/evidence/fixture-link-flags/darwin-before.log').read_text()
assert links(darwin) == links(original)
print('Darwin selector: PASS — __error; all four Darwin fixture link commands remain byte-identical')
print('Linux selector plan: PASS — __errno_location (no Linux execution)')
