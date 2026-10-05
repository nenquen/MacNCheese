"""Fast flags page: JSON editor with validation and reset."""
import json

from PySide6.QtWidgets import (QHBoxLayout, QMessageBox, QPushButton,
                               QTextEdit, QVBoxLayout, QWidget)

from macncheese import core


class FlagsPage(QWidget):
    def __init__(self, window):
        super().__init__()
        self.window = window
        layout = QVBoxLayout(self)
        self.editor = QTextEdit()
        self.editor.setPlaceholderText('{\n  "DFIntTaskSchedulerTargetFps": 60\n}')
        try:
            self.editor.setPlainText(
                json.dumps(core.load_fast_flags(), indent=2, ensure_ascii=False))
        except Exception:  # noqa: BLE001 - start empty instead
            pass
        layout.addWidget(self.editor, 1)

        buttons = QHBoxLayout()
        save = QPushButton("Save")
        save.clicked.connect(self._save)
        reset = QPushButton("Reset to empty")
        reset.clicked.connect(self._reset)
        reload = QPushButton("Reload")
        reload.clicked.connect(self._reload)
        buttons.addWidget(save)
        buttons.addWidget(reset)
        buttons.addWidget(reload)
        layout.addLayout(buttons)

    def _save(self):
        try:
            flags = json.loads(self.editor.toPlainText() or "{}")
        except ValueError as e:
            QMessageBox.warning(self, "Fast flags", f"Invalid JSON: {e}")
            return
        if not isinstance(flags, dict):
            QMessageBox.warning(self, "Fast flags", "Top level must be an object.")
            return
        try:
            core.save_fast_flags(flags)
        except OSError as e:
            QMessageBox.critical(self, "Fast flags", str(e))
            return
        QMessageBox.information(self, "Fast flags", "Saved. Applies on next launch.")

    def _reset(self):
        self.editor.setPlainText("{}")

    def _reload(self):
        try:
            self.editor.setPlainText(
                json.dumps(core.load_fast_flags(), indent=2, ensure_ascii=False))
        except Exception as e:  # noqa: BLE001 - shown to the user
            QMessageBox.critical(self, "Fast flags", str(e))
