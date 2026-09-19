import copy
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from PyQt6.QtCore import QTimer
from PyQt6.QtTest import QTest
from PyQt6.QtWidgets import QApplication, QMessageBox
import backend
from window import MainWindow
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

    def test_project_conversation_and_native_session_are_visible(self):
        self.connected()
        self.assertIn("我的项目对话", self.window.conversation.text())
        self.assertEqual(self.window.conversation.toolTip(), "codex-fixture-id")
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

    def test_legacy_monitor_can_open_but_not_mutate(self):
        self.connected(limited=True)
        self.assertTrue(self.window.open_button.isEnabled())
        for item in (self.window.sync_button, self.window.stop_button, self.window.apply_model, self.window.follow_default):
            self.assertFalse(item.isEnabled())
        self.assertIn("概览", self.window.connection.text())

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


if __name__ == "__main__":
    unittest.main()
