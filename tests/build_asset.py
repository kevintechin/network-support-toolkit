"""Build the NetworkHealthCheck release asset the way the repository's packaging rule requires (healthcheck/VALIDATION.md,
"Packaging"): tracked files under healthcheck/ only, so Reports/ and every other untracked output are excluded by
construction; working-tree bytes, so the CRLF checkout is preserved; one top-level NetworkHealthCheck-<version>/ folder;
deflate. The version is read from the en-US script. Prints the size and the SHA256 that go into the release notes.

Every entry is stamped with the date of the commit the build is made from, so that the same commit gives the same
archive byte for byte (backlog #21). Without that stamp zipfile writes the build time into each file entry, which is
why four CI builds of identical content produced four digests; the directory entries were already deterministic,
because a bare ZipInfo dates from 1980, and they keep that date. The platform a ZipInfo would record - 0 on
Windows, 3 elsewhere - is pinned as well, so the archive does not depend on the host that built it either. The stamp makes the digest a fact about the commit:
built from a working tree that differs from it, the archive is what the tree says and the digest is not reproducible,
which is why the tree's state is printed beside it.

Usage (from anywhere):  python tests/build_asset.py [<out.zip>]    default: NetworkHealthCheck-<version>.zip in the current directory"""
import hashlib, pathlib, subprocess, sys, time, zipfile

EPOCH_1980 = (1980, 1, 1, 0, 0, 0)   # what a bare ZipInfo carries, and what the folder entries have always had

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


def entry_for(name, date_time):
    """A ZipInfo whose every field is chosen here rather than taken from the machine.

    ZipInfo writes the building platform into create_system - 0 on Windows and 3 everywhere else - so the central
    directory, and with it the digest, would still depend on the host that built it. It is pinned to 0, which is what
    Windows already produced, so the releases built so far keep their bytes; the side effect is that a POSIX extractor
    ignores the permission bits below and uses its own default, which is what a package extracted on Linux should get
    rather than the owner-only 0o600 those bits would impose.
    """
    entry = zipfile.ZipInfo(name, date_time)
    entry.create_system = 0
    return entry


dirs = sorted({str(pathlib.PurePosixPath(f).parent) for f in files if '/' in f})
OUT.parent.mkdir(parents=True, exist_ok=True)
if OUT.exists():
    OUT.unlink()
with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED) as z:
    # The folder entries keep the 1980 a bare ZipInfo carries: they were already the same in every build, and moving
    # them would change the bytes of every asset for nothing.
    z.writestr(entry_for(TOP + '/', EPOCH_1980), b'')
    for d in dirs:
        z.writestr(entry_for(f'{TOP}/{d}/', EPOCH_1980), b'')
    for f in files:
        # The fields writestr fills in for a bare name, with the build clock replaced by the commit's date: deflate
        # (a ZipInfo of its own defaults to STORED, which would quietly triple the asset) and the same 0o600.
        entry = entry_for(f'{TOP}/{f}', stamp)
        entry.compress_type = zipfile.ZIP_DEFLATED
        entry.external_attr = 0o600 << 16
        z.writestr(entry, (PACKAGE / f).read_bytes())

# What the archive claims about itself, read back from the archive: every entry made by the same platform, every file
# stamped with the commit, every folder with the 1980 they have always had.
with zipfile.ZipFile(OUT) as z:
    systems = sorted({i.create_system for i in z.infolist()})
    file_stamps = sorted({i.date_time for i in z.infolist() if not i.filename.endswith('/')})
    dir_stamps = sorted({i.date_time for i in z.infolist() if i.filename.endswith('/')})
assert systems == [0], f'create_system varies: {systems}'
assert file_stamps == [tuple(stamp)], f'file entries carry more than the commit date: {file_stamps}'
assert dir_stamps == [EPOCH_1980], f'folder entries are not the constant date: {dir_stamps}'

digest = hashlib.sha256(OUT.read_bytes()).hexdigest()
print(f'{OUT.name}: {OUT.stat().st_size} bytes')
print(f'SHA256: {digest}')
crlf = [f for f in files if f.endswith(('.ps1', '.cmd', '.config.json'))]
bad = [f for f in crlf if b'\n' in (PACKAGE / f).read_bytes().replace(b'\r\n', b'')]
print(f'CRLF files packaged: {len(crlf)}, with a stray LF: {len(bad)}')
assert not bad, bad
