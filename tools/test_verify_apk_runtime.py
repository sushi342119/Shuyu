import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile

spec = importlib.util.spec_from_file_location('runtime', Path(__file__).with_name('verify_apk_runtime.py'))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class ApkRuntimeTest(unittest.TestCase):
    def test_original_succeeds_and_stripped_runtime_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / 'android/app/src/main/jniLibs/arm64-v8a/libcpp.so'
            original.parent.mkdir(parents=True)
            original.write_bytes(b'\x7fELForiginal-runtime-with-symbols')
            for name, data, valid in [
                ('original', original.read_bytes(), True),
                ('stripped', b'\x7fELForiginal-runtime', False),
            ]:
                apk = root / f'{name}.apk'
                with ZipFile(apk, 'w') as z:
                    z.writestr('lib/arm64-v8a/libcpp.so', data)
                if valid:
                    self.assertTrue(runtime.verify(apk, 'arm64-v8a', root))
                else:
                    with self.assertRaises(ValueError):
                        runtime.verify(apk, 'arm64-v8a', root)

    def test_wrong_or_extra_architecture_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / 'android/app/src/main/jniLibs/arm64-v8a/libcpp.so'
            original.parent.mkdir(parents=True)
            original.write_bytes(b'\x7fELFx')
            apk = root / 'wrong.apk'
            with ZipFile(apk, 'w') as z:
                z.writestr('lib/arm64-v8a/libcpp.so', b'\x7fELFx')
                z.writestr('lib/x86_64/libcpp.so', b'\x7fELFx')
            with self.assertRaises(ValueError):
                runtime.verify(apk, 'arm64-v8a', root)

    def test_missing_source_fails_by_default_and_succeeds_when_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            apk = root / 'local-only.apk'
            with ZipFile(apk, 'w') as z:
                z.writestr('lib/arm64-v8a/libapp.so', b'\x7fELFapp')
            with self.assertRaises(FileNotFoundError):
                runtime.verify(apk, 'arm64-v8a', root)
            self.assertFalse(runtime.verify(apk, 'arm64-v8a', root, allow_missing_source=True))

    def test_provision_writes_elf_binary_and_rejects_invalid_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(FileNotFoundError):
                runtime.provision('arm64-v8a', root, '')
            self.assertFalse(runtime.provision('arm64-v8a', root, '', allow_missing=True))
            with self.assertRaises(ValueError):
                runtime.provision('arm64-v8a', root, 'not-base64!!!')
            with self.assertRaises(ValueError):
                runtime.provision('arm64-v8a', root, base64.b64encode(b'not-elf').decode('ascii'))
            elf = b'\x7fELFvalid-arm64-runtime'
            self.assertTrue(
                runtime.provision('arm64-v8a', root, base64.b64encode(elf).decode('ascii'))
            )
            self.assertEqual(runtime.runtime_path('arm64-v8a', root).read_bytes(), elf)

    def test_release_workflow_provisions_and_verifies_packaged_runtime(self):
        root = Path(__file__).resolve().parent.parent
        workflow = (root / '.github/workflows/android-release.yml').read_text()
        self.assertIn('python3 tools/verify_apk_runtime.py --provision --abi arm64-v8a', workflow)
        self.assertIn(
            'python3 tools/verify_apk_runtime.py build/app/outputs/flutter-apk/app-release.apk --abi arm64-v8a',
            workflow,
        )


if __name__ == '__main__':
    unittest.main()
