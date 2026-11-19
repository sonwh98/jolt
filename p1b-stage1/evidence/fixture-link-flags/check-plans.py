"""Check make expansion only; this does not execute or qualify Linux code."""
from pathlib import Path
import subprocess

out = Path(__file__).resolve().parent
base = ['make', '--dry-run', 'gambitffi-bridge',
        'GAMBIT_PREFIX=/Users/sto/.local/share/mise/installs/gambit/4.9.8',
        'CHEZ=/Users/sto/.local/share/mise/installs/chezscheme/10.4.1/bin/scheme',
        'TMPDIR=' + str(Path('build/p1b-linux-r2/tmp').resolve())]


def plan(label, extra=()):
    result = subprocess.run(base + list(extra), capture_output=True, text=True, timeout=20)
    (out / (label + '.log')).write_text(result.stdout + result.stderr)
    return result


def commands(text):
    lines = text.splitlines()
    result = []
    i = 0
    while i < len(lines):
        if lines[i].startswith('sh host/gambit/ffi/watchdog.sh 60 cc '):
            command = [lines[i]]
            while command[-1].endswith('\\'):
                i += 1
                command.append(lines[i])
            result.append('\n'.join(command))
        i += 1
    assert len(result) == 4, result
    return result


before = commands((out / 'darwin-before.log').read_text())
darwin = plan('darwin-after')
assert darwin.returncode == 0, darwin.stderr
assert commands(darwin.stdout) == before
print('Darwin: PASS — all four expanded fixture link commands are byte-identical')
linux = plan('linux-plan', ['GAMBIT-FFI-HOST-OS=Linux'])
assert linux.returncode == 0, linux.stderr
assert commands(linux.stdout) == [s.replace(' -dynamiclib ', ' -shared -fPIC ') for s in before]
print('Linux plan: PASS — all four fixture commands select -shared -fPIC (no Linux execution)')
other = plan('unsupported-plan', ['GAMBIT-FFI-HOST-OS=FreeBSD'])
assert other.returncode != 0
assert "unsupported fixture-link platform 'FreeBSD'" in other.stderr, other.stderr
print('Unsupported platform: PASS — make refuses with the explicit fixture-link error')
