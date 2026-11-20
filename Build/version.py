#!/usr/bin/env python3
"""Validate the release tag and synchronize compiled version information."""
import os, pathlib, re
ROOT=pathlib.Path(__file__).resolve().parents[1]
def version():
    value=(ROOT/'VERSION').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+',value):raise ValueError('VERSION must be MAJOR.MINOR.PATCH')
    if os.environ.get('GITHUB_REF','').startswith('refs/tags/') and os.environ['GITHUB_REF_NAME'].removeprefix('v')!=value:
        raise ValueError('Tag must match VERSION')
    return value
if __name__=='__main__':
    value=version()
    (ROOT/'Sources/ConnectionCore/AppVersion.swift').write_text('public enum AppVersion { public static let current = "'+value+'" }\n')
    print(value)
