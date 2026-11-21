#!/usr/bin/env python3
"""Create a draft, upload all assets, then publish; never replace a public release."""
import json,os,pathlib,subprocess,tempfile
from version import version
ROOT=pathlib.Path(__file__).resolve().parents[1]
v=version();tag=os.environ['GITHUB_REF_NAME'];repo=os.environ['GH_REPO']
assets=ROOT/'release-assets'
allowed=[assets/f'Spice4Mac-{v}-arm64.zip',assets/'SHA256SUMS']
if set(assets.iterdir())!=set(allowed):
    raise SystemExit('Unexpected release asset; only the application ZIP and checksum are allowed.')
subprocess.run(['sha256sum','--check','SHA256SUMS'],cwd=assets,check=True)
query=subprocess.run(['gh','release','view',tag,'--json','isDraft'],capture_output=True,text=True)
if query.returncode==0 and not json.loads(query.stdout)['isDraft']:
    raise SystemExit('This release is already public; refusing to overwrite its assets.')
notes=f'''Apple Silicon용 SPICE 원격 데스크톱 클라이언트 Spice4Mac {v}입니다.

- macOS 26 이상, Apple Silicon 전용
- SwiftUI/AppKit, Metal 화면 표시, 전체 화면 자동 숨김 UI
- TLS·ticket·.vv 연결, 클립보드·오디오·자동 해상도
- GUI와 함께 실행·종료되는 CLI 및 스크린샷 자동화

`Spice4Mac-{v}-arm64.zip`에는 앱과 CLI가 포함됩니다.
현재 ad-hoc 서명이며 Apple 공증은 받지 않았습니다.
단일 화면을 지원하며 USB·마이크·파일 공유·SASL·다중 모니터는 지원하지 않습니다.

자체 코드는 MIT, 외부 라이브러리는 각자의 라이선스를 따릅니다.
실행에 필요한 라이브러리는 앱 안에 포함되어 별도 설치가 필요하지 않습니다.
ZIP과 SHA256SUMS를 제공합니다.

Build commit: {os.environ['GITHUB_SHA']}
'''
with tempfile.NamedTemporaryFile(mode='w',suffix='.md') as file:
    file.write(notes);file.flush()
    if query.returncode!=0:
        subprocess.run(['gh','release','create',tag,'--verify-tag','--draft','--title','Spice4Mac '+v,'--notes-file',file.name],check=True)
    subprocess.run(['gh','release','upload',tag,*map(str,allowed),'--clobber'],check=True)
    subprocess.run(['gh','release','edit',tag,'--draft=false','--notes-file',file.name],check=True)
