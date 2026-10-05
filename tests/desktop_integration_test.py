import unittest

from macncheese import desktop


class DesktopIntegrationTests(unittest.TestCase):
    def test_portal_dark_wins(self):
        self.assertEqual(
            desktop.system_color_scheme(env={}, portal={"color-scheme": 1}), "dark")
        self.assertEqual(
            desktop.system_color_scheme(env={}, portal={"color-scheme": 2}), "light")
        self.assertIsNone(
            desktop.system_color_scheme(env={}, portal={"color-scheme": 0},
                                        gsettings=lambda k: None,
                                        kde_config=lambda: None))

    def test_gnome_gsettings(self):
        env = {"XDG_CURRENT_DESKTOP": "GNOME"}
        get = lambda k: "prefer-dark"  # noqa: E731
        self.assertEqual(
            desktop.system_color_scheme(env=env, portal={}, gsettings=get), "dark")

    def test_kde_colorscheme(self):
        env = {"XDG_CURRENT_DESKTOP": "KDE"}
        kde = lambda: {"colorscheme": "BreezeDark"}  # noqa: E731
        self.assertEqual(
            desktop.system_color_scheme(env=env, portal={}, kde_config=kde), "dark")
        kde = lambda: {"colorscheme": "Breeze"}  # noqa: E731
        self.assertEqual(
            desktop.system_color_scheme(env=env, portal={}, kde_config=kde), "light")

    def test_kde_font_parsing(self):
        env = {"XDG_CURRENT_DESKTOP": "KDE"}
        kde = lambda: {"font": "Noto Sans,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"}  # noqa: E731
        self.assertEqual(
            desktop.system_font(env=env, kde_config=kde), ("Noto Sans", 10.0))

    def test_gnome_font_parsing(self):
        env = {"XDG_CURRENT_DESKTOP": "GNOME"}
        get = lambda k: "Cantarell 11"  # noqa: E731
        self.assertEqual(
            desktop.system_font(env=env, gsettings=get), ("Cantarell", 11.0))

    def test_font_css_is_safe(self):
        css = desktop.font_css("Noto Sans', 10); evil(", 10)
        self.assertNotIn(";", css.split("{", 1)[1].split("font-family")[0])
        self.assertIn("font-size: 10.0pt", css)

    def test_unknown_returns_none(self):
        self.assertIsNone(desktop.system_font(env={},
                                              gsettings=lambda k: None,
                                              kde_config=lambda: None))


class AppIconTests(unittest.TestCase):
    def test_icon_install_and_noop(self):
        import os
        import tempfile
        from pathlib import Path
        from unittest.mock import patch
        from macncheese import core
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(os.environ, {"XDG_DATA_HOME": directory}):
                self.assertTrue(core.ensure_app_icon())
                target = Path(directory) / "icons" / "hicolor" / "256x256" / "apps" / "macncheese.png"
                self.assertTrue(target.is_file())
                self.assertFalse(core.ensure_app_icon())


class AppStructureTests(unittest.TestCase):
    """Catch accidental deletion of helpers (regression: _page_sidebar)."""

    def test_critical_helpers_exist(self):
        import ast
        from pathlib import Path
        tree = ast.parse((Path(__file__).resolve().parent.parent
                          / "launcher" / "macncheese" / "app.py").read_text())
        defined = {node.name for node in tree.body
                   if isinstance(node, (ast.FunctionDef, ast.ClassDef))}
        for name in ("_page_sidebar", "_open_uri", "LauncherApp", "LauncherWindow",
                     "PlayPage", "main"):
            self.assertIn(name, defined, f"{name} missing from app.py")
