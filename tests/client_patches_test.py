import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from macncheese import core


def make_bundle(directory, version="0.741.0.7411056"):
    bundle = Path(directory) / "RobloxPlayer.app" / "Contents"
    bundle.mkdir(parents=True, exist_ok=True)
    with open(bundle / "Info.plist", "wb") as file:
        plistlib.dump({"CFBundleShortVersionString": version}, file)
    return Path(directory) / "RobloxPlayer.app"


class ClientPatchStampTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bundle = make_bundle(self.tmp.name)
        self.settings_file = Path(self.tmp.name) / "settings.json"
        self.stamp = Path(self.tmp.name) / "client-patches.json"
        self.settings_file.write_text(json.dumps({"auto_patch_throttle": True}))
        patches = (patch.object(core, "APP_BUNDLE", self.bundle),
                    patch.object(core, "SETTINGS_FILE", self.settings_file),
                    patch.object(core, "PATCH_STAMP", self.stamp))
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def test_no_stamp_is_not_current(self):
        self.assertFalse(core.client_patches_current())

    def test_mark_makes_current(self):
        core.mark_client_patches()
        self.assertTrue(core.client_patches_current())
        stamp = json.loads(self.stamp.read_text())
        self.assertEqual(stamp["version"], "0.741.0.7411056")
        self.assertTrue(stamp["done"])

    def test_client_update_invalidates(self):
        core.mark_client_patches()
        make_bundle(self.tmp.name, version="0.742.0.7420000")
        self.assertFalse(core.client_patches_current())

    def test_toggle_invalidates(self):
        core.mark_client_patches()
        self.assertTrue(core.client_patches_current())
        self.settings_file.write_text(json.dumps({"auto_patch_throttle": False}))
        self.assertFalse(core.client_patches_current())

    def test_missing_bundle_is_not_current(self):
        core.mark_client_patches()
        (self.bundle / "Contents" / "Info.plist").unlink()
        self.assertFalse(core.client_patches_current())

    def test_flags_still_applied_when_binary_skipped(self):
        flags_file = Path(self.tmp.name) / "flags.json"
        flags_file.write_text(json.dumps({}))
        with patch.object(core, "FAST_FLAGS", flags_file):
            core.ensure_raknet_transport(binary=False)
        flags = json.loads(flags_file.read_text())
        self.assertEqual(flags.get("FFlagUseRbxTransportClient"), "False")
        self.assertEqual(flags.get("DFFlagHttpLocalThrottle"), "False")
