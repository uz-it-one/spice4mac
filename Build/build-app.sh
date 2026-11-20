#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. Build/native-env.sh
python3 Build/version.py
swift build -c release --disable-sandbox --build-system native -Xswiftc -file-prefix-map -Xswiftc "$PWD=." -Xswiftc -debug-prefix-map -Xswiftc "$PWD=." -Xcc "-ffile-prefix-map=$PWD=."
python3 Build/package-app.py
