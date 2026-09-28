"""Tests for ci/simulator_preflight.py with synthetic `simctl list -j` output. No Xcode is used."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CI = Path(__file__).resolve().parent.parent.parent / "ci"
sys.path.insert(0, str(CI))

import simulator_preflight as preflight  # noqa: E402

SE3 = "com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation"
IPHONE17 = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
IOS265 = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
IOS262 = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"


def devicetypes(*identifiers):
    names = {SE3: "iPhone SE (3rd generation)", IPHONE17: "iPhone 17"}
    return {"devicetypes": [{"identifier": i, "name": names.get(i, i)} for i in identifiers]}


def runtimes(available=True, supported=(SE3, IPHONE17), list_supported=True):
    runtime = {"identifier": IOS265, "name": "iOS 26.5", "version": "26.5", "buildversion": "23F77",
               "isAvailable": available}
    if not available:
        runtime["availabilityError"] = "synthetic reason"
    if list_supported:
        runtime["supportedDeviceTypes"] = [{"identifier": i} for i in supported]
    return {"runtimes": [runtime]}


class SimulatorPreflightTests(unittest.TestCase):
    def test_supported_pair_passes(self):
        ok, message = preflight.check(devicetypes(SE3, IPHONE17), runtimes(), SE3, IOS265)
        self.assertTrue(ok, message)
        self.assertEqual(message, "iPhone SE (3rd generation) on iOS 26.5 (23F77)")

    def test_each_missing_or_unsupported_case_fails_without_substitution(self):
        cases = [
            (devicetypes(IPHONE17), runtimes(), "is not installed with this Xcode"),
            (devicetypes(SE3), {"runtimes": []}, "runtime com.apple.CoreSimulator.SimRuntime.iOS-26-5 is not installed"),
            (devicetypes(SE3), runtimes(available=False), "unavailable: synthetic reason"),
            (devicetypes(SE3), runtimes(supported=(IPHONE17,)), "does not support device type"),
            (devicetypes(SE3), runtimes(list_supported=False), "support can't be confirmed"),
        ]
        for types, rts, expected in cases:
            with self.subTest(expected=expected):
                ok, message = preflight.check(types, rts, SE3, IOS265)
                self.assertFalse(ok)
                self.assertIn(expected, message)
                self.assertNotIn("iPhone 17", message, "never offers another device")

    def test_command_line_exit_codes(self):
        with tempfile.TemporaryDirectory() as folder:
            types, good, bad = (Path(folder) / n for n in ("types.json", "good.json", "bad.json"))
            types.write_text(json.dumps(devicetypes(SE3)), encoding="utf-8")
            good.write_text(json.dumps(runtimes()), encoding="utf-8")
            bad.write_text(json.dumps(runtimes(supported=(IPHONE17,))), encoding="utf-8")
            script = str(CI / "simulator_preflight.py")
            common = ["--device-type", SE3, "--runtime", IOS265, "--devicetypes-json", str(types)]
            passed = subprocess.run([sys.executable, script, *common, "--runtimes-json", str(good)],
                                    capture_output=True, text=True)
            failed = subprocess.run([sys.executable, script, *common, "--runtimes-json", str(bad)],
                                    capture_output=True, text=True)
        self.assertEqual(passed.returncode, 0, passed.stderr)
        self.assertEqual(failed.returncode, 1)
        self.assertIn("does not support", failed.stderr)


class WorkflowPinTests(unittest.TestCase):
    """The prepared workflow and its example copy stay identical and keep the agreed limits."""

    APP = Path(__file__).resolve().parent.parent.parent

    def test_example_matches_the_active_workflow_and_pins(self):
        example = (self.APP / "ci" / "ios-app-tests.yml.example").read_text(encoding="utf-8")
        active = self.APP.parent.parent / ".github" / "workflows" / "ios-app-tests.yml"
        if active.exists():
            self.assertEqual(active.read_text(encoding="utf-8"), example)
        for required in ("runs-on: macos-26 ", "timeout-minutes: 30", "DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer",
                         "AIBIBLE_EXPECT_XCODE_BUILD: 17F113", f"AIBIBLE_SIM_DEVICE_TYPE: {SE3}",
                         f"AIBIBLE_SIM_RUNTIME: {IOS262}", "persist-credentials: false", "contents: read"):
            self.assertIn(required, example)
        self.assertNotIn(IOS265, example, "exactly one runtime is pinned")
        for forbidden in ("-large", "-xlarge", "secrets.", "actions/cache", "upload-artifact", "CODE_SIGN"):
            self.assertNotIn(forbidden, example.replace("(not -large / -xlarge)", ""))



class PngBytesTests(unittest.TestCase):
    """Bundled PNGs must be copied byte-for-byte; the app checks the covers' SHA-256."""

    APP = Path(__file__).resolve().parent.parent.parent
    SCRIPT = APP / "ci" / "check-resource-bytes.sh"

    def test_png_processing_is_off_for_the_app_and_hosted_test_targets(self):
        text = (self.APP / "project.yml").read_text(encoding="utf-8")
        blocks = {}
        for name in ("AIBible", "AIBibleTests", "AIBibleUITests"):
            start = text.index(f"\n  {name}:\n")
            nexts = [text.index(f"\n  {n}:\n") for n in ("AIBible", "AIBibleTests", "AIBibleUITests", "schemes")
                     if f"\n  {n}:\n" in text and text.index(f"\n  {n}:\n") > start]
            nexts += [text.index("\nschemes:")] if "\nschemes:" in text else []
            blocks[name] = text[start:min(nexts)]
        for name in ("AIBible", "AIBibleTests"):
            self.assertIn('COMPRESS_PNG_FILES: "NO"', blocks[name], name)
            self.assertIn('STRIP_PNG_TEXT: "NO"', blocks[name], name)

    def test_ci_reads_back_both_synthetic_pngs_after_the_build(self):
        script = (self.APP / "ci" / "run-tests.sh").read_text(encoding="utf-8")
        build = script.index("xcodebuild build-for-testing")
        readback = script.index("check-resource-bytes.sh")
        tests = script.index("xcodebuild test-without-building")
        self.assertTrue(build < readback < tests, "readback runs after the build and before the tests")
        for source, built in (("AIBible/Resources/Fixtures/presentation-fixture-cover.png", "$APP_BUNDLE/presentation-fixture-cover.png"),
                              ("AIBibleTests/ConverterSample/synthetic-sample-cover.png",
                               "$APP_BUNDLE/PlugIns/AIBibleTests.xctest/synthetic-sample-cover.png")):
            self.assertIn(source, script)
            self.assertIn(built, script)

    def test_synthetic_source_pngs_are_unchanged(self):
        import hashlib
        for relative in ("AIBible/Resources/Fixtures/presentation-fixture-cover.png",
                         "AIBibleTests/ConverterSample/synthetic-sample-cover.png"):
            data = (self.APP / relative).read_bytes()
            self.assertEqual((len(data), hashlib.sha256(data).hexdigest()),
                             (73, "4f7aa88955dc030612a08ec5f5867587911ef0fa6b9e152a11ed478ee72d0574"), relative)

    @unittest.skipUnless(__import__("shutil").which("bash"), "the readback is a POSIX bash script; bash is not installed")
    def test_readback_script_passes_identical_and_fails_drift_or_missing(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            source, same, drifted = folder / "cover.png", folder / "same.png", folder / "drifted.png"
            source.write_bytes(b"\x89PNG original")
            same.write_bytes(b"\x89PNG original")
            drifted.write_bytes(b"\x89PNG re-encoded")
            run = lambda *files: subprocess.run(["bash", self.SCRIPT.as_posix(), *[f.as_posix() for f in files]],
                                                capture_output=True, text=True)
            ok = run(source, same)
            self.assertEqual(ok.returncode, 0, ok.stderr)
            self.assertIn("source 13 B", ok.stdout)
            bad = run(source, same, source, drifted)
            self.assertEqual(bad.returncode, 1)
            self.assertIn("drifted.png differs from its source", bad.stderr)
            missing = run(source, folder / "absent.png")
            self.assertEqual(missing.returncode, 1)
            self.assertIn("built copy missing", missing.stderr)
            odd = subprocess.run(["bash", self.SCRIPT.as_posix(), source.as_posix()], capture_output=True, text=True)
            self.assertEqual(odd.returncode, 2)


if __name__ == "__main__":
    unittest.main()
