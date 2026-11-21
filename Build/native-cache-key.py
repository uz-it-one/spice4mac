#!/usr/bin/env python3
"""Invalidate native binaries when toolchain, Homebrew versions or paths change."""
import hashlib,json,os,pathlib,platform,subprocess,sys

def output(*args):return subprocess.check_output(args,text=True).strip()
state={
    'image':os.environ.get('ImageVersion','local'),
    'architecture':platform.machine(),
    'os':platform.mac_ver()[0],
    'workspace':str(pathlib.Path(__file__).resolve().parents[1]),
    'python':sys.version,
    'python_path':sys.executable,
    'xcode':output('xcodebuild','-version'),
    'sdk':output('xcrun','--show-sdk-version'),
    'homebrew':output('brew','list','--versions'),
}
print('key='+hashlib.sha256(json.dumps(state,sort_keys=True).encode()).hexdigest())
