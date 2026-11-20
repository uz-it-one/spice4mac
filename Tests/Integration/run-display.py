#!/usr/bin/env python3
"""Local animated SPICE regression, not an external guest performance benchmark."""
import json, os, pathlib, re, signal, socket, subprocess, time
ROOT=pathlib.Path(__file__).resolve().parents[2]
OUT=ROOT/'Artifacts'
with socket.socket() as s:
    s.bind(('127.0.0.1',0));port=s.getsockname()[1]
env=dict(os.environ,SPICE_FIXTURE_ANIMATE='1',SPICE4MAC_DIAGNOSTICS='1')
with (OUT/'display-server.log').open('w') as serverlog, (OUT/'display-client.log').open('w') as clientlog:
    server=subprocess.Popen([str(ROOT/'.build-native/spice-fixture'),str(port)],env=env,stdout=serverlog,stderr=serverlog)
    client=None
    try:
        time.sleep(.3)
        client=subprocess.Popen([str(ROOT/'dist/spice4mac'),'--host','127.0.0.1','--port',str(port),'--insecure','--fullscreen'],env=env,stdout=clientlog,stderr=clientlog,start_new_session=True)
        time.sleep(7)
        assert client.poll() is None, 'Session exited during animation'
        server.terminate();server.wait(timeout=3)
        code=client.wait(timeout=10)
        assert code in (0,2), code
    finally:
        if server.poll() is None:server.terminate();server.wait(timeout=3)
        if client:
            try:os.killpg(client.pid,signal.SIGTERM)
            except ProcessLookupError:pass
            client.wait(timeout=3)
text=(OUT/'display-client.log').read_text()
samples=[tuple(map(float,m)) for m in re.findall(r'display received_fps=([\d.]+) submitted_fps=([\d.]+) upload_ms=([\d.]+)',text)]
assert len(samples)>=3, text
steady=samples[1:]
result={'mode':'rows' if os.environ.get('SPICE_FIXTURE_ROWS') else 'full-frame','size':os.environ.get('SPICE_FIXTURE_WIDTH','640')+'x'+os.environ.get('SPICE_FIXTURE_HEIGHT','480'),'fullscreen_entered':'"event":"fullscreen"' in text,'samples':samples,'steady_received_fps':sum(x[0] for x in steady)/len(steady),'steady_submitted_fps':sum(x[1] for x in steady)/len(steady),'mean_upload_ms':sum(x[2] for x in steady)/len(steady)}
assert result['fullscreen_entered'],text
assert result['steady_received_fps']>=20 and result['steady_submitted_fps']>=20,result
result['passed']=True
(OUT/'display-results.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
