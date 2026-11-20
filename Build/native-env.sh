#!/bin/sh
# Source from repository root.
export PKG_CONFIG_PATH="$PWD/.build-native/prefix/lib/pkgconfig:$PWD/.build-native/prefix/share/pkgconfig:/opt/homebrew/opt/openssl@3/lib/pkgconfig:/opt/homebrew/opt/libffi/lib/pkgconfig:/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig"
export MACOSX_DEPLOYMENT_TARGET=26.0
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"

export PATH="/opt/homebrew/bin:$PATH"
export PATH="$PWD/.build-native/tools/bin:$PWD/.build-native/venv/bin:$PATH"
