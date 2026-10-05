"""Settings page: form bound straight to core settings."""
from PySide6.QtWidgets import (QCheckBox, QComboBox, QFormLayout, QHBoxLayout,
                               QLabel, QSlider, QWidget)

from macncheese import core
from macncheese.display import validated_dpi_scale


class SettingsPage(QWidget):
    def __init__(self, window):
        super().__init__()
        self.window = window
        form = QFormLayout(self)
        settings = window.settings

        self.renderer = QComboBox()
        self.renderer.addItems(["opengl", "vulkan"])
        self.renderer.setCurrentText(settings.get("renderer", "opengl"))
        self.renderer.setToolTip("Vulkan (Zink) is experimental")
        self.renderer.currentTextChanged.connect(
            lambda v: window.save_setting("renderer", v))
        form.addRow("Renderer", self.renderer)

        dpi_row, self.dpi, self.dpi_label = self._slider(100, 400, 5)
        self.dpi.setValue(int(validated_dpi_scale(settings.get("dpi_scale", 1.0)) * 100))
        self.dpi.valueChanged.connect(self._dpi_changed)
        self._dpi_text()
        form.addRow("Roblox UI scale (%)", dpi_row)

        sens_row, self.sens, self.sens_label = self._slider(10, 500, 5, decimals=2)
        self.sens.setValue(int(float(settings.get("mouse_sensitivity", 1.0)) * 100))
        self.sens.valueChanged.connect(self._sens_changed)
        self._sens_text()
        form.addRow("Camera sensitivity", sens_row)

        self.dns = QComboBox()
        self.dns.addItems(["system", "quad9", "cloudflare", "custom"])
        self.dns.setCurrentText(settings.get("dns", "system"))
        self.dns.currentTextChanged.connect(lambda v: window.save_setting("dns", v))
        form.addRow("DNS for Roblox", self.dns)

        for key, label in [
                ("raw_mouse", "Raw mouse input (camera)"),
                ("hide_menu_bar", "Hide the macOS menu bar"),
                ("mangohud", "MangoHud overlay"),
                ("follow_system_theme", "Follow system light/dark mode"),
                ("use_system_font", "Use system interface font"),
                ("discord_rpc", "Discord Rich Presence")]:
            box = QCheckBox()
            box.setChecked(bool(settings.get(key, key != "mangohud")))
            box.stateChanged.connect(
                lambda _state, k=key, b=box: window.save_setting(k, b.isChecked()))
            form.addRow(label, box)

    @staticmethod
    def _slider(low, high, step, decimals=0):
        row = QWidget()
        layout = QHBoxLayout(row)
        layout.setContentsMargins(0, 0, 0, 0)
        slider = QSlider()
        from PySide6.QtCore import Qt
        slider.setOrientation(Qt.Orientation.Horizontal)
        slider.setRange(low, high)
        slider.setSingleStep(step)
        label = QLabel()
        layout.addWidget(slider, 1)
        layout.addWidget(label)
        slider._decimals = decimals
        return row, slider, label

    def _dpi_changed(self, value):
        self.window.save_setting("dpi_scale", validated_dpi_scale(value / 100))
        self.window.save_setting("dpi_scale_auto", False)
        self._dpi_text()

    def _dpi_text(self):
        self.dpi_label.setText(f"{self.dpi.value()}%")

    def _sens_changed(self, value):
        self.window.save_setting("mouse_sensitivity", round(value / 100, 2))
        self._sens_text()

    def _sens_text(self):
        self.sens_label.setText(f"{self.sens.value() / 100:.2f}")
