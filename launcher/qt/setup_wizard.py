"""First-run setup: progress dialog running the install chain."""
from PySide6.QtCore import QObject, QThread, Signal, Slot
from PySide6.QtWidgets import (QDialog, QLabel, QProgressBar, QVBoxLayout)


class SetupWorker(QObject):
    progress = Signal(float, str)
    finished = Signal(object)

    def __init__(self, window):
        super().__init__()
        self.window = window

    @Slot()
    def run(self):
        from macncheese import core
        try:
            missing = core.missing_tools()
            if missing:
                raise RuntimeError("Install these first: " + ", ".join(missing))
            self.progress.emit(0.2, "Checking for Roblox updates…")
            installed = core.installed_version()
            if not installed:
                version, upload = core.latest_version()
                self.progress.emit(0.3, f"Downloading Roblox {version}…")
                core.update_roblox(upload, lambda f, m: self.progress.emit(0.3 + 0.5 * f, m))
            if not core.shim_built():
                self.progress.emit(0.85, "Building compatibility libraries…")
                ok, output = core.build_shim()
                if not ok:
                    raise RuntimeError("Shim build failed:\n" + output)
            self.window.settings["setup_complete"] = True
            core.save_settings(self.window.settings)
            self.finished.emit((True, "Setup complete"))
        except Exception as e:  # noqa: BLE001 - shown to the user
            self.finished.emit((False, str(e)))


class SetupDialog(QDialog):
    def __init__(self, window):
        super().__init__(window)
        self.setWindowTitle("Mac'n Cheese setup")
        self.setMinimumWidth(420)
        layout = QVBoxLayout(self)
        self.label = QLabel("Preparing Roblox…")
        self.label.setWordWrap(True)
        self.bar = QProgressBar()
        self.bar.setRange(0, 100)
        layout.addWidget(self.label)
        layout.addWidget(self.bar)

        self._thread = QThread(self)
        self._worker = SetupWorker(window)
        self._worker.moveToThread(self._thread)
        self._worker.progress.connect(self._on_progress)
        self._worker.finished.connect(self._on_finished)
        self._thread.started.connect(self._worker.run)
        self._thread.start()

    def _on_progress(self, fraction, message):
        self.bar.setValue(int(fraction * 100))
        self.label.setText(message)

    def _on_finished(self, result):
        _ok, _message = result
        self._thread.quit()
        self._thread.wait()
        self.accept()


class SetupPage:
    """Placeholder so MainWindow can always construct pages."""
    def __init__(self, window):
        self.window = window
