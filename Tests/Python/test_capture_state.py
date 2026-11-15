"""Debugger state regressions: no real accounts, toolchain or SQLCipher required."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("state_capture", Path(__file__).resolve().parents[2] / "scripts/key_capture.py")
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class Error:
    def __init__(self, message=""):
        self.message = message

    def Success(self): return not self.message
    def Fail(self): return bool(self.message)
    def GetCString(self): return self.message
    def GetType(self): return 1
    def GetError(self): return 7


class Process:
    def __init__(self):
        self.state, self.stop_id, self.uid = 5, 1, 123
        self.error, self.calls, self.threads = Error(), 0, []
        self.after_resume = 6

    def IsValid(self): return True
    def GetUniqueID(self): return self.uid
    def GetState(self): return self.state
    def GetStopID(self): return self.stop_id
    def GetExitStatus(self): return 91
    def __iter__(self): return iter(self.threads)
    def Continue(self):
        self.calls += 1
        self.state = self.after_resume
        return self.error


class ProcessEvents:
    eBroadcastBitStateChanged = 1
    EventIsProcessEvent = staticmethod(lambda event: event.is_process)
    GetProcessFromEvent = staticmethod(lambda event: event.owner)
    GetStateFromEvent = staticmethod(lambda event: event.state)
    GetRestartedFromEvent = staticmethod(lambda event: event.restarted)


class CaptureStateTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.request = SimpleNamespace(complete=False, report=lambda event, **fields: self.events.append(dict(event=event, **fields)))
        self.capture = capture.ChildCapture(self.request, 30)
        self.process = Process()
        self.capture.process = self.process
        self.capture.lldb = SimpleNamespace(SBProcess=ProcessEvents, eStateInvalid=0, eStateStopped=5,
            eStateRunning=6, eStateStepping=7, eStateCrashed=8, eStateDetached=9, eStateExited=10,
            eStopReasonSignal=5, eStopReasonException=6)
        self.inspected = []
        self.capture.inspect_stop = lambda breakpoint: self.inspected.append(breakpoint)

    def event(self, **changes):
        fields = dict(is_process=True, owner=self.process, state=5, restarted=False, GetType=lambda: 1)
        fields.update(changes)
        return SimpleNamespace(**fields)

    def test_legacy_still_running_and_new_already_running_are_not_failures(self):
        for message in ("Resume request failed - process still running.", "resume request failed - process already running"):
            with self.subTest(message=message):
                self.setUp()
                self.process.error = Error(message)
                self.process.after_resume = 5  # Public state may also still lag.
                self.assertIsNone(self.capture.handle_process_event(self.event(), 42))
                self.assertEqual(self.events[-1]["event"], "resume_race")
                self.assertEqual(self.events[-1]["resumeKind"], "already_running")

    def test_restarted_startup_stop_is_not_resumed_or_read(self):
        self.assertIsNone(self.capture.handle_process_event(self.event(restarted=True), 42))
        self.assertEqual(self.process.calls, 0)
        self.assertEqual(self.inspected, [])

    def test_other_process_and_non_state_events_are_ignored(self):
        other = Process(); other.uid = 456
        for event in (self.event(owner=other), self.event(GetType=lambda: 2), self.event(is_process=False)):
            self.assertIsNone(self.capture.handle_process_event(event, 42))
        self.assertEqual(self.process.calls, 0)
        self.assertEqual(self.inspected, [])

    def test_same_stop_is_processed_once_and_later_stops_can_continue(self):
        self.capture.handle_process_event(self.event(), 42)
        self.process.state = 5
        self.capture.handle_process_event(self.event(), 42)
        self.assertEqual(self.process.calls, 1)
        self.process.stop_id += 1
        self.capture.handle_process_event(self.event(), 42)
        self.assertEqual(self.process.calls, 2)

    def test_real_permission_denial_and_unknown_error_have_structural_diagnostics(self):
        for message, code in (("Operation not permitted: private/path/secret", "debug_resume_denied"),
                              ("failed to resume private/path/secret", "child_resume_failed")):
            with self.subTest(code=code):
                self.setUp()
                self.process.error = Error(message); self.process.after_resume = 5
                with self.assertRaises(capture.CaptureFailure) as failed:
                    self.capture.handle_process_event(self.event(), 42)
                self.assertEqual(failed.exception.code, code)
                self.assertEqual(failed.exception.diagnostic["errorCode"], 7)
                self.assertEqual(failed.exception.diagnostic["state"], 5)
                self.assertNotIn("secret", repr(failed.exception.diagnostic))

    def test_process_exiting_during_resume_is_reported_as_exit(self):
        self.process.error = Error("process no longer exists"); self.process.after_resume = 10
        self.assertEqual(self.capture.handle_process_event(self.event(), 42), "child_exited")

    def test_exception_stop_is_reported_as_crash_without_resume(self):
        self.process.threads = [SimpleNamespace(GetStopReason=lambda: 6)]
        self.assertEqual(self.capture.handle_process_event(self.event(), 42), "child_crashed")
        self.assertEqual(self.process.calls, 0)

    def test_complete_capture_stays_stopped_until_breakpoints_are_removed_and_detached(self):
        self.capture.inspect_stop = lambda _: setattr(self.request, "complete", True)
        self.assertEqual(self.capture.handle_process_event(self.event(), 42), "complete")
        self.assertEqual(self.process.calls, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
