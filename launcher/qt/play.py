"""Play page: status, Play/Stop, Studio, log tail."""
from PySide6.QtCore import QTimer
from PySide6.QtWidgets import (QHBoxLayout, QLabel, QMessageBox, QPushButton,
                               QTextEdit, QVBoxLayout, QWidget)

from macncheese import core


class PlayPage(QWidget):
    def __init__(self, window):
        super().__init__()
        self.window = window
        layout = QVBoxLayout(self)
        self.status = QLabel()
        self.status.setWordWrap(True)
        layout.addWidget(self.status)

        buttons = QHBoxLayout()
        self.play_btn = QPushButton("Play Roblox")
        self.play_btn.clicked.connect(self._play)
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.clicked.connect(window.stop_roblox)
        self.studio_btn = QPushButton("Roblox Studio")
        self.studio_btn.clicked.connect(self._studio)
        buttons.addWidget(self.play_btn)
        buttons.addWidget(self.stop_btn)
        buttons.addWidget(self.studio_btn)
        layout.addLayout(buttons)

        self.log_view = QTextEdit()
        self.log_view.setReadOnly(True)
        self.log_view.setPlaceholderText("Game log appears here while Roblox runs.")
        layout.addWidget(self.log_view, 1)

        self._tail_timer = QTimer(self)
        self._tail_timer.setInterval(1500)
        self._tail_timer.timeout.connect(self._tail_log)
        self._tail_timer.start()
        self.refresh()

    def _play(self):
        self.window.start_roblox()
        self.refresh()

    def _studio(self):
        from macncheese import studio
        try:
            if studio.needs_install():
                reply = QMessageBox.question(
                    self, "Roblox Studio",
                    "Studio is not installed (~800 MB download). Install now?")
                if reply != QMessageBox.StandardButton.Yes:
                    return
                studio.install()
            studio.launch([])
        except Exception as e:  # noqa: BLE001 - shown to the user
            QMessageBox.critical(self, "Roblox Studio", str(e))

    def refresh(self):
        running = self.window._running()
        version = core.installed_version() or "not installed"
        shim = "ready" if core.shim_built() else "needs build"
        self.status.setText(f"Roblox {version} · shim {shim} · "
                            + ("running" if running else "stopped"))
        self.play_btn.setEnabled(not running)
        self.stop_btn.setEnabled(running)

    def _tail_log(self):
        session = self.window.session
        path = getattr(session, "log_path", None)
        if path is None:
            return
        try:
            text = path.read_text(errors="replace")
        except OSError:
            return
        tail = text[-6000:]
        if self.log_view.toPlainText()[-6000:] != tail:
            self.log_view.setPlainText(tail)
            bar = self.log_view.verticalScrollBar()
            bar.setValue(bar.maximum())
