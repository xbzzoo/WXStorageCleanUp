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


class CaptureFailure(RuntimeError):
    def __init__(self, code, **diagnostic):
        super().__init__(code)
        self.code = code
        self.diagnostic = diagnostic


def resume_error_kind(error):
    # LLDB <= 17 says "still running"; newer versions say "already running".
    # Only classify text in memory. Never put debugger error text in the log.
    message = (error.GetCString() or "").lower()
    if "already running" in message or "still running" in message:
        return "already_running"
    if any(value in message for value in ("permission denied", "operation not permitted", "not allowed to", "not permitted to")):
        return "permission_denied"
    return "other"


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

    def report(self, event, **fields):
        pending = sorted(set(self.pages) - set(self.keys))
        # Database names come from the request allowlist. Never include key bytes,
        # account names, absolute paths, debugger output or chat contents.
        publish(event, verified=len(self.keys), total=len(self.pages), complete=self.complete,
                pending=pending[:8], pending_count=len(pending), **fields)

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
        self.observations = 0
        self.handled_stop = None
        self.breakpoint = None

    def cancel(self, _signal, _frame):
        self.cancelled = True

    def inspect_stop(self, breakpoint_id):
        lldb = self.lldb
        for thread in self.process:
            if thread.GetStopReason() != lldb.eStopReasonBreakpoint:
                continue
            if thread.GetStopReasonDataCount() < 2 or thread.GetStopReasonDataAtIndex(0) != breakpoint_id:
                continue
            self.observations += 1
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
                self.request.report("progress")

    def read(self, address, size):
        error = self.lldb.SBError()
        value = self.process.ReadMemory(address, size, error)
        return bytes(value) if error.Success() and value is not None else b""

    def diagnostic(self, error=None):
        fields = dict(state=int(self.process.GetState()), stopID=int(self.process.GetStopID()),
                      stopReasons=sorted({int(thread.GetStopReason()) for thread in self.process})[:16])
        if self.process.GetState() == self.lldb.eStateExited:
            fields["exitStatus"] = int(self.process.GetExitStatus())
        if self.breakpoint is not None:
            fields["breakpointLocations"] = int(self.breakpoint.GetNumLocations())
        if error is not None:
            fields.update(errorType=int(error.GetType()), errorCode=int(error.GetError()), resumeKind=resume_error_kind(error))
        return fields

    def terminal_reason(self, state):
        lldb = self.lldb
        if state == lldb.eStateCrashed:
            return "child_crashed"
        if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateInvalid):
            return "child_exited"
        return None

    def handle_process_event(self, event, breakpoint_id):
        lldb = self.lldb
        if not lldb.SBProcess.EventIsProcessEvent(event) or not event.GetType() & lldb.SBProcess.eBroadcastBitStateChanged:
            return None
        owner = lldb.SBProcess.GetProcessFromEvent(event)
        if not owner.IsValid() or owner.GetUniqueID() != self.process.GetUniqueID():
            return None
        state = lldb.SBProcess.GetStateFromEvent(event)
        reason = self.terminal_reason(state)
        if reason:
            self.request.report("diagnostic", **self.diagnostic())
            return reason
        # Consuming the state event updates LLDB's public run lock. A polled
        # GetState() can describe a startup stop that LLDB already auto-resumed.
        if state != lldb.eStateStopped or lldb.SBProcess.GetRestartedFromEvent(event):
            return None
        if self.process.GetState() != lldb.eStateStopped:
            return None
        stop_id = self.process.GetStopID()
        if stop_id == self.handled_stop:
            return None
        self.handled_stop = stop_id
        for thread in self.process:
            stop = thread.GetStopReason()
            fatal_signal = stop == lldb.eStopReasonSignal and thread.GetStopReasonDataCount() > 0 and \
                thread.GetStopReasonDataAtIndex(0) in (signal.SIGABRT, signal.SIGSEGV, signal.SIGBUS, signal.SIGILL, signal.SIGFPE)
            if stop == lldb.eStopReasonException or fatal_signal:
                self.request.report("diagnostic", **self.diagnostic())
                return "child_crashed"
        self.inspect_stop(breakpoint_id)
        if self.request.complete:
            return "complete"
        error = self.process.Continue()
        if error.Success():
            return None
        fields = self.diagnostic(error)
        reason = self.terminal_reason(self.process.GetState())
        if reason:
            self.request.report("diagnostic", **fields)
            return reason
        if fields["resumeKind"] == "already_running" or self.process.GetState() in (lldb.eStateRunning, lldb.eStateStepping):
            self.request.report("resume_race", **fields)
            return None
        code = "debug_resume_denied" if fields["resumeKind"] == "permission_denied" else "child_resume_failed"
        raise CaptureFailure(code, **fields)

    def launch(self, executable, arguments, data_home=None):
        import lldb
        self.lldb = lldb
        lldb.SBDebugger.Initialize()
        publish("debugger", lldbVersion=lldb.SBDebugger.GetVersionString().splitlines()[0][:200])
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
        self.breakpoint = breakpoint
        if not breakpoint.IsValid():
            raise RuntimeError("breakpoint_unavailable")
        info = lldb.SBLaunchInfo(arguments)
        info.SetLaunchFlags(info.GetLaunchFlags() & ~lldb.eLaunchFlagDisableASLR)
        info.SetWorkingDirectory(str(Path(executable).parent))
        if data_home is not None:
            home_path = Path(data_home).resolve(strict=True)
            if not home_path.is_dir():
                raise ValueError("invalid_data_home")
            # The debug copy is no longer sandboxed. Keep Foundation's home at
            # the original container so it loads the selected account's existing
            # preferences/databases instead of creating another profile.
            # Only the launched child's environment is changed, never this helper's.
            info.SetEnvironmentEntries(["CFFIXED_USER_HOME=" + str(home_path)], True)
        for descriptor in (0, 1, 2):
            info.AddSuppressFileAction(descriptor, descriptor == 0, descriptor != 0)
        error = lldb.SBError()
        self.process = self.target.Launch(info, error)
        if error.Fail() or not self.process.IsValid():
            # Avoid forwarding debugger output, paths, argument values or process memory.
            raise CaptureFailure("debug_launch_denied", errorType=int(error.GetType()), errorCode=int(error.GetError()))
        self.request.report("launched", pid=self.process.GetProcessID(), targetArchitecture=self.architecture)
        started = time.monotonic()
        end = started + self.timeout
        listener = self.debugger.GetListener()
        last_report = 0
        reason = "capture_timeout"
        while not self.cancelled and time.monotonic() < end:
            if time.monotonic() - last_report > 3:
                self.request.report("waiting", elapsed=int(time.monotonic() - started),
                                    remaining=max(0, int(end - time.monotonic())), observations=self.observations,
                                    breakpointLocations=int(breakpoint.GetNumLocations()))
                last_report = time.monotonic()
            event = lldb.SBEvent()
            if listener.WaitForEvent(1, event):
                outcome = self.handle_process_event(event, breakpoint.GetID())
                if outcome:
                    reason = outcome
                    break
            else:
                # Terminal fallback only. Never resume or inspect memory from
                # a polled stopped state without consuming its actual event.
                outcome = self.terminal_reason(self.process.GetState())
                if outcome:
                    reason = outcome
                    break
        self.request.save()
        if not self.cancelled and not self.request.complete:
            if reason == "capture_timeout" and breakpoint.GetNumLocations() == 0:
                reason = "breakpoint_unresolved"
            self.request.report("incomplete", code=reason, observations=self.observations,
                                breakpointLocations=int(breakpoint.GetNumLocations()))
        return 130 if self.cancelled else (0 if self.request.complete else 3)

    def release(self):
        if self.process is not None and self.process.IsValid():
            lldb = self.lldb
            if self.process.GetState() not in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateInvalid):
                # Remove our observations, then detach. The app coordinates a normal quit.
                # Never kill a process merely because it shares WeChat's name.
                if self.process.GetState() != lldb.eStateStopped:
                    self.process.Stop()
                    end = time.monotonic() + 5
                    listener = self.debugger.GetListener()
                    while self.process.GetState() not in (lldb.eStateStopped, lldb.eStateCrashed,
                            lldb.eStateExited, lldb.eStateDetached, lldb.eStateInvalid) and time.monotonic() < end:
                        listener.WaitForEvent(1, lldb.SBEvent())
                self.target.DeleteAllBreakpoints()
                # Older Apple LLDB Python bindings expose only Detach(). Its
                # default resumes the child; the bool overload is not portable.
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
    parser.add_argument("--data-home")
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("child_arguments", nargs="*")
    args = parser.parse_args()
    os.umask(0o077)
    request = RequestedDatabases(args.db_root, args.request, args.keys)
    request.report("cache")
    if args.verify_only or request.complete:
        # Do not destroy a previously complete key cache on a read-only readiness check.
        return 0 if request.complete else 3
    if not args.executable:
        raise ValueError("executable_required")
    capture = ChildCapture(request, args.timeout)
    signal.signal(signal.SIGINT, capture.cancel)
    signal.signal(signal.SIGTERM, capture.cancel)
    try:
        return capture.launch(args.executable, args.child_arguments, args.data_home)
    finally:
        capture.release()
        request.report("finished")


if __name__ == "__main__":
    try:
        result = main()
    except Exception as error:
        # These codes are intentionally structural. No exception repr, key or user data.
        code = str(error) if isinstance(error, (ValueError, RuntimeError)) else type(error).__name__
        allowed = {"invalid_request", "invalid_database_allowlist", "unsafe_database_path", "symlinked_database",
                   "database_outside_selected_account", "unsupported_database_page", "unsafe_cache_file",
                   "cached_account_mismatch", "unsafe_cache_location", "unsupported_target_architecture",
                   "breakpoint_unavailable", "debug_launch_denied", "debug_resume_denied", "child_resume_failed", "executable_required", "invalid_data_home"}
        publish("error", code=code if code in allowed else "capture_failed",
                **(error.diagnostic if isinstance(error, CaptureFailure) else {}))
        result = 2
    raise SystemExit(result)
