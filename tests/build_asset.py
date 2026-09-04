"""Build the NetworkHealthCheck release asset the way the repository's packaging rule requires (healthcheck/VALIDATION.md,
"Packaging"): tracked files under healthcheck/ only, so Reports/ and every other untracked output are excluded by
construction; working-tree bytes, so the CRLF checkout is preserved; one top-level NetworkHealthCheck-<version>/ folder;
deflate. The version is read from the en-US script. Prints the size and the SHA256 that go into the release notes.

Usage (from anywhere):  python tests/build_asset.py [<out.zip>]    default: NetworkHealthCheck-<version>.zip in the current directory"""
import hashlib, pathlib, subprocess, sys, zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'healthcheck'

version = None
for line in (PACKAGE / 'en-US' / 'NetworkHealthCheck.ps1').read_text(encoding='utf-8-sig').splitlines():
    if line.startswith('$script:ToolVersion'):
        version = line.split('"')[1]
        break
assert version, 'tool version not found'
TOP = f'NetworkHealthCheck-{version}'
OUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(f'{TOP}.zip')

tracked = subprocess.run(['git', '-C', str(ROOT), 'ls-files', 'healthcheck'], capture_output=True, text=True, check=True).stdout.split('\n')
files = sorted(p[len('healthcheck/'):] for p in (x.strip() for x in tracked) if p)
assert files and not any(f.startswith('Reports/') or '/Reports/' in f for f in files)
missing = [f for f in files if not (PACKAGE / f).is_file()]
assert not missing, f'tracked but absent from the working tree: {missing}'
print(f'version {version}: {len(files)} tracked files')

dirs = sorted({str(pathlib.PurePosixPath(f).parent) for f in files if '/' in f})
OUT.parent.mkdir(parents=True, exist_ok=True)
if OUT.exists():
    OUT.unlink()
with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr(zipfile.ZipInfo(TOP + '/'), b'')
    for d in dirs:
        z.writestr(zipfile.ZipInfo(f'{TOP}/{d}/'), b'')
    for f in files:
        z.writestr(f'{TOP}/{f}', (PACKAGE / f).read_bytes())

digest = hashlib.sha256(OUT.read_bytes()).hexdigest()
print(f'{OUT.name}: {OUT.stat().st_size} bytes')
print(f'SHA256: {digest}')
crlf = [f for f in files if f.endswith(('.ps1', '.cmd', '.config.json'))]
bad = [f for f in crlf if b'\n' in (PACKAGE / f).read_bytes().replace(b'\r\n', b'')]
print(f'CRLF files packaged: {len(crlf)}, with a stray LF: {len(bad)}')
assert not bad, bad
