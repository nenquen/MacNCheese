"""Logs page: pick a launch log, read the tail."""
from PySide6.QtWidgets import (QHBoxLayout, QListWidget, QPushButton,
                               QTextEdit, QVBoxLayout, QWidget)

from macncheese import core


class LogsPage(QWidget):
    def __init__(self, window):
        super().__init__()
        layout = QVBoxLayout(self)
        top = QHBoxLayout()
        self.list = QListWidget()
        self.list.setMaximumWidth(240)
        self.list.currentRowChanged.connect(self._show)
        refresh = QPushButton("Refresh")
        refresh.clicked.connect(self._reload)
        top.addWidget(self.list, 1)
        top.addWidget(refresh)
        layout.addLayout(top)
        self.view = QTextEdit()
        self.view.setReadOnly(True)
        layout.addWidget(self.view, 1)
        self._reload()

    def _files(self):
        try:
            logs = sorted(core.LOGS.glob("launch-*.log"), reverse=True)[:30]
        except OSError:
            logs = []
        return logs

    def _reload(self):
        self._files_cache = self._files()
        self.list.clear()
        self.list.addItems([p.name for p in self._files_cache])
        if self._files_cache:
            self.list.setCurrentRow(0)

    def _show(self, row):
        if 0 <= row < len(getattr(self, "_files_cache", [])):
            try:
                text = self._files_cache[row].read_text(errors="replace")
            except OSError:
                text = ""
            self.view.setPlainText(text[-30000:])
