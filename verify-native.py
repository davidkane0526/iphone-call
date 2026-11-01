"""Reject legacy/unversioned ABI artifacts before any iPhone deployment."""
import hashlib
import json
from pathlib import Path
import struct
import sys


def inspect(path, expected_type):
    blob = path.read_bytes()
    if len(blob) < 32:
        raise ValueError('invalid_macho_size')
    magic, cpu, subtype, filetype, count, command_bytes, flags, _ = struct.unpack_from('<8I', blob)
    if magic != 0xfeedfacf or cpu != 0x0100000c or filetype != expected_type:
        raise ValueError('native_arm64e_device_macho_required')
    if subtype & 0xff != 2 or not subtype & 0x80000000:
        raise ValueError('versioned_arm64e_abi_required_legacy_binary_rejected')
    if (subtype >> 24) & 0x3f != 0:
        raise ValueError('unsupported_ptrauth_abi_version_for_target_device')
    if subtype & 0x40000000:
        raise ValueError('kernel_ptrauth_abi_is_not_a_user_process_binary')
    if 32 + command_bytes > len(blob):
        raise ValueError('invalid_load_command_region')
    minimum = None
    offset = 32
    for _ in range(count):
        if offset + 8 > len(blob):
            raise ValueError('invalid_load_command')
        command, size = struct.unpack_from('<II', blob, offset)
        if size < 8 or offset + size > len(blob):
            raise ValueError('invalid_load_command_size')
        if command == 0x32:
            if size < 24:
                raise ValueError('invalid_build_version_command')
            platform, minimum = struct.unpack_from('<II', blob, offset + 8)
            if platform != 2:
                raise ValueError('ios_device_platform_required')
        elif command == 0x25:
            if size < 16:
                raise ValueError('invalid_minimum_os_command')
            minimum = struct.unpack_from('<I', blob, offset + 8)[0]
        offset += size
    if offset != 32 + command_bytes:
        raise ValueError('inconsistent_load_command_region')
    if minimum is None or minimum > 0x00100301:
        raise ValueError('binary_deployment_target_exceeds_ios_16_3_1')
    return {'file': path.name, 'sha256': hashlib.sha256(blob).hexdigest(),
            'cpu_subtype': hex(subtype), 'minimum_os_raw': hex(minimum),
            'native_versioned_arm64e': True}


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: verify-native.py library.dylib native-smoke-executable')
    result = [inspect(Path(sys.argv[1]), 6), inspect(Path(sys.argv[2]), 2)]
    output = Path(sys.argv[1]).parent / 'NATIVE_ABI_MANIFEST.json'
    output.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps({'native_abi_metadata_check': 'passed', 'device_test': 'not_run'}))
