import copy
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from PyQt6.QtCore import QTimer, Qt
from PyQt6.QtGui import QPalette, QColor
from PyQt6.QtTest import QTest
from PyQt6.QtWidgets import QApplication, QMessageBox, QInputDialog, QFileDialog
import backend
from window import MainWindow, apply_light_theme
from test_backend import source_at


APP = QApplication.instance() or QApplication([])
APP.setStyle("Fusion")


class WindowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="desktop-ui-test-")
        self.root = Path(self.temp.name)
        self.store = backend.Store(self.root / "state")
        self.store.add_project(self.root, "我的项目对话", "codex-fixture-id")
        self.window = MainWindow(self.store, auto_discover=False)
        self.window.show()
        QTest.qWait(20)

    def tearDown(self):
        self.window.pool.waitForDone(10000)
        APP.processEvents()
        self.window.busy = False
        self.window._allow_exit = True
        self.window.close()
        self.window.deleteLater()
        APP.processEvents()
        self.temp.cleanup()

    def wait_until(self, predicate, timeout=5000):
        deadline = time.monotonic() + timeout / 1000
        while not predicate() and time.monotonic() < deadline:
            QTest.qWait(20)
        self.assertTrue(predicate())

    def connected(self, limited=False):
        state = {"online": True, "limited": limited, "active": 1, "url": "http://127.0.0.1:4317",
                 "settings": {"revision": 2, "mode": "dsh-default", "effective": {"provider": "p", "model": "m1"},
                              "providers": [{"id": "p", "models": [{"id": "m1"}, {"id": "m2"}]},
                                            {"id": "q", "models": [{"id": "q1"}]}]},
                 "runs": [{"id": "r", "title": "测试任务", "status": "running", "sessionId": "fixture-dsh-session"}]}
        self.window.snapshots[str(self.root)] = state
        self.window.reload_projects()
        return state

    def test_project_team_and_native_session_need_no_manual_conversation(self):
        self.connected()
        self.assertIn("无需关联对话", self.window.conversation.text())
        self.assertFalse(hasattr(self.window, "associate_button"))
        self.assertEqual(self.window.table.item(0, 2).text(), "fixture-dsh-session")
        self.assertEqual(self.window.address.text(), "http://127.0.0.1:4317")
        self.assertEqual(self.window.stat_labels[1].text(), "1")

    def test_periodic_refresh_preserves_unsubmitted_model_choice(self):
        state = self.connected()
        self.window.model_combo.setCurrentIndex(1)
        self.window.snapshots[str(self.root)] = copy.deepcopy(state)
        self.window.reload_projects()
        self.assertEqual(self.window.model_combo.currentData(), "m2")
        self.window.snapshots[str(self.root)]["settings"]["revision"] = 3
        self.window.project_changed()
        self.assertEqual(self.window.model_combo.currentData(), "m1")

    def test_legacy_monitor_can_stop_locally_but_not_modify_model_or_sync(self):
        self.connected(limited=True)
        self.assertTrue(self.window.open_button.isEnabled())
        self.assertTrue(self.window.stop_button.isEnabled())
        for item in (self.window.sync_button, self.window.apply_model, self.window.follow_default):
            self.assertFalse(item.isEnabled())
        self.assertIn("概览", self.window.connection.text())
        self.assertIn("旧版", self.window.model_status.text())

    def test_offline_model_preview_explains_connection_and_never_saves_to_monitor(self):
        self.window.display_source(backend.read_source(source_at(self.root / "source")))
        self.assertEqual(self.window.provider_combo.currentData(), "chosen-provider")
        self.assertEqual(self.window.model_combo.currentData(), "chosen-model")
        self.assertTrue(self.window.provider_combo.isEnabled())
        self.assertFalse(self.window.apply_model.isEnabled())
        self.assertFalse(self.window.follow_default.isEnabled())
        self.assertFalse(self.window.connect_model.isHidden())
        self.assertIn("预览", self.window.model_status.text())
        self.window.provider_combo.setCurrentIndex(0)
        with patch("window.MonitorClient") as client:
            self.window.save_model()
            client.assert_not_called()
        self.connected()
        self.assertTrue(self.window.apply_model.isEnabled())
        self.assertEqual(self.window.provider_combo.currentData(), "p")
        self.assertTrue(self.window.connect_model.isHidden())

    def test_auto_search_one_result_remembers_default_without_dialog_and_is_responsive(self):
        row = dict(backend.read_source(source_at(self.root / "source")), source="DSH_HOME")
        original = (Path(row["directory"]) / "settings.yaml").read_bytes()
        beats = []
        timer = QTimer()
        timer.setInterval(15)
        timer.timeout.connect(lambda: beats.append(1))
        timer.start()
        def candidates():
            time.sleep(.22)
            return [row]
        with patch.object(self.store, "candidates", side_effect=candidates) as search, patch("window.QInputDialog.getItem") as dialog:
            self.window.find_source()
            self.window.find_source()
            self.assertFalse(self.window.detect_source.isEnabled())
            self.wait_until(lambda: not self.window.searching_source)
            self.assertEqual(search.call_count, 1)
            dialog.assert_not_called()
        timer.stop()
        self.assertGreater(len(beats), 3)
        self.assertEqual(self.store.saved_source(), row["directory"])
        self.assertEqual(self.window.source["model"], "chosen-model")
        self.assertEqual(original, (Path(row["directory"]) / "settings.yaml").read_bytes())
        self.assertTrue(self.window.detect_source.property("primary"))
        self.assertFalse(self.window.browse_source.property("primary"))

    def test_multiple_sources_require_selection_and_cancellation_preserves_saved_choice(self):
        first = dict(backend.read_source(source_at(self.root / "first")), source="DSH_HOME")
        second = dict(backend.read_source(source_at(self.root / "second")), source="用户默认目录")
        def choose(_parent, _title, _prompt, options, *_):
            self.assertIn("chosen-provider / chosen-model", options[1])
            return options[1], True
        with patch.object(self.store, "candidates", return_value=[first, second]), patch("window.QInputDialog.getItem", side_effect=choose):
            self.window.find_source()
            self.wait_until(lambda: not self.window.searching_source)
        self.assertEqual(self.store.saved_source(), second["directory"])
        with patch.object(self.store, "candidates", return_value=[first, second]), patch("window.QInputDialog.getItem", return_value=("", False)):
            self.window.find_source()
            self.wait_until(lambda: not self.window.searching_source)
        self.assertEqual(self.store.saved_source(), second["directory"])

    def test_no_source_and_ambiguous_startup_guide_user_without_opening_browser(self):
        row = dict(backend.read_source(source_at(self.root / "source")), source="DSH_HOME")
        with patch.object(self.store, "candidates", return_value=[]), patch("window.QFileDialog.getExistingDirectory") as browse:
            self.window.find_source()
            self.wait_until(lambda: not self.window.searching_source)
            self.assertIn("手动选择目录", self.window.source_status.text())
            browse.assert_not_called()
        with patch.object(self.store, "candidates", return_value=[row, dict(row, directory="other")]), patch("window.QInputDialog.getItem") as dialog:
            self.window.load_source()
            self.wait_until(lambda: not self.window.searching_source)
            dialog.assert_not_called()
        self.assertIsNone(self.window.source)
        self.assertIsNone(self.store.saved_source())

    def test_startup_does_not_replace_broken_saved_source(self):
        saved = dict(directory=str(self.root / "missing"), source="上次选择", error="配置已移动", provider="", model="")
        valid = dict(backend.read_source(source_at(self.root / "source")), source="DSH_HOME")
        with patch.object(self.store, "candidates", return_value=[saved, valid]), patch.object(self.store, "set_source") as save:
            self.window.load_source()
            self.wait_until(lambda: not self.window.searching_source)
            save.assert_not_called()
        self.assertTrue(self.window.source["error"])
        self.assertIn("尚未切换", self.window.source_status.text())

    def test_all_dialogs_use_white_background_even_with_dark_system_palette(self):
        dark = QPalette()
        dark.setColor(QPalette.ColorRole.Window, QColor("#202020"))
        APP.setPalette(dark)
        APP.styleHints().setColorScheme(Qt.ColorScheme.Dark)
        apply_light_theme(APP)
        for dialog in (QInputDialog(self.window), QMessageBox(self.window), QFileDialog(self.window)):
            if isinstance(dialog, QFileDialog):
                dialog.setOption(QFileDialog.Option.DontUseNativeDialog)
            dialog.show()
            QTest.qWait(20)
            self.assertEqual(dialog.palette().color(QPalette.ColorRole.Window).name(), "#ffffff")
            corner = dialog.grab().toImage().pixelColor(3, 3)
            self.assertGreater(min(corner.red(), corner.green(), corner.blue()), 240)
            dialog.close()
            dialog.deleteLater()

    def test_start_never_installs_and_missing_dependencies_require_separate_action(self):
        self.window.display_source(backend.read_source(source_at(self.root / "source")))
        self.wait_until(lambda: not self.window.checking_projects)
        with patch("window.readiness", return_value={"ready": False}), patch("window.existing_monitor", return_value=None), patch.object(self.window, "next_process") as start:
            self.window.start_monitor()
            self.wait_until(lambda: not self.window.busy)
            start.assert_not_called()
            self.assertIn("先点击", self.window.logs.toPlainText())
        with patch("window.readiness", return_value={"ready": True}), patch("window.existing_monitor", return_value=None), patch.object(self.window, "next_process") as start:
            self.window.start_monitor()
            self.wait_until(lambda: start.called)
            self.assertEqual(len(self.window.queue), 1)
            self.assertIn("Start", self.window.queue[0][1])

    def test_install_is_separate_and_keeps_existing_dependencies_when_updating(self):
        self.wait_until(lambda: not self.window.checking_projects)
        ready = dict(nodeReady=True, npm="npm.cmd", installed=False, dependencies=False)
        with patch("window.readiness", side_effect=lambda _: dict(ready)), patch("window.existing_monitor", return_value=None), patch("window.bundled_toolkit", return_value=self.root), patch.object(self.window, "next_process") as run, patch("window.QMessageBox.question", return_value=QMessageBox.StandardButton.Yes) as question:
            self.window.install_dependencies()
            self.wait_until(lambda: run.called)
            self.assertIn("npm 下载", question.call_args.args[2])
            self.assertEqual([q[1][q[1].index("-Action")+1] for q in self.window.queue], ["Install", "Prepare"])
            self.window.set_busy(False)
            ready.update(installed=True, dependencies=True, updateAvailable=True)
            run.reset_mock()
            self.window.install_dependencies()
            self.wait_until(lambda: run.called)
            self.assertEqual([q[1][q[1].index("-Action")+1] for q in self.window.queue], ["Install"])

    def test_project_check_is_automatic_async_and_gates_buttons(self):
        self.wait_until(lambda: not self.window.checking_projects)
        ready = dict(ready=True, nodeReady=True, npm="npm.cmd", installed=True,
                     dependencies=True, dependencyPresent=True, nodeVersion="v24.16.0")
        def slow(_):
            time.sleep(.2)
            return ready
        beats = []
        timer = QTimer()
        timer.setInterval(15)
        timer.timeout.connect(lambda: beats.append(1))
        timer.start()
        with patch("window.readiness", side_effect=slow):
            self.window.check_project()
            self.assertIn("正在检查", self.window.preparation_status.text())
            self.assertFalse(self.window.install_button.isEnabled())
            self.wait_until(lambda: not self.window.checking_projects)
        timer.stop()
        self.assertGreater(len(beats), 3)
        self.assertTrue(self.window.start_button.isEnabled())
        self.assertFalse(self.window.install_button.isEnabled())
        self.assertTrue(self.window.uninstall_button.isEnabled())
        self.connected()
        self.assertFalse(self.window.uninstall_button.isEnabled())

    def test_uninstall_requires_confirmation_and_only_queues_dependency_removal(self):
        with patch("window.QMessageBox.question", return_value=QMessageBox.StandardButton.No), patch.object(self.window, "next_process") as run:
            self.window.uninstall_dependencies()
            run.assert_not_called()
        with patch("window.QMessageBox.question", return_value=QMessageBox.StandardButton.Yes), patch.object(self.window, "next_process"):
            self.window.uninstall_dependencies()
            self.assertEqual(len(self.window.queue), 1)
            self.assertIn("RemoveDependencies", self.window.queue[0][1])

    def test_directory_browser_saves_source_and_cancel_preserves_it(self):
        source = source_at(self.root / "my-dsh")
        with patch("window.QFileDialog.getExistingDirectory", return_value=str(source)) as dialog:
            self.window.choose_source()
        self.assertIn("settings.yaml", dialog.call_args.args[1])
        self.assertEqual(dialog.call_args.args[2], str(backend.program_directory()))
        self.assertEqual(self.window.source["provider"], "chosen-provider")
        saved = (self.store.base / "user-settings-source.json").read_bytes()
        with patch("window.QFileDialog.getExistingDirectory", return_value=""):
            self.window.choose_source()
        self.assertEqual(saved, (self.store.base / "user-settings-source.json").read_bytes())

    def test_slow_connection_check_keeps_window_responsive_and_reuses_monitor(self):
        self.window.display_source(backend.read_source(source_at(self.root / "source")))
        beats = []
        timer = QTimer()
        timer.setInterval(15)
        timer.timeout.connect(lambda: beats.append(True))
        timer.start()

        def slow_check(_):
            time.sleep(0.25)
            return {"online": True, "url": "http://127.0.0.1:4317", "runs": [], "settings": {}}

        with patch("window.existing_monitor", side_effect=slow_check), patch.object(self.window, "prepare_monitor") as prepare:
            self.window.start_monitor()
            self.wait_until(lambda: not self.window.busy)
            prepare.assert_not_called()
        timer.stop()
        self.assertGreater(len(beats), 3)
        self.assertIn("复用", self.window.logs.toPlainText())

    def test_process_progress_handles_split_utf8_and_reports_success(self):
        script = self.root / "fake-operation.py"
        script.write_text("import os, time\nos.write(1, b'@@TK_PROGRESS@@|apply|1|2\\n')\npayload='中文已完成\\n'.encode()\nos.write(1, payload[:2])\ntime.sleep(.08)\nos.write(1, payload[2:])\n", encoding="utf-8")
        self.window.queue = [("验证操作", [sys.executable, str(script)])]
        self.window.set_busy(True)
        self.window.next_process()
        self.wait_until(lambda: not self.window.busy)
        self.assertIn("中文已完成", self.window.logs.toPlainText())
        self.assertNotIn("�", self.window.logs.toPlainText())
        self.assertEqual(self.window.progress.value(), 100)
        self.assertEqual(self.window.job_label.text(), "已完成")

    def test_failed_stage_does_not_run_next_stage_and_window_stays_open(self):
        self.window.queue = [("故障注入", [sys.executable, "-c", "raise SystemExit(7)"]),
                             ("不得运行", [sys.executable, "-c", "print('SHOULD-NOT-RUN')"])]
        self.window.set_busy(True)
        self.window.next_process()
        self.wait_until(lambda: not self.window.busy)
        self.assertEqual(self.window.job_label.text(), "操作未完成")
        self.assertNotIn("SHOULD-NOT-RUN", self.window.logs.toPlainText())
        self.assertTrue(self.window.isVisible())

    def test_closing_during_operation_does_not_interrupt_it(self):
        self.window.set_busy(True)
        self.window.close()
        self.assertTrue(self.window.isVisible())
        self.window.set_busy(False)

    def test_offline_process_has_visible_stop_button_and_status(self):
        self.window.snapshots[str(self.root)] = {"online": False, "canStop": True, "active": 0, "runs": []}
        self.window.project_changed()
        self.assertIn("后台仍在运行", self.window.connection.text())
        self.assertTrue(self.window.stop_button.isEnabled())

    def test_close_can_keep_background_or_cancel(self):
        self.connected()
        with patch.object(self.window, "confirm_background_exit", return_value="cancel"), patch.object(self.window, "stop_projects") as stop:
            self.window.close()
            self.assertTrue(self.window.isVisible())
            stop.assert_not_called()
        with patch.object(self.window, "confirm_background_exit", return_value="keep"), patch.object(self.window, "stop_projects") as stop:
            self.window.close()
            self.assertFalse(self.window.isVisible())
            stop.assert_not_called()

    def test_close_with_stop_waits_for_completion_then_exits(self):
        self.connected()
        with patch.object(self.window, "confirm_background_exit", return_value="stop"), patch("window.stop_command", return_value=[sys.executable, "-c", "import time;time.sleep(.1)"]):
            self.window.close()
            self.assertTrue(self.window.isVisible())
            self.assertTrue(self.window.busy)
            self.wait_until(lambda: not self.window.isVisible())
        self.assertFalse(self.window.state()["online"])
        self.assertIn("占用已释放", self.window.logs.toPlainText())

    def test_failed_stop_keeps_desktop_open(self):
        self.connected()
        with patch.object(self.window, "confirm_background_exit", return_value="stop"), patch("window.stop_command", return_value=[sys.executable, "-c", "raise SystemExit(7)"]):
            self.window.close()
            self.wait_until(lambda: not self.window.busy)
        self.assertTrue(self.window.isVisible())
        self.assertFalse(self.window._allow_exit)
        self.assertFalse(self.window._closing_after_stop)


if __name__ == "__main__":
    unittest.main()
