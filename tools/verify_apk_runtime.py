#!/usr/bin/env python3
"""Provision and verify that an APK redistributes the original API binary without stripping."""
from __future__ import annotations
import argparse
import base64
import binascii
import os
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent.parent
ABIS = ('armeabi-v7a', 'arm64-v8a', 'x86_64')


def runtime_path(abi: str, root: Path = ROOT) -> Path:
    return root / 'android/app/src/main/jniLibs' / abi / 'libcpp.so'


def provision(
    abi: str,
    root: Path = ROOT,
    encoded: str | None = None,
    *,
    allow_missing: bool = False,
) -> bool:
    target = runtime_path(abi, root)
    payload = (encoded if encoded is not None else os.environ.get('ANDROID_API_RUNTIME_BASE64', '')).strip()
    if payload:
        try:
            data = base64.b64decode(payload, validate=True)
        except binascii.Error as error:
            raise ValueError(f'{abi}: invalid base64 in ANDROID_API_RUNTIME_BASE64') from error
        if not data.startswith(b'\x7fELF'):
            raise ValueError(f'{abi}: decoded runtime is not an ELF binary')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        return True
    if target.is_file():
        if target.stat().st_size <= 0:
            raise ValueError(f'{abi}: {target.relative_to(root)} is empty')
        return True
    if allow_missing:
        print(f'{abi}: no libcpp.so provisioned; building local-only APK without legacy online API runtime.')
        return False
    raise FileNotFoundError(
        f'Missing {target.relative_to(root)}; provide the authorized binary or set ANDROID_API_RUNTIME_ARM64_BASE64'
    )


def verify(
    apk: Path,
    abi: str,
    root: Path = ROOT,
    *,
    allow_missing_source: bool = False,
) -> bool:
    original = runtime_path(abi, root)
    with ZipFile(apk) as archive:
        names = [n for n in archive.namelist() if n.startswith('lib/') and n.endswith('/libcpp.so')]
        if not original.is_file():
            if allow_missing_source:
                if names:
                    raise ValueError(f'Unexpected API runtime packaged without source binary: {names}')
                return False
            raise FileNotFoundError(
                f'Missing {original.relative_to(root)}; cannot verify packaged API runtime in {apk}'
            )
        expected = f'lib/{abi}/libcpp.so'
        if names != [expected]:
            raise ValueError(f'Expected only the {abi} API runtime in this one-ABI APK')
        if archive.read(expected) != original.read_bytes():
            raise ValueError(f'{abi}: packaged API runtime differs from the original; check native symbol stripping')
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path, nargs='?')
    parser.add_argument('--abi', required=True, choices=ABIS)
    parser.add_argument('--provision', action='store_true', help='Materialize libcpp.so before building')
    parser.add_argument(
        '--allow-missing-source',
        action='store_true',
        help='Allow local-only CI builds when libcpp.so is not provisioned',
    )
    args = parser.parse_args()
    if args.provision:
        if args.apk is not None:
            parser.error('--provision does not accept an APK path')
        if provision(args.abi, allow_missing=args.allow_missing_source):
            print(f'{args.abi}: API runtime is present for packaging.')
        return
    if args.apk is None:
        parser.error('the following arguments are required: apk')
    if verify(args.apk, args.abi, allow_missing_source=args.allow_missing_source):
        print(f'{args.abi}: embedded API runtime is byte-for-byte unchanged.')
    else:
        print(f'{args.abi}: verified local-only APK without embedded API runtime.')


if __name__ == '__main__':
    main()
