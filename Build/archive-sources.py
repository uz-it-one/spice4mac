#!/usr/bin/env python3
"""Ship exact native dependency sources/recipes alongside binary releases."""
import hashlib,json,pathlib,re,shutil,subprocess,tarfile,tempfile,urllib.request
from version import version
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=ROOT/'.build-native'
DIST=ROOT/'dist'
def output(args):return subprocess.check_output(list(map(str,args)),text=True).strip()
def main():
    lock=json.loads((ROOT/'Dependencies/native-lock.json').read_text())
    manifest=[]
    with tempfile.TemporaryDirectory(prefix='spice4mac-sources-') as temporary:
        stage=pathlib.Path(temporary)/'dependency-sources';stage.mkdir()
        for name in ['Build','Dependencies','Patches']:
            shutil.copytree(ROOT/name,stage/name,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
        shutil.copy2(ROOT/'Brewfile',stage/'Brewfile')
        shutil.copy2(ROOT/'docs/THIRD_PARTY.md',stage/'README.md')
        archives=stage/'archives';archives.mkdir()
        for item in lock['archives']:
            src=WORK/'downloads'/(item['name']+'.tar.xz')
            assert hashlib.sha256(src.read_bytes()).hexdigest()==item['sha256']
            shutil.copy2(src,archives/src.name);manifest.append(item)
        for item in lock['repositories']:
            src=WORK/'sources'/item['name']
            if not src.exists():continue
            assert output(['git','-C',src,'rev-parse','HEAD'])==item['commit']
            dest=stage/'git-sources'/item['name'];dest.mkdir(parents=True)
            for name in output(['git','-C',src,'ls-files','--recurse-submodules']).splitlines():
                file=src/name
                if not file.is_file():continue
                target=dest/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(file,target)
            if (src/'.tarball-version').exists():shutil.copy2(src/'.tarball-version',dest/'.tarball-version')
            manifest.append(item)
        audit=json.loads((WORK/'native-audit-private.json').read_text())
        kegs=set()
        for row in audit:
            path=pathlib.Path(row['source'])
            if 'Cellar' in path.parts:
                i=path.parts.index('Cellar');kegs.add(pathlib.Path(*path.parts[:i+3]))
        kegs.add(pathlib.Path(output(['brew','--prefix','ca-certificates'])).resolve())
        cache=WORK/'source-downloads';cache.mkdir(exist_ok=True)
        def download(url, digest, dest):
            cached=cache/(digest or hashlib.sha256(url.encode()).hexdigest())
            if not cached.exists():
                print('Downloading source:',url,flush=True)
                urllib.request.urlretrieve(url,cached)
            actual=hashlib.sha256(cached.read_bytes()).hexdigest()
            if digest and actual!=digest:raise RuntimeError('Source hash mismatch: '+url)
            dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(cached,dest)
            manifest.append({'url':url,'sha256':actual,'file':str(dest.relative_to(stage))})
        for keg in sorted(kegs):
            recipe=next((keg/'.brew').glob('*.rb'))
            text=recipe.read_text();dest=stage/'homebrew'/keg.parent.name/keg.name;dest.mkdir(parents=True)
            shutil.copy2(recipe,dest/recipe.name)
            receipt=json.loads((keg/'INSTALL_RECEIPT.json').read_text())
            tap=receipt['source']['tap_git_head']
            # Quoted URL followed by SHA before another URL: stable source and resources/patches.
            pairs=re.findall(r'^\s*url "([^"\n]+)"(?:(?!^\s*url ).)*?^\s*sha256 "([0-9a-f]{64})"',text,re.M|re.S)
            if not pairs:raise RuntimeError('No auditable source URL: '+recipe.name)
            for n,(url,digest) in enumerate(pairs):
                if '#{' in url:raise RuntimeError('Interpolated source URL requires explicit handling')
                filename=url.split('?')[0].rstrip('/').split('/')[-1]
                download(url,digest,dest/(str(n)+'-'+filename))
            for patch in re.findall(r'^\s*file "(Patches/[^"\n]+)"',text,re.M):
                download('https://raw.githubusercontent.com/Homebrew/homebrew-core/'+tap+'/'+patch,None,dest/patch)
        (stage/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        target=DIST/('Spice4Mac-'+version()+'-dependency-sources.tar.gz')
        with tarfile.open(target,'w:gz') as tar:tar.add(stage,arcname=stage.name)
        print('Created',target)
if __name__=='__main__':main()
