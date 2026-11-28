#!/usr/bin/env python3
"""Local animated SPICE regression, not an external guest performance benchmark."""
import json, os, pathlib, re, signal, socket, subprocess, time
ROOT=pathlib.Path(__file__).resolve().parents[2]
OUT=ROOT/'Artifacts'
with socket.socket() as s:
    s.bind(('127.0.0.1',0));port=s.getsockname()[1]
env=dict(os.environ,SPICE_FIXTURE_ANIMATE='1',SPICE4MAC_DIAGNOSTICS='1')
cpu_samples=[];rss_kb=[]
with (OUT/'display-server.log').open('w') as serverlog, (OUT/'display-client.log').open('w') as clientlog:
    server=subprocess.Popen([str(ROOT/'.build-native/spice-fixture'),str(port)],env=env,stdout=serverlog,stderr=serverlog)
    client=None
    try:
        time.sleep(.3)
        client=subprocess.Popen([str(ROOT/'dist/spice4mac'),'--host','127.0.0.1','--port',str(port),'--insecure','--fullscreen'],env=env,stdout=clientlog,stderr=clientlog,start_new_session=True)
        # Entering full screen at 4K can take several seconds; wait for it before measuring.
        deadline=time.monotonic()+20
        while time.monotonic()<deadline and '"event":"fullscreen"' not in (OUT/'display-client.log').read_text():
            assert client.poll() is None, 'Session exited before entering full screen'
            time.sleep(.1)
        time.sleep(2)
        # Sample the GUI process (the launcher's child) once per second while frames stream.
        gui=subprocess.run(['pgrep','-P',str(client.pid)],capture_output=True,text=True).stdout.split()
        for _ in range(5):
            if gui:
                ps=subprocess.run(['ps','-o','%cpu=,rss=','-p',gui[0]],capture_output=True,text=True).stdout.split()
                if len(ps)==2:cpu_samples.append(float(ps[0]));rss_kb.append(int(ps[1]))
            time.sleep(1)
        assert client.poll() is None, 'Session exited during animation'
        server.terminate();server.wait(timeout=3)
        code=client.wait(timeout=10)
        assert code in (2,5), code
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
result={'mode':'rows' if os.environ.get('SPICE_FIXTURE_ROWS') else 'full-frame','size':os.environ.get('SPICE_FIXTURE_WIDTH','640')+'x'+os.environ.get('SPICE_FIXTURE_HEIGHT','480'),'fullscreen_entered':'"event":"fullscreen"' in text,'samples':samples,'steady_received_fps':sum(x[0] for x in steady)/len(steady),'steady_submitted_fps':sum(x[1] for x in steady)/len(steady),'mean_upload_ms':sum(x[2] for x in steady)/len(steady),'app_cpu_percent':sum(cpu_samples)/len(cpu_samples) if cpu_samples else None,'app_rss_mb':max(rss_kb)/1024 if rss_kb else None}
assert result['fullscreen_entered'],text
assert result['steady_received_fps']>=20 and result['steady_submitted_fps']>=20,result
# Optional, machine-specific regression guard, e.g. SPICE_DISPLAY_MAX_CPU=60.
limit=os.environ.get('SPICE_DISPLAY_MAX_CPU')
if limit:assert result['app_cpu_percent'] is not None and result['app_cpu_percent']<=float(limit),result
result['passed']=True
(OUT/'display-results.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
