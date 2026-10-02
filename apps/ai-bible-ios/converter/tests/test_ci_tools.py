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
        for forbidden in ("-large", "-xlarge", "secrets.", "actions/cache", "CODE_SIGN"):
            self.assertNotIn(forbidden, example.replace("(not -large / -xlarge)", ""))
        # The Python suite (converter, release preflight, private-app verifier) runs in CI too.
        self.assertIn("python3 -m unittest discover -s apps/ai-bible-ios/converter/tests", example)
        # The one upload: the synthetic screenshots, from a pinned action, kept 7 days.
        upload = "uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1"
        self.assertEqual(example.count("upload-artifact"), 1)
        self.assertIn(upload, example)
        for required in ("name: aibible-screenshots", "path: ${{ runner.temp }}/aibible-screenshots",
                         "AIBIBLE_SCREENSHOT_DIR: ${{ runner.temp }}/aibible-screenshots", "retention-days: 7"):
            self.assertIn(required, example)



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


@unittest.skipUnless(__import__("shutil").which("bash"), "the verifier is a POSIX bash script; bash is not installed")
class PrivateAppVerifyTests(unittest.TestCase):
    """ci/verify-private-app.sh against fake app bundles: it must pass only an app that bundles the
    reviewed private book (and cover), selects it, and holds no synthetic sample content."""

    APP = Path(__file__).resolve().parent.parent.parent
    SCRIPT = APP / "ci" / "verify-private-app.sh"
    BOOK = b'{"isFixture": false, "chapters": []}'
    COVER = b"\x89PNG private cover"

    def make_app(self, folder, marker=b"AIBIBLE_EDITION=private-book"):
        import plistlib
        app = Path(folder) / "AIBible.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "AIBible"}, fmt=plistlib.FMT_BINARY))
        (app / "AIBible").write_bytes(b"\x00\xcf\xfa\xed" + marker + b"\x00code")
        (app / "book.private.json").write_bytes(self.BOOK)
        (app / "cover.private.jpg").write_bytes(self.COVER)
        (app / "PrivacyInfo.xcprivacy").write_bytes(b"plist")
        return app

    def run_verify(self, app, cover=True, book_sha=None):
        import hashlib
        args = [str(app), book_sha or hashlib.sha256(self.BOOK).hexdigest()]
        if cover:
            args += ["cover.private.jpg", hashlib.sha256(self.COVER).hexdigest()]
        return subprocess.run(["bash", self.SCRIPT.as_posix(), *args], capture_output=True, text=True)

    def test_passes_a_private_app_and_reports_what_it_checked(self):
        with tempfile.TemporaryDirectory() as folder:
            result = self.run_verify(self.make_app(folder))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("selects the private edition", result.stdout)

    def test_fails_on_any_synthetic_content(self):
        cases = {
            "Fixtures/book.fixture.json": b"{}",
            "presentation-fixture-cover.png": b"png",
            "other.fixture.json": b"{}",
            "notes.json": b'{"isFixture": true}',
        }
        for name, data in cases.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as folder:
                app = self.make_app(folder)
                (app / name).parent.mkdir(parents=True, exist_ok=True)
                (app / name).write_bytes(data)
                result = self.run_verify(app)
                self.assertEqual(result.returncode, 1)
                self.assertIn("synthetic", result.stderr)

    def test_fails_unless_the_executable_selects_the_private_edition(self):
        for marker, expected in ((b"AIBIBLE_EDITION=synthetic-fixture", "lacks the private edition marker"),
                                 (b"AIBIBLE_EDITION=private-book AIBIBLE_EDITION=synthetic-fixture",
                                  "contains the synthetic edition marker")):
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as folder:
                result = self.run_verify(self.make_app(folder, marker=marker))
                self.assertEqual(result.returncode, 1)
                self.assertIn(expected, result.stderr)

    def test_fails_on_a_changed_or_missing_book_or_cover(self):
        with tempfile.TemporaryDirectory() as folder:
            app = self.make_app(folder)
            self.assertIn("differs from the reviewed bundle", self.run_verify(app, book_sha="0" * 64).stderr)
            (app / "cover.private.jpg").write_bytes(b"other")
            self.assertIn("differs from the reviewed cover", self.run_verify(app).stderr)
            (app / "book.private.json").unlink()
            self.assertIn("book.private.json missing", self.run_verify(app, cover=False).stderr)
        self.assertEqual(subprocess.run(["bash", self.SCRIPT.as_posix(), "only-one"], capture_output=True).returncode, 2)

    def test_release_marker_is_compiled_per_edition_and_logged(self):
        source = (self.APP / "AIBible" / "App" / "AppModel.swift").read_text(encoding="utf-8")
        private = source.index('static let editionMarker = "AIBIBLE_EDITION=private-book"')
        synthetic = source.index('static let editionMarker = "AIBIBLE_EDITION=synthetic-fixture"')
        self.assertTrue(source.index("#if AIBIBLE_PRIVATE_BOOK") < private < source.index("#else") < synthetic)
        self.assertIn("AppConfig.editionMarker, privacy: .public", source)
        script = (self.APP / "ci" / "run-tests.sh").read_text(encoding="utf-8")
        self.assertIn("-configuration Release", script)
        self.assertIn('exit "$marker_status"', script)

    def test_staging_strips_samples_and_verifies_both_build_modes(self):
        script = (self.APP / "converter" / "stage-private-build.sh").read_text(encoding="utf-8")
        strip = script.index('rm -rf "$APP/AIBible/Resources/Fixtures"')
        self.assertLess(strip, script.index('"$XCODEGEN" generate'))
        self.assertIn("xcodebuild archive", script)
        self.assertIn("-configuration Release", script)
        self.assertEqual(script.count("ci/verify-private-app.sh\" \"$BUILT\""), 2)
        self.assertIn("codesign --verify", script)
        # It may archive and sign, but never export, upload or submit anything.
        self.assertNotRegex(script, r"altool|notarytool|-exportArchive|upload-app|iTMSTransporter|xcrun +upload")


