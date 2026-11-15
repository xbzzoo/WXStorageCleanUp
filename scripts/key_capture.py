#!/usr/bin/env python3
"""Local, account-scoped key acquisition for a process launched by this helper.

Only PBKDF invocations whose salts belong to explicitly requested databases are
examined. Candidates must authenticate an entire SQLCipher v4 first page before
they enter the private cache. The event stream contains counts, never key bytes.
No attach-to-PID, privilege escalation, system-setting changes or network access.

The SQLCipher page layout and CommonCrypto observation approach are documented at
https://gist.github.com/acmerfight/0a01249ef72970d07a2603dbb629e80f .
This implementation adds account binding, cache revalidation, request allowlists,
bounded observations and graceful stop/detach of its own launched child.
"""
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import signal
import struct
import tempfile
import time


def publish(event, **fields):
    print(json.dumps(dict(event=event, **fields), sort_keys=True), flush=True)


def authenticate_page(key, page):
    if not isinstance(key, bytes) or len(key) != 32 or len(page) != 4096:
        return False
    authentication_salt = bytes(part ^ 0x3a for part in page[:16])
    authentication_key = hashlib.pbkdf2_hmac("sha512", key, authentication_salt, 2, dklen=32)
    message = page[16:-64] + struct.pack("<I", 1)
    return hmac.compare_digest(hmac.new(authentication_key, message, "sha512").digest(), page[-64:])


def private_save(destination, value):
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if destination.is_symlink() or destination.parent.is_symlink():
        raise ValueError("unsafe_cache_location")
    os.chmod(str(destination.parent), 0o700)
    descriptor, name = tempfile.mkstemp(prefix=".capture-", dir=str(destination.parent))
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, str(destination))
    finally:
        if os.path.exists(name):
            os.unlink(name)


class RequestedDatabases:
    def __init__(self, root, request_file, cache_file):
        self.root = Path(root).resolve(strict=True)
        request = json.loads(Path(request_file).read_text())
        if request.get("version") != 1 or not request.get("account"):
            raise ValueError("invalid_request")
        self.account = request["account"]
        self.cache_file = Path(cache_file)
        self.pages = {}
        names = request.get("databases", [])
        if not names or len(names) > 512 or len(set(names)) != len(names):
            raise ValueError("invalid_database_allowlist")
        for name in names:
            relative = Path(name)
            if relative.is_absolute() or any(part in (".", "..") for part in relative.parts):
                raise ValueError("unsafe_database_path")
            path = self.root / relative
            if path.is_symlink():
                raise ValueError("symlinked_database")
            if self.root not in path.resolve(strict=True).parents:
                raise ValueError("database_outside_selected_account")
            with path.open("rb") as stream:
                page = stream.read(4096)
            if page[:16] == b"SQLite format 3\0":
                continue
            if len(page) != 4096:
                raise ValueError("unsupported_database_page")
            self.pages[name] = page
        self.keys = {}
        self.load_valid_cache()

    def load_valid_cache(self):
        if not self.cache_file.exists():
            return
        if self.cache_file.is_symlink() or self.cache_file.stat().st_size > 2 * 1024 * 1024:
            raise ValueError("unsafe_cache_file")
        cached = json.loads(self.cache_file.read_text())
        if cached.get("version") != 1 or cached.get("account") != self.account:
            raise ValueError("cached_account_mismatch")
        entries = cached.get("keys", {})
        for name, page in self.pages.items():
            entry = entries.get(name, {})
            try:
                key = bytes.fromhex(entry.get("enc_key", ""))
            except (ValueError, TypeError):
                continue
            if authenticate_page(key, page):
                self.keys[name] = {"enc_key": key.hex(), "salt": page[:16].hex()}

    @property
    def complete(self):
        return len(self.keys) == len(self.pages)

    def save(self):
        private_save(self.cache_file, {"version": 1, "account": self.account, "keys": self.keys})

    def observe(self, secret, salt, iterations):
        if iterations == 2:
            original_salt = bytes(part ^ 0x3a for part in salt)
            candidate = secret
        elif iterations == 256000:
            original_salt = salt
            if original_salt not in {page[:16] for page in self.pages.values()}:
                return False
            candidate = hashlib.pbkdf2_hmac("sha512", secret, salt, iterations, dklen=32)
        else:
            return False
        changed = False
        for name, page in self.pages.items():
            if name not in self.keys and page[:16] == original_salt and authenticate_page(candidate, page):
                self.keys[name] = {"enc_key": candidate.hex(), "salt": original_salt.hex()}
                changed = True
        if changed:
            self.save()
        return changed


