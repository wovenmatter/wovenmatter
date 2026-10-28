"""Fast compression must retain compatibility and retry before notarization."""
import os
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    hdiutil = root / 'hdiutil'
    hdiutil.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
level = sys.argv[sys.argv.index('-format') + 1]
with open(os.environ['COMPRESSION_CALLS'], 'a') as f: f.write(level + '\\n')
pathlib.Path(sys.argv[-1]).write_text(level)
''')
    stat = root / 'stat'
    stat.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
level = pathlib.Path(sys.argv[-1]).read_text()
mode = os.environ['COMPRESSION_MODE']
print(536870913 if mode == 'oversize' or (mode == 'retry' and level == 'ULFO') else 500000000)
''')
    for tool in (hdiutil, stat): tool.chmod(0o755)
    for mode, expected in [('small', 0), ('retry', 0), ('oversize', 65)]:
        output, calls = root / f'{mode}.dmg', root / f'{mode}.log'
        result = subprocess.run([ROOT / 'scripts/create-release-dmg.sh', root, output],
            env=dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'], COMPRESSION_MODE=mode, COMPRESSION_CALLS=str(calls)), capture_output=True, text=True)
        assert result.returncode == expected, result
        assert calls.read_text().splitlines() == (['ULFO'] if mode == 'small' else ['ULFO', 'ULMO'])
print('DMG compression: fast path, maximum-compression fallback, and oversize rejection passed.')
