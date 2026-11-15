#!/usr/bin/env python3
"""Tests use only synthetic databases and an owned command-line PBKDF fixture."""
import hashlib
import importlib.util
import json
import os
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

    def test_real_lldb_capture_of_owned_cli_fixture(self):
        python_path = subprocess.check_output(["/usr/bin/xcrun", "lldb", "-P"], text=True).strip()
        source = self.root / "pbkdf_fixture.c"
        salt = bytes(value ^ 0x3a for value in self.page[:16])
        source.write_text("""
        #include <CommonCrypto/CommonKeyDerivation.h>
        #include <unistd.h>
        int main(void) {
            unsigned char key[32] = {%s};
            unsigned char salt[16] = {%s};
            unsigned char output[32];
            usleep(100000);
            CCKeyDerivationPBKDF(kCCPBKDF2, (const char*)key, 32, salt, 16,
                kCCPRFHmacAlgSHA512, 2, output, 32);
            usleep(200000);
            return output[0] == 255 ? 0 : 0;
        }
        """ % (",".join(str(value) for value in self.key), ",".join(str(value) for value in salt)))
        executable = self.root / "pbkdf_fixture"
        subprocess.run(["/usr/bin/xcrun", "clang", "-O0", "-g", str(source), "-o", str(executable)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        entitlements = self.root / "fixture.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True}))
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(executable)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        environment = dict(os.environ, PYTHONPATH=python_path, PYTHONNOUSERSITE="1", PYTHONDONTWRITEBYTECODE="1")
        result = subprocess.run(["/usr/bin/python3", str(HELPER), "--db-root", str(self.storage),
            "--request", str(self.request_file), "--keys", str(self.cache), "--executable", str(executable), "--timeout", "15"],
            env=environment, capture_output=True, text=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(self.key.hex(), result.stdout + result.stderr)
        self.assertEqual(json.loads(self.cache.read_text())["keys"]["contact/contact.db"]["enc_key"], self.key.hex())


if __name__ == "__main__":
    unittest.main(verbosity=2)
