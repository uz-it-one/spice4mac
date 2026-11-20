#!/usr/bin/env python3
"""Build pinned upstream SPICE client without GTK; never installs globally."""
import hashlib, json, os, pathlib, re, subprocess, sys, tarfile, urllib.request
os.environ['PATH'] = '/opt/homebrew/bin:' + os.environ.get('PATH', '')
ROOT = pathlib.Path(__file__).resolve().parents[1]
WORK = ROOT / '.build-native'
PREFIX = WORK / 'prefix'
LOCK = json.loads((ROOT / 'Dependencies/native-lock.json').read_text())

def run(args, **kw):
    print('+', ' '.join(map(str,args)), flush=True)
    subprocess.run(list(map(str,args)), check=True, **kw)

def main():
    for d in ['sources','downloads','prefix','logs']:
        (WORK/d).mkdir(parents=True,exist_ok=True)
    for item in LOCK['archives']:
        archive = WORK/'downloads'/(item['name']+'.tar.xz')
        if not archive.exists(): urllib.request.urlretrieve(item['url'], archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != item['sha256']:
            raise RuntimeError('SHA-256 mismatch: '+item['name'])
        source = WORK/'sources'/item['name']
        if not source.exists():
            with tarfile.open(archive) as tar: tar.extractall(WORK/'sources',filter='data')
    for item in LOCK['repositories']:
        if item['name'] == 'spice-server' and '--server' not in sys.argv: continue
        source=WORK/'sources'/item['name']
        if not (source/'.git').exists():
            run(['git','clone','--no-checkout',item['url'],source])
        run(['git','-C',source,'checkout','--detach',item['commit']])
        if (source/'.gitmodules').exists(): run(['git','-C',source,'submodule','update','--init','--recursive'])
    venv=WORK/'venv'
    if not (venv/'bin/python3').exists(): run([sys.executable,'-m','venv',venv])
    run([venv/'bin/pip','install','pyparsing==3.2.3','meson==1.10.1','ninja==1.13.0'])
    tools=WORK/'tools'
    if not (tools/'bin/bison').exists():
        source=WORK/'sources/bison-3.8.2'
        run(['./configure','--prefix='+str(tools),'--disable-nls'],cwd=source)
        run(['make','-j8'],cwd=source)
        run(['make','install'],cwd=source)
    if not (tools/'bin/pkgconf').exists():
        source=WORK/'sources/pkgconf-2.3.0'
        run(['./configure','--prefix='+str(tools)],cwd=source)
        run(['make','-j8'],cwd=source)
        run(['make','install'],cwd=source)
    if not (tools/'bin/pkg-config').exists(): (tools/'bin/pkg-config').symlink_to('pkgconf')
    sdk=pathlib.Path(subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip())
    zlib_header=(sdk/'usr/include/zlib.h').read_text()
    zlib_version=re.search(r'#define ZLIB_VERSION "([^"]+)"',zlib_header).group(1)
    pc=PREFIX/'lib/pkgconfig';pc.mkdir(parents=True,exist_ok=True)
    (pc/'zlib.pc').write_text('Name: zlib\nDescription: macOS SDK zlib\nVersion: '+zlib_version+'\nLibs: -lz\n')
    engine=WORK/'sources/spice-gtk'
    (engine/'.tarball-version').write_text(LOCK['spice_gtk_build_version']+'\n')
    for patch in LOCK['patches']:
        path=ROOT/patch['path']
        if hashlib.sha256(path.read_bytes()).hexdigest()!=patch['sha256']:raise RuntimeError('Patch digest mismatch')
        applied=subprocess.run(['git','-C',str(engine),'apply','--reverse','--check',str(path)],capture_output=True).returncode==0
        if not applied:run(['git','-C',engine,'apply',path])
    env=os.environ.copy()
    env.update(PATH=str(tools/'bin')+':'+str(venv/'bin')+':'+env['PATH'], MACOSX_DEPLOYMENT_TARGET=LOCK['deployment_target'],
               PKG_CONFIG_PATH=str(PREFIX/'lib/pkgconfig')+':'+str(PREFIX/'share/pkgconfig')+':/opt/homebrew/opt/openssl@3/lib/pkgconfig:/opt/homebrew/opt/libffi/lib/pkgconfig:/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig',
               CFLAGS='-arch arm64 -mmacosx-version-min=26.0', LDFLAGS='-arch arm64 -mmacosx-version-min=26.0 -lobjc', CXXFLAGS='-arch arm64 -mmacosx-version-min=26.0')
    jobs=[('spice-protocol',[]),('json-glib-1.10.0',['-Dintrospection=disabled','-Ddocumentation=disabled','-Dtests=false']),
          ('gstreamer-1.26.0',['-Dintrospection=disabled','-Dtests=disabled','-Dexamples=disabled','-Dbenchmarks=disabled','-Dgst_debug=false','-Dnls=disabled']),
          ('gst-plugins-base-1.26.0',['-Dintrospection=disabled','-Dtests=disabled','-Dexamples=disabled','-Dgl=disabled','-Dorc=disabled','-Dnls=disabled']),
          ('spice-gtk',['-Dgtk=disabled','-Dwayland-protocols=disabled','-Dwebdav=disabled','-Dusbredir=disabled','-Dlibcap-ng=disabled','-Dpolkit=disabled','-Dintrospection=disabled','-Dvapi=disabled','-Dsasl=disabled','-Dsmartcard=disabled','-Degl=disabled','-Dgtk_doc=disabled','-Dcoroutine=gthread','-Dlz4=disabled'])]
    if '--server' in sys.argv:
        jobs.append(('spice-server',['-Dgstreamer=no','-Dsasl=false','-Dsmartcard=disabled','-Dmanual=false','-Dtests=false','-Dlz4=false']))
    for name,opts in jobs:
        source=WORK/'sources'/name; build=WORK/('build-'+name)
        compile_options=['-Dc_args=-arch arm64 -mmacosx-version-min=26.0','-Dc_link_args=-arch arm64 -mmacosx-version-min=26.0 -lobjc']
        if name=='spice-server': compile_options+=['-Dcpp_args=-arch arm64 -mmacosx-version-min=26.0','-Dcpp_link_args=-arch arm64 -mmacosx-version-min=26.0']
        run(['meson','setup']+(['--reconfigure'] if (build/'meson-private/coredata.dat').exists() else [])+[build,source,'--prefix='+str(PREFIX),'--libdir=lib','--buildtype=release','--wrap-mode=nofallback','-Ddefault_library=shared']+opts+compile_options,env=env)
        run(['meson','compile','-C',build,'-j',str(min(os.cpu_count() or 4,8))],env=env)
        run(['meson','install','-C',build,'--no-rebuild'],env=env)
    print('Native prefix:',PREFIX)
if __name__=='__main__': main()
