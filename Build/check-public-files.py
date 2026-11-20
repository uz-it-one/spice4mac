#!/usr/bin/env python3
"""Check the actual Git index as well as ignore rules before publication."""
import pathlib,re,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[1]
files=subprocess.check_output(['git','ls-files','-z'],cwd=ROOT).decode().split('\0')
files=[name for name in files if name]
private_prefixes=('.build/','.build-native/','dist/','Artifacts/','.codex/','.agents/','.idea/','.vscode/','docs/research/')
secret=re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}')
for name in files:
    if name.startswith(private_prefixes):raise SystemExit('Local material tracked: '+name)
    data=subprocess.check_output(['git','show',':'+name],cwd=ROOT)
    home_prefix=('/'+'Users'+'/').encode()
    if home_prefix in data or secret.search(data):raise SystemExit('Private path or credential pattern: '+name)
blocked=['.env','session.vv','tls.key','ca.pem','.build/test','.build-native/test','dist/test','Artifacts/test.json','.vscode/settings.json','.codex/config','.agents/notes','docs/implementation-status.md','docs/research/source-audit.md','Build/__pycache__/x.pyc']
for name in blocked:
    if subprocess.run(['git','check-ignore','--no-index','-q',name],cwd=ROOT).returncode:raise SystemExit('Missing ignore rule: '+name)
print(f'Public file checks passed: {len(files)} tracked files, {len(blocked)} ignore rules')
