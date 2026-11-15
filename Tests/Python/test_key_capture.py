#!/usr/bin/env python3
"""Tests use only synthetic databases and an owned command-line PBKDF fixture."""
import hashlib
import contextlib
import io
import importlib.util
import json
import os
import platform
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
HELPER = PROJECT / "scripts/key_capture.py"
spec = importlib.util.spec_from_file_location("local_key_capture", HELPER)
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class KeyCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="WeChatStorageKeyTests-")
        self.root = Path(self.temp.name)
        self.storage = self.root / "account-a" / "db_storage"
        self.database = self.storage / "contact" / "contact.db"
        self.database.parent.mkdir(parents=True)
        self.key = bytes(range(32))
        sqlcipher = shutil.which("sqlcipher")
        if not sqlcipher:
            self.skipTest("SQLCipher is not installed")
        subprocess.run([sqlcipher, str(self.database)], input=(
            'PRAGMA key="x\'%s\'"; CREATE TABLE fixture(value); INSERT INTO fixture VALUES(1);\n' % self.key.hex()),
            text=True, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.page = self.database.read_bytes()[:4096]
        self.request_file = self.root / "request.json"
        self.request_file.write_text(json.dumps({"version": 1, "account": "scope-a", "databases": ["contact/contact.db"]}))
        self.cache = self.root / "vault" / "keys.json"
        self.addCleanup(self.temp.cleanup)

    def request(self):
        return capture.RequestedDatabases(self.storage, self.request_file, self.cache)

    def test_page_authentication_and_wrong_key(self):
        self.assertTrue(capture.authenticate_page(self.key, self.page))
        self.assertFalse(capture.authenticate_page(bytes(reversed(range(32))), self.page))
        changed = bytearray(self.page); changed[100] ^= 1
        self.assertFalse(capture.authenticate_page(self.key, bytes(changed)))
        self.assertFalse(capture.authenticate_page(self.key, self.page[:100]))

    def test_matching_salt_is_required_and_cache_is_private(self):
        request = self.request()
        salt = bytes(value ^ 0x3a for value in self.page[:16])
        self.assertFalse(request.observe(self.key, bytes(16), 2))
        self.assertFalse(request.observe(self.key, salt, 1))
        self.assertTrue(request.observe(self.key, salt, 2))
        self.assertTrue(request.complete)
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.cache.parent.stat().st_mode & 0o777, 0o700)
        self.assertTrue(self.request().complete)

    def test_foreign_account_cache_is_refused(self):
        capture.private_save(self.cache, {"version": 1, "account": "scope-b", "keys": {
            "contact/contact.db": {"enc_key": self.key.hex()}}})
        with self.assertRaisesRegex(ValueError, "cached_account_mismatch"):
            self.request()

    def test_invalid_cached_key_is_not_reused(self):
        capture.private_save(self.cache, {"version": 1, "account": "scope-a", "keys": {
            "contact/contact.db": {"enc_key": bytes(reversed(range(32))).hex()}}})
        self.assertFalse(self.request().complete)

    def test_database_allowlist_rejects_escape_and_symlink(self):
        self.request_file.write_text(json.dumps({"version": 1, "account": "scope-a", "databases": ["../other.db"]}))
        with self.assertRaises(ValueError):
            self.request()
        (self.storage / "link.db").symlink_to(self.database)
        self.request_file.write_text(json.dumps({"version": 1, "account": "scope-a", "databases": ["link.db"]}))
        with self.assertRaises(ValueError):
            self.request()

    def test_verify_only_does_not_print_or_require_lldb(self):
        request = self.request()
        request.observe(self.key, bytes(part ^ 0x3a for part in self.page[:16]), 2)
        result = subprocess.run(["/usr/bin/python3", str(HELPER), "--db-root", str(self.storage),
            "--request", str(self.request_file), "--keys", str(self.cache), "--verify-only"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn(self.key.hex(), result.stdout + result.stderr)
        self.assertTrue(json.loads(result.stdout)["complete"])

    def test_progress_lists_only_missing_databases_and_never_keys(self):
        request = self.request()
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream):
            request.report("waiting", elapsed=30, remaining=210)
            request.observe(self.key, bytes(part ^ 0x3a for part in self.page[:16]), 2)
            request.report("finished")
        events = [json.loads(line) for line in stream.getvalue().splitlines()]
        self.assertEqual(events[0]["pending"], ["contact/contact.db"])
        self.assertEqual(events[0]["pending_count"], 1)
        self.assertEqual(events[0]["elapsed"], 30)
        self.assertEqual(events[-1]["pending"], [])
        self.assertTrue(events[-1]["complete"])
        self.assertNotIn(self.key.hex(), stream.getvalue())
        self.assertNotIn(str(self.storage), stream.getvalue())

    def test_real_lldb_capture_of_owned_cli_fixture(self):
        self.capture_owned_cli_fixture(platform.machine())

    @unittest.skipUnless(platform.machine() == "arm64", "Cross-architecture validation requires an Apple Silicon host")
    def test_real_lldb_capture_of_owned_intel_cli_fixture(self):
        if subprocess.run(["/usr/bin/arch", "-x86_64", "/usr/bin/true"], capture_output=True).returncode:
            self.skipTest("Rosetta is not installed")
        self.capture_owned_cli_fixture("x86_64")

    def test_real_command_line_tools_capture_of_owned_intel_fixture(self):
        lldb = Path("/Library/Developer/CommandLineTools/usr/bin/lldb")
        if not lldb.exists():
            self.skipTest("Separate Command Line Tools are not installed")
        if platform.machine() == "arm64" and subprocess.run(["/usr/bin/arch", "-x86_64", "/usr/bin/true"], capture_output=True).returncode:
            self.skipTest("Rosetta is not installed")
        python_path = subprocess.check_output([str(lldb), "-P"], text=True).strip()
        self.capture_owned_cli_fixture("x86_64", python_path=python_path, local_symbols=True)

    def capture_owned_cli_fixture(self, architecture, python_path=None, local_symbols=False):
        python_path = python_path or os.environ.get("WX_TEST_LLDB_PYTHON") or subprocess.check_output(["/usr/bin/xcrun", "lldb", "-P"], text=True).strip()
        helper = os.environ.get("WX_TEST_KEY_CAPTURE_HELPER", str(HELPER))
        wrapper = ""
        if local_symbols or os.environ.get("WX_TEST_LOCAL_SYMBOLS"):
            # LLDB 14 cannot resolve symbols in macOS 26's dyld shared cache.
            # Give the synthetic fixture a local entry with the same ABI; its
            # implementation still calls the actual CommonCrypto function.
            # This tests the legacy event protocol, not shared-cache support.
            wrapper = """
            #include <dlfcn.h>
            __attribute__((noinline)) int CCKeyDerivationPBKDF(CCPBKDFAlgorithm algorithm,
                const char *password, size_t passwordLen, const uint8_t *salt, size_t saltLen,
                CCPseudoRandomAlgorithm prf, uint rounds, uint8_t *derivedKey, size_t derivedKeyLen) {
                typedef int (*Function)(CCPBKDFAlgorithm, const char *, size_t, const uint8_t *, size_t,
                    CCPseudoRandomAlgorithm, uint, uint8_t *, size_t);
                Function function = (Function)dlsym(RTLD_NEXT, "CCKeyDerivationPBKDF");
                return function(algorithm, password, passwordLen, salt, saltLen, prf, rounds, derivedKey, derivedKeyLen);
            }
            """
        source = self.root / "pbkdf_fixture.m"
        salt = bytes(value ^ 0x3a for value in self.page[:16])
        source.write_text("""
        #include <CommonCrypto/CommonKeyDerivation.h>
        #import <Foundation/Foundation.h>
        #include <unistd.h>
        #include <pthread.h>
        %s
        static void *warmup(void *unused) {
            unsigned char otherKey[32] = {0}, otherSalt[16] = {0}, output[32];
            for (int i = 0; i < 6; ++i) {
                CCKeyDerivationPBKDF(kCCPBKDF2, (const char*)otherKey, 32, otherSalt, 16,
                    kCCPRFHmacAlgSHA512, 2, output, 32);
            }
            return 0;
        }
        int main(int argc, char **argv) {
            @autoreleasepool {
            if (argc != 2) return 90;
            NSString *expectedHome = [NSString stringWithUTF8String:argv[1]];
            if (![NSHomeDirectory() isEqualToString:expectedHome]) return 91;
            NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            if (![documents isEqualToString:[expectedHome stringByAppendingPathComponent:@"Documents"]]) return 92;
            pthread_t threads[4];
            for (int i = 0; i < 4; ++i) pthread_create(&threads[i], 0, warmup, 0);
            for (int i = 0; i < 4; ++i) pthread_join(threads[i], 0);
            unsigned char key[32] = {%s};
            unsigned char salt[16] = {%s};
            unsigned char output[32];
            usleep(100000);
            CCKeyDerivationPBKDF(kCCPBKDF2, (const char*)key, 32, salt, 16,
                kCCPRFHmacAlgSHA512, 2, output, 32);
            usleep(200000);
            return output[0] == 255 ? 0 : 0;
            }
        }
        """ % (wrapper, ",".join(str(value) for value in self.key), ",".join(str(value) for value in salt)))
        executable = self.root / "pbkdf_fixture"
        subprocess.run(["/usr/bin/xcrun", "clang", "-arch", architecture, "-O0", "-g", "-framework", "Foundation", str(source), "-o", str(executable)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        entitlements = self.root / "fixture.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True}))
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(executable)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        environment = dict(os.environ, PYTHONPATH=python_path, PYTHONNOUSERSITE="1", PYTHONDONTWRITEBYTECODE="1")
        data_home = self.root / "original-container" / "Data"
        (data_home / "Documents").mkdir(parents=True)
        result = subprocess.run(["/usr/bin/python3", helper, "--db-root", str(self.storage),
            "--request", str(self.request_file), "--keys", str(self.cache), "--executable", str(executable), "--timeout", "15",
            "--data-home", str(data_home), str(data_home)],
            env=environment, capture_output=True, text=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(self.key.hex(), result.stdout + result.stderr)
        self.assertEqual(json.loads(self.cache.read_text())["keys"]["contact/contact.db"]["enc_key"], self.key.hex())
        # A child that exits before opening the selected DB must report why,
        # rather than pretending the user should keep waiting for login.
        self.cache.unlink()
        early_exit = subprocess.run(["/usr/bin/python3", helper, "--db-root", str(self.storage),
            "--request", str(self.request_file), "--keys", str(self.cache), "--executable", str(executable), "--timeout", "15",
            "--data-home", str(data_home), str(self.root / "wrong-home")],
            env=environment, capture_output=True, text=True, timeout=45)
        self.assertEqual(early_exit.returncode, 3, early_exit.stdout + early_exit.stderr)
        events = [json.loads(line) for line in early_exit.stdout.splitlines()]
        incomplete = next(event for event in events if event["event"] == "incomplete")
        self.assertEqual(incomplete["code"], "child_exited")
        self.assertEqual(incomplete["pending"], ["contact/contact.db"])
        self.assertEqual(incomplete["verified"], 0)
        self.assertNotIn(self.key.hex(), early_exit.stdout + early_exit.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