class ReleasePreflightTests(unittest.TestCase):
    """ci/release-preflight.py refuses placeholder or missing release values without choosing any."""

    APP = Path(__file__).resolve().parent.parent.parent
    SCRIPT = APP / "ci" / "release-preflight.py"
    GOOD_PRODUCT = "org.sample-owner.aibible.fullbook"

    def copy_root(self, folder, bundle="org.sample-owner.aibible", product=GOOD_PRODUCT,
                  privacy='"https://books.sample-owner.org/privacy"', support='"https://books.sample-owner.org/support"',
                  storekit_product=None):
        import shutil
        root = Path(folder) / "app"
        for relative in ("project.yml", "AIBible/App/AppModel.swift", "StoreKit/Products.storekit"):
            (root / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(self.APP / relative, root / relative)
        project = (root / "project.yml").read_text(encoding="utf-8")
        (root / "project.yml").write_text(project.replace("com.example.aibible.app", bundle, 1), encoding="utf-8")
        config = (root / "AIBible/App/AppModel.swift").read_text(encoding="utf-8")
        config = config.replace('fullBookProductID = "com.example.aibible.fullbook"', f'fullBookProductID = "{product}"')
        config = config.replace("privacyPolicyURLString: String? = nil", f"privacyPolicyURLString: String? = {privacy}")
        config = config.replace("supportURLString: String? = nil", f"supportURLString: String? = {support}")
        (root / "AIBible/App/AppModel.swift").write_text(config, encoding="utf-8")
        storekit = json.loads((root / "StoreKit/Products.storekit").read_text(encoding="utf-8"))
        storekit["products"][0]["productID"] = storekit_product or product
        (root / "StoreKit/Products.storekit").write_text(json.dumps(storekit), encoding="utf-8")
        return root

    def run_preflight(self, root, *extra):
        return subprocess.run([sys.executable, self.SCRIPT.as_posix(), "--root", str(root), *extra],
                              capture_output=True, text=True)

    def test_the_committed_placeholders_are_all_refused(self):
        result = self.run_preflight(self.APP)
        self.assertEqual(result.returncode, 1)
        for expected in ("bundle ID from project.yml (AIBible target) is a placeholder: com.example.aibible.app",
                         "fullBookProductID is a placeholder: com.example.aibible.fullbook",
                         "privacyPolicyURLString is not set", "supportURLString is not set"):
            self.assertIn(expected, result.stderr)

    def test_real_looking_values_pass(self):
        with tempfile.TemporaryDirectory() as folder:
            result = self.run_preflight(self.copy_root(folder))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bundle ID org.sample-owner.aibible, product ID " + self.GOOD_PRODUCT, result.stdout)

    def test_each_bad_value_is_refused(self):
        cases = [
            ({"bundle": "com.example.aibible"}, "bundle ID from project.yml (AIBible target) is a placeholder"),
            ({"bundle": "not a bundle id"}, "is not a reverse-DNS identifier"),
            ({"product": "com.example.aibible.fullbook"}, "fullBookProductID is a placeholder"),
            ({"product": "full book!"}, "characters App Store Connect doesn't allow"),
            ({"storekit_product": "org.sample-owner.other"}, "don't match AppConfig.fullBookProductID"),
            ({"privacy": "nil"}, "privacyPolicyURLString is not set"),
            ({"privacy": '"http://books.sample-owner.org/privacy"'}, "privacyPolicyURLString must be an https URL"),
            ({"support": '"https://example.com/support"'}, "supportURLString is a placeholder"),
            ({"support": '"https://localhost/support"'}, "supportURLString"),
            ({"support": '"https://books.sample-owner.org/TODO"'}, "supportURLString is a placeholder"),
        ]
        for overrides, expected in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as folder:
                result = self.run_preflight(self.copy_root(folder, **overrides))
                self.assertEqual(result.returncode, 1)
                self.assertIn(expected, result.stderr)

    def test_bundle_id_override_is_checked_instead_of_project_yml(self):
        with tempfile.TemporaryDirectory() as folder:
            root = self.copy_root(folder, bundle="com.example.aibible.app")
            self.assertEqual(self.run_preflight(root, "--bundle-id", "org.sample-owner.aibible").returncode, 0)
            result = self.run_preflight(root, "--bundle-id", "com.example.other")
            self.assertIn("bundle ID from --bundle-id is a placeholder", result.stderr)

    def test_staging_runs_the_preflight_before_building_and_on_the_archive(self):
        script = (self.APP / "converter" / "stage-private-build.sh").read_text(encoding="utf-8")
        preflight = script.index('python3 "$PREFLIGHT/apps/ai-bible-ios/ci/release-preflight.py"')
        self.assertLess(preflight, script.index('[[ -f "$BOOK" ]]'))
        self.assertIn('release-preflight.py" --root "$APP" --bundle-id "$archived_id"', script)


if __name__ == "__main__":
    unittest.main()
