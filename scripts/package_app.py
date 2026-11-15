#!/usr/bin/env python3
"""Build a local, ad-hoc signed macOS app. Does not modify WeChat or install the app."""
from pathlib import Path
import json
import hashlib
import plistlib
import re
import shutil
import subprocess
from make_icon import build_icon
from build_dependencies import main as build_dependencies, PREFIX as DEPENDENCIES

PROJECT = Path(__file__).resolve().parents[1]
OUTPUT = PROJECT / "build"
BUNDLE = OUTPUT / "微空间.app"
VERSION = "0.3.1"


def run(*args, capture=False):
    result = subprocess.run(args, cwd=PROJECT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ""


def dependencies(binary):
    output = run("otool", "-L", str(binary), capture=True)
    own_ids = set(run("otool", "-D", str(binary), capture=True).splitlines()[1:])
    return [line.strip().split(" (", 1)[0] for line in output.splitlines()[1:]
            if line.strip().startswith((str(DEPENDENCIES), "/opt/homebrew/", "/usr/local/"))
            and line.strip().split(" (", 1)[0] not in own_ids]


def main():
    build_dependencies()
    run("swift", "build", "-c", "release",
        "-Xswiftc", "-file-prefix-map", "-Xswiftc", str(PROJECT) + "=/WeChatStorage",
        "-Xswiftc", "-gnone")
    binary_dir = Path(run("swift", "build", "-c", "release", "--show-bin-path", capture=True))
    OUTPUT.mkdir(exist_ok=True)
    if BUNDLE.exists():
        # This path is a deterministic build artifact created only by this script.
        shutil.rmtree(BUNDLE)
    contents = BUNDLE / "Contents"
    executable = contents / "MacOS" / "WeChatStorage"
    resources = contents / "Resources"
    frameworks = contents / "Frameworks"
    for folder in [executable.parent, resources, frameworks]:
        folder.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary_dir / "WeChatStorage", executable)
    info = {
        "CFBundleDevelopmentRegion": "zh_CN", "CFBundleExecutable": "WeChatStorage",
        "CFBundleIdentifier": "local.wechatstorage.app", "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "微空间", "CFBundleDisplayName": "微空间", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": VERSION, "CFBundleVersion": "9", "LSMinimumSystemVersion": "14.0",
        "CFBundleIconFile": "AppIcon.icns",
        "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
        "LSApplicationCategoryType": "public.app-category.utilities",
        "NSDocumentsFolderUsageDescription": "用于扫描你选择的微信数据目录并管理选中的附件。",
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    (contents / "PkgInfo").write_text("APPL????")
    shutil.copy2(PROJECT / "scripts" / "key_capture.py", resources / "key_capture.py")
    shutil.copy2(build_icon(OUTPUT), resources / "AppIcon.icns")
    bundled = []
    cipher = str(DEPENDENCIES / "bin/sqlcipher")
    copied = {}

    def copy_library(source):
        source = Path(source)
        name = source.name
        if name in copied:
            if copied[name].resolve() != source.resolve():
                raise RuntimeError("Conflicting library basename: " + name)
            return
        copied[name] = source
        destination = frameworks / name
        shutil.copy2(source.resolve(), destination)
        for dependency in dependencies(source):
            if Path(dependency).resolve() != source.resolve():
                copy_library(dependency)
        run("install_name_tool", "-id", "@rpath/" + name, str(destination))
        for dependency in dependencies(destination):
            run("install_name_tool", "-change", dependency, "@loader_path/" + Path(dependency).name, str(destination))

    if cipher:
        target = resources / "sqlcipher"
        shutil.copy2(Path(cipher).resolve(), target)
        target.chmod(0o755)
        for dependency in dependencies(Path(cipher)):
            copy_library(dependency)
            run("install_name_tool", "-change", dependency,
                "@executable_path/../Frameworks/" + Path(dependency).name, str(target))
        bundled.append(target)
    copy_library(DEPENDENCIES / "lib/libzstd.dylib")
    notices = resources / "ThirdPartyNotices"
    notices.mkdir()
    for path in (DEPENDENCIES / "share/licenses").iterdir():
        if path.is_file():
            shutil.copy2(path, notices / path.name)
    (notices / "README.txt").write_text(
        "SQLCipher Community Edition (BSD-style license): https://github.com/sqlcipher/sqlcipher\n"
        "OpenSSL (Apache-2.0): https://www.openssl.org/source/license.html\n"
        "Zstandard (BSD/GPL dual license; BSD distribution): https://github.com/facebook/zstd\n"
        "The application uses Apple's system SQLite and frameworks.\n")
    # Enforce the requested floor on every shipped Mach-O, including bundled helpers.
    versions = [(14, 0)]
    components = []
    for binary in [executable, *frameworks.iterdir(), *bundled]:
        version = re.search(r"\bminos\s+([0-9.]+)", run("xcrun", "vtool", "-show-build", str(binary), capture=True))
        if not version:
            raise RuntimeError("Cannot verify deployment target: " + str(binary))
        versions.append(tuple(int(part) for part in version.group(1).split(".")))
        components.append({"path": str(binary.relative_to(BUNDLE)), "minimumOSVersion": version.group(1)})
    if max(versions) > (14, 0):
        raise RuntimeError("A bundled binary exceeds the macOS 14 deployment target")
    minimum_os = ".".join(map(str, max(versions)))
    info["LSMinimumSystemVersion"] = minimum_os
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    for library in frameworks.iterdir():
        if library.is_file():
            run("codesign", "--force", "--sign", "-", "--timestamp=none", str(library))
    for binary in bundled:
        run("codesign", "--force", "--sign", "-", "--options", "0", "--timestamp=none", str(binary))
    # Ad-hoc signatures have no Developer Team ID. Hardened library validation would reject
    # these locally signed dependencies; release distribution needs a real Developer ID
    # applied consistently to the app, helper, and libraries before enabling runtime.
    run("codesign", "--force", "--sign", "-", "--options", "0", "--timestamp=none", str(BUNDLE))
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(BUNDLE))
    if cipher:
        run(str(resources / "sqlcipher"), ":memory:", "PRAGMA cipher_version;")
    archive = OUTPUT / "WeChatStorage-macOS.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(BUNDLE), str(archive))
    architecture = run("lipo", "-archs", str(executable), capture=True)
    release = OUTPUT / "release"
    release.mkdir(exist_ok=True)
    compatibility = {"version": VERSION, "architecture": architecture, "minimumOSVersion": minimum_os,
                     "components": components, "dependenciesBuiltFromSource": True, "opensslLinkage": "static",
                     "runtimeValidationOS": run("sw_vers", "-productVersion", capture=True),
                     "macOS14Or15HardwareTested": False, "notarized": False}
    compatibility_file = release / "COMPATIBILITY.json"
    compatibility_file.write_text(json.dumps(compatibility, indent=2) + "\n")
    artifact_name = f"WeChatStorage-{VERSION}-macOS-{architecture}"
    zip_release = release / (artifact_name + ".zip")
    shutil.copy2(archive, zip_release)
    stage = OUTPUT / "dmg-stage"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir()
    shutil.copytree(BUNDLE, stage / BUNDLE.name, symlinks=True)
    (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
    (stage / "安装说明.txt").write_text(
        f"微空间 {VERSION} · macOS {minimum_os}+ · {architecture}\n\n"
        "安装：将「微空间.app」拖入旁边的 Applications 文件夹，然后从应用程序打开。\n\n"
        "本预览版使用本地 ad-hoc 签名，尚未通过 Apple 公证。\n"
        "如果 macOS 阻止打开，请先核对下载来源，再参考 Apple 的单个应用放行说明：\n"
        "https://support.apple.com/102445\n\n"
        "清理将附件移入废纸篓。请核对后清空相应项目；共享文件的其他硬链接仍存在时，数据空间继续占用。\n"
        "项目：https://github.com/xbzzoo/WeChatStorage\n", encoding="utf-8")
    dmg = release / (artifact_name + ".dmg")
    run("hdiutil", "create", "-volname", "微空间", "-srcfolder", str(stage),
        "-format", "UDZO", "-fs", "HFS+", "-ov", str(dmg))
    checksums = []
    for artifact in (dmg, zip_release, compatibility_file):
        digest = hashlib.sha256()
        with artifact.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
        checksums.append(digest.hexdigest() + "  " + artifact.name)
    (release / "SHA256SUMS.txt").write_text("\n".join(checksums) + "\n")
    metadata = {"app": str(BUNDLE), "version": VERSION, "architecture": architecture, "minimumOSVersion": minimum_os,
                "sqlcipherBundled": bool(cipher), "libraries": sorted(copied), "notarized": False, "hardenedRuntime": False}
    (OUTPUT / "build-info.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    print("Built: " + str(BUNDLE))


if __name__ == "__main__":
    main()
