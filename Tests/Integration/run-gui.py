#!/usr/bin/env python3
"""Requires a logged-in graphical macOS session. Executes only the built app and localhost fixture."""
import json,os,pathlib,socket,subprocess,time,signal
ROOT=pathlib.Path(__file__).resolve().parents[2];OUT=ROOT/'Artifacts';WORK=ROOT/'.build-native';CLI=ROOT/'dist/spice4mac';APP=ROOT/'dist/Spice4Mac.app'
results=[];processes=[]
def port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def run(name,args,expected=0,input=None):
    p=subprocess.run([str(CLI),'--app',str(APP),*map(str,args)],cwd=ROOT,input=input,capture_output=True,text=True,timeout=25)
    (OUT/(name+'.log')).write_text(p.stdout+p.stderr)
    results.append({'name':name,'passed':p.returncode==expected,'exit':p.returncode,'expected':expected})
    if p.returncode!=expected:raise RuntimeError(name+': '+p.stdout+p.stderr)
def fixture(tls=False):
    p=port();args=[WORK/'spice-fixture',str(p)]
    if tls:args += [WORK/'integration-pki/valid.pem',WORK/'integration-pki/valid.pem',WORK/'integration-pki/valid.key']
    log=open(OUT/('gui-server-'+str(p)+'.log'),'w');proc=subprocess.Popen(list(map(str,args)),stdout=log,stderr=log);processes.append((proc,log));time.sleep(.3);return p
try:
    p=fixture()
    run('gui-frame',['--host','127.0.0.1','--port',p,'--insecure','--timeout','10','--screenshot',OUT/'fixture.png','--window-screenshot',OUT/'window.png','--exit-after-connect'])
    # No --wait: CLI must stay alive after the first frame, then exit with its GUI.
    lifecycle_port=fixture()
    lifecycle_server=processes[-1][0]
    lifecycle_log=OUT/'gui-cli-lifecycle.log'
    with lifecycle_log.open('w') as output:
        launcher=subprocess.Popen([str(CLI),'--app',str(APP),'--host','127.0.0.1','--port',str(lifecycle_port),'--insecure'],stdout=output,stderr=output,start_new_session=True)
        try:
            deadline=time.monotonic()+15
            while time.monotonic()<deadline and '"event":"frame"' not in lifecycle_log.read_text():
                if launcher.poll() is not None:raise RuntimeError('CLI returned before session ended')
                time.sleep(.1)
            assert '"event":"frame"' in lifecycle_log.read_text(), 'No lifecycle frame'
            time.sleep(.5)
            assert launcher.poll() is None, 'CLI failed to hold shell'
            lifecycle_server.terminate();lifecycle_server.wait(timeout=3)
            code=launcher.wait(timeout=10)
            assert code in (0,2), f'Unexpected disconnect exit: {code}'
            results.append({'name':'cli-holds-shell-and-exits-on-disconnect','passed':True,'exit':code})
        finally:
            try:os.killpg(launcher.pid,signal.SIGTERM)
            except ProcessLookupError:pass
            launcher.wait(timeout=3)
    run('gui-screenshot-failure',['--host','127.0.0.1','--port',p,'--insecure','--screenshot',ROOT/'no-such-folder/shot.png','--exit-after-connect'],3)
    t=fixture(True)
    run('gui-tls',['--host','127.0.0.1','--tls-port',t,'--ca-file',WORK/'integration-pki/valid.pem','--exit-after-connect'])
    run('gui-tls-rejected',['--host','127.0.0.1','--tls-port',t,'--ca-file',WORK/'integration-pki/wrong.pem','--exit-after-connect'],2)
    run('cli-validation-rejected',['--host','127.0.0.1','--port',p,'--exit-after-connect'],64)
    run('gui-connect-refused',['--host','127.0.0.1','--port',port(),'--insecure','--exit-after-connect'],2)
    with socket.socket() as silent:
        silent.bind(('127.0.0.1',0));silent.listen()
        run('gui-timeout',['--host','127.0.0.1','--port',silent.getsockname()[1],'--insecure','--timeout','1','--exit-after-connect'],4)
finally:
    for proc,log in processes:
        proc.terminate()
        try:proc.wait(timeout=3)
        except subprocess.TimeoutExpired:proc.kill();proc.wait()
        log.close()
    (OUT/'gui-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
