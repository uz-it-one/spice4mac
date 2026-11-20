#!/usr/bin/env python3
import hashlib,json,pathlib
from version import version
ROOT=pathlib.Path(__file__).resolve().parents[1]
dist=ROOT/'dist';v=version()
assets=[dist/f'Spice4Mac-{v}-arm64.zip',dist/f'Spice4Mac-{v}-dependency-sources.tar.gz',dist/'native-audit.json']
(dist/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in assets))
