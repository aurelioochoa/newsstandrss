#!/usr/bin/env python3
"""Check the published Cydia source, archive compatibility and immutable versions."""
import bz2
import gzip
import hashlib
import importlib.util
import io
import shutil
import struct
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("publish_cydia", ROOT / "scripts/publish-cydia.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


def main():
    control = publisher.fields((ROOT / "control").read_text())
    name = f"{control['Package']}_{control['Version']}_{control['Architecture']}.deb"
    package = ROOT / "repo/debs" / name
    publisher.validate(package, control)
    members = dict(publisher.index.ar_members(package.read_bytes()))
    with tarfile.open(fileobj=io.BytesIO(members['data.tar.gz']), mode='r:gz') as archive:
        files = {item.name.lstrip('./'): item for item in archive.getmembers()}
        for path in ['Library/MobileSubstrate/DynamicLibraries/NewsstandRSS.dylib',
                     'Library/NewsstandRSS/Reader.app/Reader', 'usr/libexec/newsstandrss-helper']:
            binary = archive.extractfile(files[path]).read()
            magic, cpu, subtype, _, count, _, _ = struct.unpack_from('<7I', binary)
            assert (magic, cpu, subtype) == (0xFEEDFACE, 12, 9), f'{path}: expected armv7'
            offset, minimum = 28, None
            for _ in range(count):
                command, size = struct.unpack_from('<2I', binary, offset)
                if command == 0x25:
                    minimum = struct.unpack_from('<I', binary, offset + 8)[0]
                offset += size
            assert minimum == 0x60000, f'{path}: expected iOS 6.0 deployment target'
        helper = files['usr/libexec/newsstandrss-helper']
        assert helper.mode & 0o7777 == 0o4755 and helper.uid == 0
        for path in ['DEBIAN/postinst', 'DEBIAN/prerm']:
            with tarfile.open(fileobj=io.BytesIO(members['control.tar.gz']), mode='r:gz') as admin:
                assert any(item.name.lstrip('./') == path.split('/')[-1] and item.mode & 0o111
                           for item in admin.getmembers()), f'{path}: executable maintainer script missing'
    indexes = ROOT / 'repo'
    packages = (indexes / 'Packages').read_bytes()
    assert gzip.decompress((indexes / 'Packages.gz').read_bytes()) == packages
    assert bz2.decompress((indexes / 'Packages.bz2').read_bytes()) == packages
    stanza = next(publisher.fields(text) for text in packages.decode().strip().split('\n\n')
                  if publisher.fields(text)['Version'] == control['Version'])
    assert stanza['Filename'] == f'debs/{name}'
    assert int(stanza['Size']) == package.stat().st_size
    assert stanza['SHA256'] == hashlib.sha256(package.read_bytes()).hexdigest()
    assert 'firmware (>= 6.0)' in stanza['Depends'] and 'firmware (<< 7.0)' in stanza['Depends']
    url = 'https://aurelioochoa.github.io/newsstandrss/repo/'
    assert control['Depiction'] == url and control['Icon'] == url + 'CydiaIcon.png'
    assert url in (ROOT / 'README.md').read_text() and url in (indexes / 'index.html').read_text()
    assert (ROOT / '.nojekyll').is_file() and (indexes / 'CydiaIcon.png').read_bytes().startswith(b'\x89PNG')
    with tempfile.TemporaryDirectory(prefix='nrss-cydia-') as directory:
        scratch = Path(directory)
        shutil.copytree(indexes, scratch / 'repo')
        (scratch / 'repo/Packages').write_bytes(packages + b'broken index\n')
        result = subprocess.run(['python3', str(ROOT / 'scripts/cydia-index.py'), str(scratch / 'repo'), '--check'],
                                capture_output=True)
        assert result.returncode != 0, 'Corrupted index was accepted'
        (scratch / 'control').write_text((ROOT / 'control').read_text())
        (scratch / 'packages').mkdir()
        # A rebuilt archive can differ without changing its metadata. Never overwrite the published bytes.
        rebuilt = bytearray(package.read_bytes())
        rebuilt[24:36] = b'1'.ljust(12, b' ')
        assert rebuilt != package.read_bytes()
        (scratch / 'packages' / name).write_bytes(rebuilt)
        publisher.ROOT = scratch
        publisher.main()
        assert (scratch / 'repo/debs' / name).read_bytes() == package.read_bytes()
    print('CYDIA_REPO_CHECK_PASSED: release, iOS 6 archives, indexes, URLs and immutable versions')


if __name__ == '__main__':
    main()
