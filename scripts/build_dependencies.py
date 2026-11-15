#!/usr/bin/env python3
"""Build pinned release dependencies for macOS 14 without changing Homebrew."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tarfile

PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT / "build" / "dependencies"
TARGET = "14.0"
SOURCES = {
    "openssl-4.1.0": (
        "https://github.com/openssl/openssl/releases/download/openssl-4.1.0/openssl-4.1.0.tar.gz",
        "50c17baf54cb008f6ce42d50deb4b28050a1aad711636cabd4b241c7e90cc2fd"),
    "sqlcipher-4.20.0": (
        "https://github.com/sqlcipher/sqlcipher/archive/refs/tags/v4.20.0.tar.gz",
        "38705f51b61ac0636a5fd064f9a77fafabc7227b2aa2513f1b14c8bb1102affc"),
    "zstd-1.5.7": (
        "https://github.com/facebook/zstd/archive/refs/tags/v1.5.7.tar.gz",
        "37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3"),
}


def run(*args, cwd=None, env=None, capture=False):
    result = subprocess.run(args, cwd=cwd, env=env, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ""


def source(name, root):
    downloads, sources = ROOT / "downloads", root / "sources"
    downloads.mkdir(parents=True, exist_ok=True)
    sources.mkdir(exist_ok=True)
    url, expected = SOURCES[name]
    archive = downloads / (name + ".tar.gz")
    if not archive.exists():
        run("curl", "--fail", "--location", "--retry", "2", "--output", str(archive), url)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        raise RuntimeError("Dependency source SHA-256 mismatch: " + name)
    destination = sources / name
    if not destination.exists():
        root = sources.resolve()
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                path = (root / member.name).resolve()
                if root not in path.parents:
                    raise RuntimeError("Source archive escapes build directory")
                if member.issym() and root not in (path.parent / member.linkname).resolve().parents:
                    raise RuntimeError("Source symlink escapes build directory")
                if member.islnk() and root not in (root / member.linkname).resolve().parents:
                    raise RuntimeError("Source hardlink escapes build directory")
            tar.extractall(root)
    return destination


def minimum_os(binary):
    output = run("xcrun", "vtool", "-show-build", str(binary), capture=True)
    versions = re.findall(r"\bminos\s+([0-9.]+)", output)
    if not versions or any(tuple(map(int, v.split("."))) > (14, 0) for v in versions):
        raise RuntimeError("Dependency exceeds macOS 14 deployment target: " + str(binary))
    return versions


def main(architecture=None):
    if platform.system() != "Darwin":
        raise RuntimeError("Build on macOS with Xcode Command Line Tools")
    architecture = architecture or platform.machine()
    if architecture not in ("arm64", "x86_64"):
        raise RuntimeError("Unsupported build architecture: " + architecture)
    root = ROOT if architecture == platform.machine() else ROOT / architecture
    prefix = root / "prefix"
    expected = {"target": TARGET, "architecture": architecture, "sources": SOURCES}
    manifest = prefix / "manifest.json"
    binaries = [prefix / "bin" / "sqlcipher", prefix / "lib" / "libzstd.dylib"]
    if manifest.exists() and all(p.is_file() for p in binaries):
        saved = json.loads(manifest.read_text())
        if saved == json.loads(json.dumps(expected)):
            for binary in binaries:
                minimum_os(binary)
                if run("lipo", "-archs", str(binary), capture=True) != architecture:
                    raise RuntimeError("Cached dependency architecture mismatch: " + str(binary))
            print("Using verified macOS 14 dependency build", flush=True)
            return prefix
    (prefix / "bin").mkdir(parents=True, exist_ok=True)
    (prefix / "lib").mkdir(exist_ok=True)
    env = os.environ.copy()
    env.update({"MACOSX_DEPLOYMENT_TARGET": TARGET, "CC": "/usr/bin/clang", "CXX": "/usr/bin/clang++",
                "SDKROOT": run("xcrun", "--show-sdk-path", capture=True),
                "CFLAGS": "-O2 -arch " + architecture + " -mmacosx-version-min=" + TARGET,
                "LDFLAGS": "-arch " + architecture + " -mmacosx-version-min=" + TARGET})
    jobs = str(min(6, os.cpu_count() or 2))
    crypto = source("openssl-4.1.0", root)
    print("Building static OpenSSL for macOS " + TARGET, flush=True)
    run("/usr/bin/perl", "./Configure", "darwin64-" + architecture + "-cc",
        "no-shared", "no-apps", "no-tests", "no-module", "--prefix=" + str(prefix),
        "--openssldir=/etc/ssl", "--libdir=lib", cwd=crypto, env=env)
    run("make", "-j" + jobs, cwd=crypto, env=env)
    run("make", "install_sw", cwd=crypto, env=env)
    cipher = source("sqlcipher-4.20.0", root)
    print("Building SQLCipher for macOS " + TARGET, flush=True)
    cflags = env["CFLAGS"] + " -I" + str(prefix / "include") + " " + " ".join([
        "-DSQLITE_HAS_CODEC", "-DSQLITE_ENABLE_JSON1", "-DSQLITE_ENABLE_FTS3",
        "-DSQLITE_ENABLE_FTS3_PARENTHESIS", "-DSQLITE_ENABLE_FTS5", "-DSQLITE_ENABLE_COLUMN_METADATA",
        "-DSQLITE_EXTRA_INIT=sqlcipher_extra_init", "-DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown"])
    ldflags = env["LDFLAGS"] + " -L" + str(prefix / "lib") + " " + str(prefix / "lib/libcrypto.a")
    ldflags += " -framework Security -framework CoreFoundation"
    run("./configure", "--disable-tcl", "--disable-shared", "--disable-readline", "--disable-load-extension",
        "--with-tempstore=yes", "--prefix=" + str(prefix), "CFLAGS=" + cflags,
        "LDFLAGS=" + ldflags, cwd=cipher, env=env)
    run("make", "-j" + jobs, "sqlite3", cwd=cipher, env=env)
    shutil.copy2(cipher / "sqlite3", binaries[0])
    binaries[0].chmod(0o755)
    version = run(str(binaries[0]), ":memory:", "PRAGMA cipher_version;", capture=True)
    if not version.startswith("4.20.0"):
        raise RuntimeError("SQLCipher codec was not built correctly: " + version)
    links = run("otool", "-L", str(binaries[0]), capture=True)
    if "/opt/homebrew/" in links or "libcrypto." in links:
        raise RuntimeError("SQLCipher must use the locally compiled static crypto library")
    zstd = source("zstd-1.5.7", root)
    print("Building Zstandard for macOS " + TARGET, flush=True)
    run("make", "-C", "lib", "-j" + jobs, cwd=zstd, env=env)
    shutil.copy2((zstd / "lib/libzstd.dylib").resolve(), binaries[1])
    for binary in binaries:
        print(str(binary.name) + " deployment: " + str(minimum_os(binary)), flush=True)
        if run("lipo", "-archs", str(binary), capture=True) != architecture:
            raise RuntimeError("Dependency architecture mismatch: " + str(binary))
    notices = prefix / "share" / "licenses"
    notices.mkdir(parents=True, exist_ok=True)
    for name, folder in [("openssl", crypto), ("sqlcipher", cipher), ("zstd", zstd)]:
        for filename in ["LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING"]:
            path = folder / filename
            if path.is_file():
                shutil.copy2(path, notices / (name + "-" + filename))
    manifest.write_text(json.dumps(expected, indent=2) + "\n")
    print("macOS 14 dependencies ready: " + str(prefix), flush=True)
    return prefix


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=("arm64", "x86_64"))
    main(parser.parse_args().arch)
