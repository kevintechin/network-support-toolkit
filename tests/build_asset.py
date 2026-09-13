"""Build the NetworkHealthCheck release asset the way the repository's packaging rule requires (healthcheck/VALIDATION.md,
"Packaging"): tracked files under healthcheck/ only, so Reports/ and every other untracked output are excluded by
construction; working-tree bytes, so the CRLF checkout is preserved; one top-level NetworkHealthCheck-<version>/ folder;
deflate. The version is read from the en-US script. Prints the size and the SHA256 that go into the release notes.

Every entry is stamped with the date of the commit the build is made from, so that the same commit gives the same
archive byte for byte (backlog #21). Without that stamp zipfile writes the build time into each file entry, which is
why four CI builds of identical content produced four digests; the directory entries were already deterministic,
because a bare ZipInfo dates from 1980, and they keep that date. The stamp makes the digest a fact about the commit:
built from a working tree that differs from it, the archive is what the tree says and the digest is not reproducible,
which is why the tree's state is printed beside it.

Usage (from anywhere):  python tests/build_asset.py [<out.zip>]    default: NetworkHealthCheck-<version>.zip in the current directory"""
import hashlib, pathlib, subprocess, sys, time, zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'healthcheck'


def git(*args):
    return subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, text=True, check=True).stdout.strip()


version = None
for line in (PACKAGE / 'en-US' / 'NetworkHealthCheck.ps1').read_text(encoding='utf-8-sig').splitlines():
    if line.startswith('$script:ToolVersion'):
        version = line.split('"')[1]
        break
assert version, 'tool version not found'
TOP = f'NetworkHealthCheck-{version}'
OUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(f'{TOP}.zip')

tracked = git('ls-files', 'healthcheck').split('\n')
files = sorted(p[len('healthcheck/'):] for p in (x.strip() for x in tracked) if p)
assert files and not any(f.startswith('Reports/') or '/Reports/' in f for f in files)
missing = [f for f in files if not (PACKAGE / f).is_file()]
assert not missing, f'tracked but absent from the working tree: {missing}'

# The commit's own date as UTC. A ZIP entry holds six numbers and no zone, so the seconds since the epoch are
# converted here rather than by git: every git date format that renders a wall clock renders it in some machine's
# zone - the committer's, or with -local the builder's - and a stamp that moves with the builder's zone is the
# defect this is fixing, one hour at a time.
commit = git('rev-parse', 'HEAD')
stamp = time.gmtime(int(git('log', '-1', '--format=%ct', commit)))[:6]
assert len(stamp) == 6 and stamp[0] >= 1980, f'unusable commit date: {stamp}'
dirty = git('status', '--porcelain', '--', 'healthcheck')
print(f'version {version}: {len(files)} tracked files')
print('commit {}: {:04d}-{:02d}-{:02d} {:02d}:{:02d}:{:02d} UTC, healthcheck/ {}'.format(
    commit[:7], *stamp, 'has uncommitted changes - this digest is not reproducible from the commit' if dirty else 'clean'))

dirs = sorted({str(pathlib.PurePosixPath(f).parent) for f in files if '/' in f})
OUT.parent.mkdir(parents=True, exist_ok=True)
if OUT.exists():
    OUT.unlink()
with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr(zipfile.ZipInfo(TOP + '/'), b'')
    for d in dirs:
        z.writestr(zipfile.ZipInfo(f'{TOP}/{d}/'), b'')
    for f in files:
        # The fields writestr fills in for a bare name, with the build clock replaced by the commit's date: deflate
        # (a ZipInfo of its own defaults to STORED, which would quietly triple the asset) and the same 0o600.
        entry = zipfile.ZipInfo(f'{TOP}/{f}', stamp)
        entry.compress_type = zipfile.ZIP_DEFLATED
        entry.external_attr = 0o600 << 16
        z.writestr(entry, (PACKAGE / f).read_bytes())

digest = hashlib.sha256(OUT.read_bytes()).hexdigest()
print(f'{OUT.name}: {OUT.stat().st_size} bytes')
print(f'SHA256: {digest}')
crlf = [f for f in files if f.endswith(('.ps1', '.cmd', '.config.json'))]
bad = [f for f in crlf if b'\n' in (PACKAGE / f).read_bytes().replace(b'\r\n', b'')]
print(f'CRLF files packaged: {len(crlf)}, with a stray LF: {len(bad)}')
assert not bad, bad
