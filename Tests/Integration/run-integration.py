#!/usr/bin/env python3
"""Real libspice-server TCP/TLS integration. All listeners bind loopback only."""
import hashlib,json,os,pathlib,socket,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[2]
WORK=ROOT/'.build-native';OUT=ROOT/'Artifacts';OPENSSL='/opt/homebrew/opt/openssl@3/bin/openssl'
RESULTS=[]
def port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def run(name,args,expected=0,env=None):
    p=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=90)
    (OUT/(name+'.log')).write_text(p.stdout+p.stderr)
    ok=p.returncode==expected
    RESULTS.append({'name':name,'passed':ok,'exit':p.returncode,'expected':expected})
    if not ok:raise RuntimeError(name+': '+p.stdout+p.stderr)
    return p
processes=[]
def server(name,cert=None,env=None):
    p=port();log=open(OUT/(name+'-server.log'),'w');args=[WORK/'spice-fixture',str(p)]
    if cert:args += [cert,cert,cert.with_suffix('.key')]
    child=subprocess.Popen(list(map(str,args)),cwd=ROOT,env=env,stdout=log,stderr=log);processes.append((child,log))
    for _ in range(50):
        if child.poll() is not None:raise RuntimeError('Server failed '+name)
        if 'ready' in (OUT/(name+'-server.log')).read_text():return p
        time.sleep(.1)
    raise RuntimeError('Server timeout')
try:
    OUT.mkdir(exist_ok=True)
    pki=WORK/'integration-pki';pki.mkdir(exist_ok=True)
    for name,san in [('valid','IP:127.0.0.1,DNS:localhost'),('wrong','DNS:wrong.invalid')]:
        run('generate-'+name,[OPENSSL,'req','-x509','-newkey','rsa:2048','-nodes','-keyout',pki/(name+'.key'),'-out',pki/(name+'.pem'),'-days','2','-subj','/CN='+('localhost' if name=='valid' else 'wrong.invalid'),'-addext','subjectAltName='+san])
        os.chmod(pki/(name+'.key'),0o600)
    plain=server('plain')
    run('plain-frame-input',[WORK/'bridge-smoke',plain])
    log=(OUT/'plain-server.log').read_text()
    assert all(t in log for t in ['key 30','key 158','pointer 42 84','wheel 0 buttons 1']),log
    RESULTS.append({'name':'input-roundtrip','passed':True})
    env=os.environ.copy();env['SPICE_SMOKE_CYCLES']='100'
    run('100-connect-disconnect',[WORK/'bridge-smoke',plain],env=env)
    tls=server('tls',pki/'valid.pem')
    run('tls-valid-ca',[WORK/'bridge-smoke',tls,pki/'valid.pem'])
    run('tls-wrong-ca',[WORK/'bridge-smoke',tls,pki/'wrong.pem'],expected=2)
    run('tls-valid-subject',[WORK/'bridge-smoke',tls,pki/'valid.pem','CN=localhost'])
    run('tls-wrong-subject',[WORK/'bridge-smoke',tls,pki/'valid.pem','CN=wrong.invalid'],expected=2)
    wrong=server('wrong-host',pki/'wrong.pem')
    run('tls-wrong-host',[WORK/'bridge-smoke',wrong,pki/'wrong.pem'],expected=2)
    secretEnv=os.environ.copy();secretEnv['SPICE_FIXTURE_TICKET']='fixture-only-ticket'
    protected=server('ticket',env=secretEnv)
    run('ticket-valid',[WORK/'bridge-smoke',protected],env=secretEnv)
    run('ticket-rejected',[WORK/'bridge-smoke',protected],expected=2)
    run('connection-refused',[WORK/'bridge-smoke',port()],expected=2)
finally:
    for process,log in processes:
        process.terminate()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill();process.wait()
        log.close()
    (OUT/'integration-results.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
print(json.dumps(RESULTS,indent=2))
