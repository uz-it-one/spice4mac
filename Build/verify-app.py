#!/usr/bin/env python3
"""Verify the ZIP is self-contained and contains no test/audit JSON."""
import hashlib,pathlib,plistlib,subprocess,tempfile,zipfile
from version import version
ROOT=pathlib.Path(__file__).resolve().parents[1]

def output(*args):return subprocess.check_output(list(map(str,args)),text=True).strip()
def main():
    archive=ROOT/'dist'/f'Spice4Mac-{version()}-arm64.zip'
    with zipfile.ZipFile(archive) as zip:
        assert not any(name.endswith('.json') for name in zip.namelist()), 'Unexpected JSON in ZIP'
        assert not any('dependency-sources' in name for name in zip.namelist())
    with tempfile.TemporaryDirectory(prefix='spice4mac-standalone-') as temporary:
        subprocess.run(['ditto','-x','-k',str(archive),temporary],check=True)
        folder=pathlib.Path(temporary)/archive.stem
        app=folder/'Spice4Mac.app';cli=folder/'spice4mac'
        for binary in [cli,app]:subprocess.run(['codesign','--verify','--deep','--strict',str(binary)],check=True)
        assert output(cli,'--version')=='spice4mac '+version()
        assert (folder/'README.md').read_bytes()==(ROOT/'README.md').read_bytes()
        assert (folder/'LICENSE').read_bytes()==(ROOT/'LICENSE').read_bytes()
        frameworks=app/'Contents/Frameworks'
        binaries=[cli,app/'Contents/MacOS/Spice4MacApp',*app.rglob('*.dylib')]
        for binary in binaries:
            for line in output('otool','-L',binary).splitlines()[1:]:
                dep=line.strip().split(' (compatibility')[0]
                if dep.startswith(('/System/','/usr/lib/')):continue
                assert dep.startswith('@rpath/'),f'External dependency: {binary.name}: {dep}'
                name=dep.removeprefix('@rpath/')
                assert (frameworks/name).is_file() or (binary.name==name and binary.suffix=='.dylib'),dep
        print(f'Standalone ZIP verified: {len(binaries)} Mach-O files; no external third-party paths or JSON')
if __name__=='__main__':main()
