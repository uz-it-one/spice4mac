#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. Build/native-env.sh
mkdir -p Artifacts
swift test --disable-sandbox --build-system native
meson test -C .build-native/build-spice-gtk --no-rebuild
clang Tests/Integration/spice-fixture.c $(pkg-config --cflags --libs spice-server gio-unix-2.0) -o .build-native/spice-fixture
clang -ISources/CSpiceBridge/include Sources/CSpiceBridge/bridge.c Tests/Integration/bridge-smoke.c $(pkg-config --cflags --libs spice-client-glib-2.0) -o .build-native/bridge-smoke
python3 Tests/Integration/run-integration.py
