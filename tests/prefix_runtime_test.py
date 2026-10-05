import tempfile
from dataclasses import replace
import unittest
from pathlib import Path
from unittest.mock import patch

from macoblox import core, darling_patches
from darling_patches_test import image_fixture, release_for


class PrefixRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.prefix = base / "prefix"
        self.sysroot = base / "sysroot"
        self.native = base / "build" / "native"
        self.relative = Path("usr/lib/system/libsystem_c.dylib")
        self.stock = self.sysroot / self.relative
        self.stock.parent.mkdir(parents=True)
        self.stock.write_bytes(b"stock")
        for name, value in (("DARLING_PREFIX", self.prefix),
                            ("DARLING_SYSROOT", self.sysroot),
                            ("NATIVE_BUILD", self.native)):
            context = patch.object(core, name, value)
            context.start()
            self.addCleanup(context.stop)

    def test_unknown_stock_is_preserved(self):
        with patch.object(darling_patches, "install_sparse_map_copy") as install:
            self.assertEqual(core._patched_kqueue_runtime(), [])
            install.assert_not_called()
        self.assertEqual(self.stock.read_bytes(), b"stock")

    def test_existing_unknown_prefix_override_wins_over_stock(self):
        installed = self.prefix / self.relative
        installed.parent.mkdir(parents=True)
        installed.write_bytes(b"custom")
        with patch.object(darling_patches, "plan_sparse_map_patch",
                          return_value=("unsupported", None)) as plan:
            self.assertEqual(core._patched_kqueue_runtime(), [])
            plan.assert_called_once_with(b"custom", library=self.relative.as_posix())
        self.assertEqual(installed.read_bytes(), b"custom")

    def test_known_repaired_prefix_needs_no_restart(self):
        installed = self.prefix / self.relative
        installed.parent.mkdir(parents=True)
        installed.write_bytes(b"repaired")
        with patch.object(darling_patches, "plan_sparse_map_patch",
                          return_value=("already patched", None)), \
                patch.object(darling_patches, "install_sparse_map_copy") as install:
            self.assertEqual(core._patched_kqueue_runtime(), [])
            install.assert_not_called()

    def test_library_symlinks_and_parent_escape_are_preserved(self):
        self.prefix.mkdir()
        (self.prefix / "usr").symlink_to(self.sysroot / "usr", target_is_directory=True)
        with patch.object(darling_patches, "plan_sparse_map_patch") as plan:
            self.assertEqual(core._patched_kqueue_runtime(), [])
            plan.assert_not_called()

    def test_stage_is_validated_and_installed_through_atomic_copy_helper(self):
        def stage(source, destination, *, library):
            self.assertEqual(source, self.stock)
            self.assertEqual(library, self.relative.as_posix())
            destination.parent.mkdir(parents=True)
            destination.write_bytes(b"repaired")
            return "patched"

        with patch.object(darling_patches, "plan_sparse_map_patch",
                          side_effect=lambda data, **_: ("patched", b"repaired") if data == b"stock"
                          else ("already patched", None)), \
                patch.object(darling_patches, "install_sparse_map_copy", side_effect=stage):
            libraries = core._patched_kqueue_runtime()
        self.assertEqual(libraries, [(self.relative, self.native / "libsystem_c.dylib")])
        self.prefix.mkdir()
        with patch.object(core, "_missing_frameworks", return_value=[]), \
                patch.object(core, "_patched_ffmpeg_bridges", return_value=[]), \
                patch.object(core, "_patched_kqueue_runtime", return_value=libraries), \
                patch.object(core, "darlingserver_running", return_value=False), \
                patch.object(core, "restart_darling") as restart, \
                patch.object(darling_patches, "install_sparse_map_copy", return_value="patched") as install:
            core.prepare_prefix({})
            install.assert_called_once_with(libraries[0][1], self.prefix / self.relative,
                                           library=self.relative.as_posix())
            restart.assert_not_called()

    def test_both_independent_kqueue_libraries_are_staged(self):
        base_library = self.sysroot / "usr/lib/libSystem.B.dylib"
        base_library.parent.mkdir(parents=True, exist_ok=True)
        base_library.write_bytes(b"stock")

        def stage(source, destination, *, library):
            self.assertIn(source, (base_library, self.stock))
            self.assertEqual(source.name, destination.name)
            self.assertEqual(library, source.relative_to(self.sysroot).as_posix())
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(b"repaired")
            return "patched"

        with patch.object(darling_patches, "plan_sparse_map_patch",
                          side_effect=lambda data, **_: ("patched", b"repaired") if data == b"stock"
                          else ("already patched", None)), \
                patch.object(darling_patches, "install_sparse_map_copy", side_effect=stage):
            libraries = core._patched_kqueue_runtime()
        self.assertEqual(libraries, [
            (Path("usr/lib/libSystem.B.dylib"), self.native / "libSystem.B.dylib"),
            (self.relative, self.native / "libsystem_c.dylib"),
        ])

    def test_wrong_family_staged_and_installed_libraries_are_preserved(self):
        data=image_fixture()
        other=bytearray(data); other[-1]^=1; other=bytes(other)
        release=replace(release_for(data), library=self.relative.as_posix())
        other_release=replace(release_for(other), library="usr/lib/libSystem.B.dylib")
        planner=darling_patches.plan_sparse_map_patch
        def plan(value, *, library=None):
            return planner(value, (release, other_release), library=library)
        self.stock.write_bytes(data)
        staged=self.native/self.relative.name
        staged.parent.mkdir(parents=True)
        wrong=plan(other)[1]
        staged.write_bytes(wrong)
        with patch.object(darling_patches, "plan_sparse_map_patch", side_effect=plan):
            self.assertEqual(core._patched_kqueue_runtime(), [])
        self.assertEqual(staged.read_bytes(), wrong)
        installed=self.prefix/self.relative
        installed.parent.mkdir(parents=True)
        for state in (other, wrong):
            installed.write_bytes(state)
            with patch.object(darling_patches, "plan_sparse_map_patch", side_effect=plan):
                self.assertEqual(core._patched_kqueue_runtime(), [])
            self.assertEqual(installed.read_bytes(), state)
        self.assertEqual(self.stock.read_bytes(), data)
