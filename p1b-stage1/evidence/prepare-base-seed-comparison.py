from pathlib import Path
import subprocess
base=Path('/tmp/p1b-base-errno');base.mkdir(exist_ok=True)
for name in ['image','prelude']:
    data=subprocess.check_output(['git','show',f'a6852ef8:host/chez/seed/{name}.ss'])
    (base/f'{name}.ss').write_bytes(data)
s=Path('host/chez/gate-boot.ss').read_text().replace('"host/chez/seed/image.ss"', '"/tmp/p1b-base-errno/image.ss"').replace('"host/chez/seed/prelude.ss"','"/tmp/p1b-base-errno/prelude.ss"')
# Force literal source arm so an ambient gate image cannot invalidate baseline.
s=s.replace('(and (not (gate-boot-narrow-hash?))','(and #f (not (gate-boot-narrow-hash?))')
(base/'gate-boot.ss').write_text(s)
s=Path('test/chez/ffi-native-error-test.ss').read_text().replace('"host/chez/gate-boot.ss"','"/tmp/p1b-base-errno/gate-boot.ss"')
(base/'errno.ss').write_text(s)
