#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
probe_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p build dist
perl tooling/logos/bin/logos.pl Tweak.xm > build/Tweak.mm
xcrun --sdk iphoneos clang++ -arch arm64e -isysroot "$probe_sdk" \
    -miphoneos-version-min=16.0 -std=c++17 -fobjc-arc -fblocks -O2 \
    -dynamiclib -framework Foundation -framework CoreFoundation -lobjc \
    -Wl,-install_name,@rpath/iPhoneRingingProbe.dylib \
    build/Tweak.mm -o dist/iPhoneRingingProbe.dylib
xcrun --sdk iphoneos clang -arch arm64e -isysroot "$probe_sdk" \
    -miphoneos-version-min=16.0 -O2 NativeSmoke.c -o dist/iPhoneRingingNativeSmoke
codesign --force --sign - dist/iPhoneRingingProbe.dylib
xcrun --sdk iphoneos clang -arch arm64e -isysroot "$probe_sdk" \
    -miphoneos-version-min=16.0 -O2 -dynamiclib -DIF_BOOTSTRAP_LIBRARY \
    '-DIF_PROBE_TARGET_PATH="/var/jb/var/mobile/iphone-forward-build/ringing-events-d002e19b/iPhoneRingingProbe.dylib"' \
    -Wl,-install_name,@rpath/iPhoneRingingBootstrap.dylib \
    NativeSmoke.c -o dist/iPhoneRingingBootstrap.dylib
codesign --force --sign - dist/iPhoneRingingNativeSmoke
codesign --force --sign - dist/iPhoneRingingBootstrap.dylib
codesign --verify --strict dist/iPhoneRingingProbe.dylib
codesign --verify --strict dist/iPhoneRingingNativeSmoke
codesign --verify --strict dist/iPhoneRingingBootstrap.dylib
python3 verify-native.py dist/iPhoneRingingProbe.dylib dist/iPhoneRingingNativeSmoke dist/iPhoneRingingBootstrap.dylib
shasum -a 256 dist/iPhoneRingingProbe.dylib dist/iPhoneRingingNativeSmoke dist/iPhoneRingingBootstrap.dylib > dist/SHA256SUMS
xcodebuild -version > dist/XCODE_VERSION.txt
printf 'Build complete. Device ABI and loading tests are still required.\n'
