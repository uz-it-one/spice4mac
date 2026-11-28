#!/usr/bin/env python3
"""Run the extracted ZIP with Homebrew and the development prefix inaccessible."""
import json,pathlib,socket,subprocess,tempfile,time,sys
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Build'))
from version import version
with socket.socket() as socket:
    socket.bind(('127.0.0.1',0));port=socket.getsockname()[1]
with tempfile.TemporaryDirectory(prefix='spice4mac-isolated-') as temporary:
    folder=pathlib.Path(temporary)
    subprocess.run(['ditto','-x','-k',str(ROOT/'dist'/f'Spice4Mac-{version()}-arm64.zip'),temporary],check=True)
    package=folder/f'Spice4Mac-{version()}-arm64'
    # Deny the prefix both as spelled and as resolved, so a symlinked prefix cannot leak through.
    prefixes={str(ROOT/'.build-native/prefix'),str((ROOT/'.build-native/prefix').resolve())}
    profile='(version 1)(allow default)(deny file-read* (subpath "/opt/homebrew")'+''.join(' (subpath '+json.dumps(p)+')' for p in sorted(prefixes))+')'
    with (folder/'server.log').open('w') as log:
        server=subprocess.Popen([str(ROOT/'.build-native/spice-fixture'),str(port)],stdout=log,stderr=log)
        try:
            time.sleep(.3)
            result=subprocess.run(['/usr/bin/sandbox-exec','-p',profile,str(package/'spice4mac'),'--app',str(package/'Spice4Mac.app'),'--host','127.0.0.1','--port',str(port),'--insecure','--timeout','10','--screenshot',str(folder/'frame.png'),'--exit-after-connect'],capture_output=True,text=True,timeout=20)
            assert result.returncode==0,result.stdout+result.stderr
            assert '"event":"frame"' in result.stdout,result.stdout
            assert (folder/'frame.png').is_file()
            print('PASS: extracted app and CLI connected and saved a frame with Homebrew and development libraries denied')
        finally:
            server.terminate()
            try:server.wait(timeout=3)
            except subprocess.TimeoutExpired:server.kill();server.wait()
