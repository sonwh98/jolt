from pathlib import Path
import subprocess, tempfile, shutil
root=Path.cwd()
# A corrupted pinned input must reject the build before compilation.
with tempfile.TemporaryDirectory(prefix='p1b-digests-') as tmp:
    dst=Path(tmp)/'host/gambit/ffi'
    shutil.copytree(root/'host/gambit/ffi',dst)
    with (dst/'joltffi-bridge.scm').open('a') as f:f.write('\n;; deliberate digest corruption\n')
    p=subprocess.run(['sh',str(dst/'verify-digests.sh')],cwd=tmp,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=15)
    assert p.returncode != 0 and 'joltffi-bridge.scm: FAILED' in p.stdout,p.stdout
    print('digest-corruption negative control: PASS (rejected before compile)')
p=subprocess.run(['sh','host/gambit/ffi/watchdog.sh','1','sh','-c','sleep 20 & wait'],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=5)
assert p.returncode == 124 and 'WATCHDOG: TIMEOUT' in p.stdout,p.stdout
print('watchdog process-group deadline: PASS (exit 124)')