class ChildCapture:
    def __init__(self, request, timeout):
        self.request = request
        self.timeout = min(300, max(5, timeout))
        self.cancelled = False
        self.debugger = None
        self.process = None
        self.target = None
        self.lldb = None
        self.architecture = None

    def cancel(self, _signal, _frame):
        self.cancelled = True

    def inspect_stop(self, breakpoint_id):
        lldb = self.lldb
        for thread in self.process:
            if thread.GetStopReason() != lldb.eStopReasonBreakpoint:
                continue
            if thread.GetStopReasonDataCount() < 2 or thread.GetStopReasonDataAtIndex(0) != breakpoint_id:
                continue
            frame = thread.GetFrameAtIndex(0)
            if self.architecture.startswith("arm64"):
                registers = [frame.FindRegister("x%d" % index).GetValueAsUnsigned() for index in range(1, 7)]
            else:
                # macOS x86_64 follows the SysV ABI: arguments 2–6 use registers,
                # and the seventh argument (rounds) follows the return address.
                registers = [frame.FindRegister(name).GetValueAsUnsigned()
                             for name in ("rsi", "rdx", "rcx", "r8", "r9")]
                stack = frame.FindRegister("rsp").GetValueAsUnsigned()
                rounds = self.read(stack + 8, 4)
                if len(rounds) != 4:
                    continue
                registers.append(int.from_bytes(rounds, "little"))
            secret_address, length, salt_address, salt_length, algorithm, iterations = registers
            if algorithm != 5 or iterations not in (2, 256000) or salt_length != 16 or not 1 <= length <= 256:
                continue
            salt = self.read(salt_address, 16)
            selected = {page[:16] for page in self.request.pages.values()}
            if iterations == 2:
                selected = {bytes(part ^ 0x3a for part in value) for value in selected}
            if salt not in selected:
                continue
            secret = self.read(secret_address, length)
            if len(secret) != length:
                continue
            if self.request.observe(secret, salt, iterations):
                publish("progress", verified=len(self.request.keys), total=len(self.request.pages))

    def read(self, address, size):
        error = self.lldb.SBError()
        value = self.process.ReadMemory(address, size, error)
        return bytes(value) if error.Success() and value is not None else b""

    def launch(self, executable, arguments):
        import lldb
        self.lldb = lldb
        lldb.SBDebugger.Initialize()
        # Pass False at creation time: neither user nor project .lldbinit files run.
        self.debugger = lldb.SBDebugger.Create(False)
        self.debugger.SkipLLDBInitFiles(True)
        self.debugger.SetAsync(True)
        # Inspect the entry ABI before a prologue changes registers or the stack.
        error = self.debugger.SetInternalVariable("target.skip-prologue", "false", self.debugger.GetInstanceName())
        if error.Fail():
            raise RuntimeError("breakpoint_unavailable")
        self.target = self.debugger.CreateTarget(str(Path(executable).resolve(strict=True)))
        self.architecture = self.target.GetTriple().split("-", 1)[0]
        if not self.target.IsValid() or not (self.architecture.startswith("arm64") or self.architecture == "x86_64"):
            raise RuntimeError("unsupported_target_architecture")
        breakpoint = self.target.BreakpointCreateByName("CCKeyDerivationPBKDF")
        if not breakpoint.IsValid():
            raise RuntimeError("breakpoint_unavailable")
        info = lldb.SBLaunchInfo(arguments)
        info.SetLaunchFlags(info.GetLaunchFlags() & ~lldb.eLaunchFlagDisableASLR)
        info.SetWorkingDirectory(str(Path(executable).parent))
        for descriptor in (0, 1, 2):
            info.AddSuppressFileAction(descriptor, descriptor == 0, descriptor != 0)
        error = lldb.SBError()
        self.process = self.target.Launch(info, error)
        if error.Fail() or not self.process.IsValid():
            # Avoid forwarding debugger output, paths, argument values or process memory.
            raise RuntimeError("debug_launch_denied")
        publish("launched", pid=self.process.GetProcessID(), verified=len(self.request.keys), total=len(self.request.pages))
        end = time.monotonic() + self.timeout
        listener = self.debugger.GetListener()
        last_report = 0
        handled_stop = None
        while not self.cancelled and time.monotonic() < end:
            state = self.process.GetState()
            if state in (lldb.eStateExited, lldb.eStateCrashed, lldb.eStateDetached, lldb.eStateInvalid):
                break
            if state == lldb.eStateStopped and self.process.GetStopID() != handled_stop:
                handled_stop = self.process.GetStopID()
                self.inspect_stop(breakpoint.GetID())
                error = self.process.Continue()
                # LLDB's public state can briefly lag the private launch state. A queued
                # startup stop may already have resumed when the listener observes it.
                if error.Fail() and "already running" not in (error.GetCString() or "").lower():
                    raise RuntimeError("child_resume_failed")
                if self.request.complete:
                    break
            if time.monotonic() - last_report > 3:
                publish("waiting", verified=len(self.request.keys), total=len(self.request.pages))
                last_report = time.monotonic()
            event = lldb.SBEvent()
            listener.WaitForEvent(1, event)
        self.request.save()
        return 130 if self.cancelled else (0 if self.request.complete else 3)

    def release(self):
        if self.process is not None and self.process.IsValid():
            lldb = self.lldb
            if self.process.GetState() not in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateInvalid):
                # Remove our observations, then detach. The app coordinates a normal quit.
                # Never kill a process merely because it shares WeChat's name.
                if self.process.GetState() != lldb.eStateStopped:
                    self.process.Stop()
                self.target.DeleteAllBreakpoints()
                error = self.process.Detach()
                if error.Fail():
                    # Resume a stopped child even when detach failed, so it is not left frozen.
                    self.process.Continue()
                    publish("cleanup_needed", pid=self.process.GetProcessID())
                else:
                    publish("detached", pid=self.process.GetProcessID())
        if self.debugger is not None:
            self.lldb.SBDebugger.Destroy(self.debugger)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db-root", required=True)
    parser.add_argument("--request", required=True)
    parser.add_argument("--keys", required=True)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--executable")
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("child_arguments", nargs="*")
    args = parser.parse_args()
    os.umask(0o077)
    request = RequestedDatabases(args.db_root, args.request, args.keys)
    publish("cache", verified=len(request.keys), total=len(request.pages), complete=request.complete)
    if args.verify_only or request.complete:
        # Do not destroy a previously complete key cache on a read-only readiness check.
        return 0 if request.complete else 3
    if not args.executable:
        raise ValueError("executable_required")
    capture = ChildCapture(request, args.timeout)
    signal.signal(signal.SIGINT, capture.cancel)
    signal.signal(signal.SIGTERM, capture.cancel)
    try:
        return capture.launch(args.executable, args.child_arguments)
    finally:
        capture.release()
        publish("finished", verified=len(request.keys), total=len(request.pages), complete=request.complete)


if __name__ == "__main__":
    try:
        result = main()
    except Exception as error:
        # These codes are intentionally structural. No exception repr, key or user data.
        code = str(error) if isinstance(error, (ValueError, RuntimeError)) else type(error).__name__
        allowed = {"invalid_request", "invalid_database_allowlist", "unsafe_database_path", "symlinked_database",
                   "database_outside_selected_account", "unsupported_database_page", "unsafe_cache_file",
                   "cached_account_mismatch", "unsafe_cache_location", "unsupported_target_architecture",
                   "breakpoint_unavailable", "debug_launch_denied", "child_resume_failed", "executable_required"}
        publish("error", code=code if code in allowed else "capture_failed")
        result = 2
    raise SystemExit(result)
