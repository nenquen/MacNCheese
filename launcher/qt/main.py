"""Main window: sidebar navigation + stacked pages + session handling."""
import sys
import threading
import time
from pathlib import Path

from PySide6.QtCore import QObject, QThread, QTimer, Signal, Slot
from PySide6.QtWidgets import (QApplication, QHBoxLayout, QListWidget,
                               QMainWindow, QMessageBox, QStackedWidget,
                               QWidget)

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from macncheese import core  # noqa: E402
from qt import flags as flags_page  # noqa: E402
from qt import logs as logs_page  # noqa: E402
from qt import play as play_page  # noqa: E402
from qt import settings_page  # noqa: E402
from qt import setup_wizard  # noqa: E402


class Worker(QObject):
    finished = Signal(object)
    progress = Signal(float, str)

    def __init__(self, fn):
        super().__init__()
        self._fn = fn

    @Slot()
    def run(self):
        try:
            self.finished.emit((True, self._fn(self.progress.emit)))
        except Exception as e:  # noqa: BLE001 - shown to the user
            self.finished.emit((False, str(e)))


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Mac'n Cheese")
        self.resize(980, 640)
        self.settings = core.load_settings()
        self.session = None
        self._thread = None

        root = QWidget()
        layout = QHBoxLayout(root)
        self.nav = QListWidget()
        self.nav.setMaximumWidth(160)
        self.stack = QStackedWidget()
        layout.addWidget(self.nav)
        layout.addWidget(self.stack, 1)
        self.setCentralWidget(root)

        self.play = play_page.PlayPage(self)
        self.settings_ui = settings_page.SettingsPage(self)
        self.flags = flags_page.FlagsPage(self)
        self.logs = logs_page.LogsPage(self)
        self.setup = setup_wizard.SetupPage(self)
        for name, page in [("Play", self.play), ("Settings", self.settings_ui),
                           ("Fast flags", self.flags), ("Logs", self.logs)]:
            self.nav.addItem(name)
            self.stack.addWidget(page)
        self.nav.currentRowChanged.connect(self.stack.setCurrentIndex)

        self._poller = QTimer(self)
        self._poller.setInterval(1000)
        self._poller.timeout.connect(self._poll_session)
        self._poller.start()

        if not core.installed_version() and not self.settings.get("setup_complete"):
            self.run_setup()

    # -- settings -----------------------------------------------------
    def save_setting(self, key, value):
        self.settings[key] = value
        core.save_settings(self.settings)

    # -- background work ----------------------------------------------
    def run_background(self, fn, done):
        if self._thread and self._thread.isRunning():
            QMessageBox.information(self, "Mac'n Cheese", "Another operation is in progress.")
            return
        self._thread = QThread(self)
        worker = Worker(fn)
        worker.moveToThread(self._thread)
        worker.finished.connect(lambda r: (self._thread.quit(), done(r)))
        self._thread.started.connect(worker.run)
        self._thread.start()

    # -- setup / update / roblox --------------------------------------
    def run_setup(self):
        dlg = setup_wizard.SetupDialog(self)
        dlg.exec()

    def start_roblox(self):
        self.run_background(self._start_job, self._start_done)

    def _start_job(self, progress):
        missing = core.missing_tools()
        if missing:
            raise RuntimeError("Missing programs: " + ", ".join(missing))
        if not core.shim_built():
            ok, output = core.build_shim()
            if not ok:
                raise RuntimeError("Shim build failed:\n" + output)
        installed = core.installed_version()
        if not installed:
            version, upload = core.latest_version()
            core.update_roblox(upload, progress)
        self.session = core.RobloxSession(self.settings)
        self.session.start()
        return "Roblox started"

    def _start_done(self, result):
        ok, message = result
        if not ok:
            self.session = None
            QMessageBox.critical(self, "Mac'n Cheese", message)
        self.play.refresh()

    def stop_roblox(self):
        session, self.session = self.session, None
        if session is not None:
            threading.Thread(target=self._stop_job, args=(session,),
                             daemon=True).start()
        self.play.refresh()

    @staticmethod
    def _stop_job(session):
        try:
            session.finish()
        except Exception:  # noqa: BLE001 - best effort stop
            pass

    def _poll_session(self):
        if self.session is None:
            return
        try:
            status = self.session.poll()
        except Exception:  # noqa: BLE001 - treat as ended
            status = -1
        if status is not None and status != 0 and not self._running():
            self.session = None
        self.play.refresh()
        self._update_title()

    def _running(self):
        try:
            return self.session is not None and self.session.process is not None \
                and self.session.process.poll() is None
        except Exception:  # noqa: BLE001
            return False

    def _update_title(self):
        base = "Mac'n Cheese"
        self.setWindowTitle(base + (" — Roblox running" if self._running() else ""))

    def closeEvent(self, event):
        if self.session is not None:
            self.hide()
            event.ignore()
            return
        if self._thread and self._thread.isRunning():
            self.hide()
            event.ignore()
            return
        event.accept()


def main():
    app = QApplication(sys.argv)
    app.setApplicationName("Mac'n Cheese")
    app.setOrganizationName("macncheese")
    window = MainWindow()
    window.show()
    return app.exec()
