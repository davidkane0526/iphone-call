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
xcrun --sdk iphoneos clang -arch arm64e -isysroot "$probe_sdk" \
    -miphoneos-version-min=16.0 -O2 -fno-stack-protector -dynamiclib -DIF_STACK_STRESS_LIBRARY \
    -Wl,-install_name,@rpath/iPhoneRingingStackFixture.dylib \
    NativeSmoke.c -o dist/iPhoneRingingStackFixture.dylib
git clone --filter=blob:none https://github.com/opa334/opainject.git tooling/opainject
git -C tooling/opainject checkout 849bb296ea8bc0643a2966485ea3c3c96ebdcd5b
mkdir -p tooling/ios-private/CoreSymbolication.framework
curl --fail --location --retry 3 \
    https://raw.githubusercontent.com/theos/sdks/0222fd5413cf4b9af096f37b4621afa2688572f7/iPhoneOS13.7.sdk/System/Library/PrivateFrameworks/CoreSymbolication.framework/CoreSymbolication.tbd \
    -o tooling/ios-private/CoreSymbolication.framework/CoreSymbolication.tbd
injector_sources=(main.m dyld.m shellcode_inject.m rop_inject.m thread_utils.m task_utils.m arm64.m)
injector_paths=()
for source in "${injector_sources[@]}"; do injector_paths+=("tooling/opainject/$source"); done
build_injector() {
    xcrun --sdk iphoneos clang -arch arm64e -isysroot "$probe_sdk" \
        -miphoneos-version-min=16.0 -fobjc-arc -fblocks -O2 -DTHEOS_LEAN_AND_MEAN \
        -Itooling/opainject -Ftooling/ios-private \
        -framework Foundation -framework CoreFoundation -framework CoreSymbolication \
        "${injector_paths[@]}" -o "$1"
}
build_injector dist/iPhoneRingingInjectorControl
python3 - <<'PY'
from pathlib import Path
p = Path('tooling/opainject/thread_utils.h')
s = p.read_text()
assert s.count('#define STACK_SIZE 65536') == 1
p.write_text(s.replace('#define STACK_SIZE 65536', '#define STACK_SIZE 1048576'))
Path('dist/STACK_SIZE_BUILD_INFO.json').write_text('{"upstream_commit":"849bb296ea8bc0643a2966485ea3c3c96ebdcd5b","control_allocation":65536,"control_usable_half":32768,"fixed_allocation":1048576,"fixed_usable_half":524288}\n')
PY
build_injector dist/iPhoneRingingInjector
cp tooling/opainject/entitlements.plist dist/INJECTOR_ENTITLEMENTS.plist
cp tooling/opainject/LICENSE dist/LICENSE_opainject.txt
for binary in iPhoneRingingProbe.dylib iPhoneRingingNativeSmoke iPhoneRingingStackFixture.dylib; do
    codesign --force --sign - "dist/$binary"
    codesign --verify --strict "dist/$binary"
done
for binary in iPhoneRingingInjectorControl iPhoneRingingInjector; do
    codesign --force --sign - --entitlements dist/INJECTOR_ENTITLEMENTS.plist "dist/$binary"
    codesign --verify --strict "dist/$binary"
done
python3 verify-native.py dist/iPhoneRingingProbe.dylib dist/iPhoneRingingNativeSmoke \
    dist/iPhoneRingingStackFixture.dylib dist/iPhoneRingingInjectorControl dist/iPhoneRingingInjector
shasum -a 256 dist/iPhoneRingingProbe.dylib dist/iPhoneRingingNativeSmoke \
    dist/iPhoneRingingStackFixture.dylib dist/iPhoneRingingInjectorControl dist/iPhoneRingingInjector > dist/SHA256SUMS
xcodebuild -version > dist/XCODE_VERSION.txt
printf 'Build complete. Device ABI and loading tests are still required.\n'
