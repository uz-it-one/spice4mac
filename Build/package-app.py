#!/usr/bin/env python3
"""Assemble a relocatable development app; audit and ad-hoc sign every Mach-O."""
import hashlib,json,os,pathlib,plistlib,re,shutil,subprocess
from version import version
ROOT=pathlib.Path(__file__).resolve().parents[1]
DIST=ROOT/'dist'; APP=DIST/'Spice4Mac.app'; FW=APP/'Contents/Frameworks'; RES=APP/'Contents/Resources'
def run(args): return subprocess.check_output(list(map(str,args)),text=True,stderr=subprocess.STDOUT)
def dependencies(path):
    return [line.strip().split(' (compatibility')[0] for line in run(['otool','-L',path]).splitlines()[1:]]
def system(path):return path.startswith('/System/') or path.startswith('/usr/lib/')
def rpaths(path):return re.findall(r'cmd LC_RPATH\n.*?path (.*?) \(offset',run(['otool','-l',path]),re.S)
def resolve(dep,owner):
    if dep.startswith('@loader_path/'):return owner.parent/dep[len('@loader_path/'):]
    if dep.startswith('@rpath/'):
        for p in rpaths(owner)+[str(ROOT/'.build-native/prefix/lib'),'/opt/homebrew/lib']:
            p=p.replace('@loader_path',str(owner.parent)).replace('@executable_path',str(ROOT/'.build/release'))
            candidate=pathlib.Path(p)/dep[len('@rpath/'):]
            if candidate.exists():return candidate
        raise RuntimeError('Unresolved '+dep+' from '+str(owner))
    return pathlib.Path(dep)
def main():
    if APP.exists():shutil.rmtree(APP)
    for p in [APP/'Contents/MacOS',FW,RES]:p.mkdir(parents=True,exist_ok=True)
    binary=ROOT/'.build/release/Spice4MacApp'; target=APP/'Contents/MacOS/Spice4MacApp';shutil.copy2(binary,target)
    queue=[(binary,target)];mapped={};audit=[]
    # Core/app/video conversion plugins enable baseline GStreamer streams. MJPEG also has the built-in SPICE decoder.
    pluginpath=ROOT/'.build-native/prefix/lib/gstreamer-1.0'
    for name in ['libgstcoreelements.dylib','libgstapp.dylib','libgstvideoconvertscale.dylib','libgstplayback.dylib','libgsttypefindfunctions.dylib']:
        src=pluginpath/name
        if src.exists():
            dest=RES/'gstreamer-1.0'/name;dest.parent.mkdir(exist_ok=True);shutil.copy2(src,dest);queue.append((src,dest))
    for original,dest in queue:
        dest.chmod(dest.stat().st_mode | 0o200)
        for dep in dependencies(original):
            if system(dep):continue
            src=resolve(dep,original).resolve()
            if src==original.resolve():continue
            name=src.name
            if name in mapped and mapped[name]!=src:raise RuntimeError('Library basename collision: '+name)
            if name not in mapped:
                mapped[name]=src;copy=FW/name;shutil.copy2(src,copy);queue.append((src,copy))
            run(['install_name_tool','-change',dep,'@rpath/'+name,dest])
        if dest.suffix=='.dylib':run(['install_name_tool','-id','@rpath/'+dest.name,dest])
        for rpath in set(rpaths(dest)):
            if rpath.startswith('/opt/') or str(ROOT) in rpath:run(['install_name_tool','-delete_rpath',rpath,dest])
        if dest==target:run(['install_name_tool','-add_rpath','@executable_path/../Frameworks',dest])
        if dest.parent.name=='gstreamer-1.0':run(['install_name_tool','-add_rpath','@loader_path/../../Frameworks',dest])
        load=run(['otool','-l',dest]);versions=re.findall(r'\bminos ([\d.]+)',load)
        arch=run(['lipo','-archs',dest]).strip()
        if 'arm64' not in arch:raise RuntimeError('Not arm64: '+str(dest))
        audit.append({'file':str(dest.relative_to(APP)),'source':str(original),'architectures':arch,'minimum_os':versions,'sha256_source':hashlib.sha256(original.read_bytes()).hexdigest()})
        run(['strip','-S',dest])
        run(['codesign','--force','--sign','-',dest])
    minimum=max(['26.0']+[v for row in audit for v in row['minimum_os']],key=lambda s:tuple(map(int,s.split('.'))))
    info={'CFBundleExecutable':'Spice4MacApp','CFBundleIdentifier':'org.spice4mac.client','CFBundleName':'Spice4Mac','CFBundleDisplayName':'Spice4Mac','CFBundlePackageType':'APPL','CFBundleShortVersionString':version(),'CFBundleVersion':version(),'LSMinimumSystemVersion':minimum,'NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication'}
    (APP/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    # Bundle CA roots explicitly; OpenSSL's Homebrew default path is not portable.
    ca=pathlib.Path('/opt/homebrew/etc/ca-certificates/cert.pem')
    if ca.exists():shutil.copy2(ca,RES/'ca-bundle.pem')
    licenses=RES/'Licenses';licenses.mkdir(exist_ok=True)
    for name in ['spice-gtk','spice-protocol','gstreamer-1.26.0','gst-plugins-base-1.26.0','json-glib-1.10.0']:
        folder=ROOT/'.build-native/sources'/name
        for filename in ['COPYING','LICENSE','COPYING.LIB']:
            if (folder/filename).exists():shutil.copy2(folder/filename,licenses/(name+'-'+filename))
    for lib in mapped.values():
        parts=lib.parts
        if 'Cellar' in parts:
            n=parts.index('Cellar');keg=pathlib.Path(*parts[:n+3])
            for f in keg.iterdir():
                if f.is_file() and ('LICENSE' in f.name.upper() or 'COPYING' in f.name.upper()):shutil.copy2(f,licenses/(parts[n+1]+'-'+f.name))
    (ROOT/'.build-native/native-audit-private.json').write_text(json.dumps(audit,indent=2)+'\n')
    audit=[{**{k:v for k,v in row.items() if k!='source'},'source_name':pathlib.Path(row['source']).name} for row in audit]
    (RES/'native-audit.json').write_text(json.dumps(audit,indent=2)+'\n')
    shutil.copy2(ROOT/'Dependencies/native-lock.json',RES/'native-lock.json')
    shutil.copy2(ROOT/'LICENSE',RES/'LICENSE-Spice4Mac')
    shutil.copy2(ROOT/'docs/THIRD_PARTY.md',RES/'THIRD_PARTY.md')
    run(['codesign','--force','--sign','-',APP])
    run(['codesign','--verify','--deep','--strict',APP])
    shutil.copy2(ROOT/'.build/release/spice4mac',DIST/'spice4mac');run(['strip','-S',DIST/'spice4mac']);run(['codesign','--force','--sign','-',DIST/'spice4mac'])
    for _,dest in queue:
        if any(not system(d) and not d.startswith('@rpath/') for d in dependencies(dest)):raise RuntimeError('Non-relocatable dependency: '+str(dest))
    (DIST/'native-audit.json').write_text(json.dumps({'minimum_os':minimum,'binaries':audit},indent=2)+'\n')
    print('Packaged',APP,'minimum OS',minimum,'native libraries',len(mapped))
if __name__=='__main__':main()
