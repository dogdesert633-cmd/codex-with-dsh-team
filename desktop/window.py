from __future__ import annotations

from datetime import datetime
from pathlib import Path
import json
import codecs

from PyQt6.QtCore import QObject, QRunnable, QThreadPool, pyqtSignal, Qt, QTimer, QProcess, QUrl
from PyQt6.QtGui import QDesktopServices, QColor, QFont
from PyQt6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QFrame, QLabel, QPushButton, QVBoxLayout, QHBoxLayout,
    QGridLayout, QStackedWidget, QListWidget, QListWidgetItem, QTableWidget, QTableWidgetItem,
    QHeaderView, QPlainTextEdit, QProgressBar, QFileDialog, QMessageBox, QLineEdit, QDialog,
    QDialogButtonBox, QFormLayout, QComboBox, QInputDialog, QAbstractItemView, QSplitter, QScrollArea,
)

from backend import (Store, DesktopError, MonitorClient, ACTIVE, bridge_command, bundled_toolkit,
                     discover_monitors, poll_projects, readiness, read_source, safe_log, same_path,
                     program_directory, existing_monitor, stop_command)
from version import VERSION

STYLE = """
QWidget { color: #25304a; font-family: 'Microsoft YaHei UI', 'Segoe UI'; font-size: 13px; }
QMainWindow, QWidget#canvas { background: #f3f5fb; }
QFrame#sidebar { background: #fff; border-right: 1px solid #e6eaf4; }
QFrame#card { background: white; border: 1px solid #e7ebf3; border-radius: 14px; }
QLabel { background: transparent; }
QLabel#brand { font-size: 21px; font-weight: 700; color: #302b65; }
QLabel#title { font-size: 25px; font-weight: 700; color: #202942; }
QLabel#heading { font-size: 16px; font-weight: 600; }
QLabel#muted { color: #768098; font-size: 12px; }
QLabel#number { font-size: 29px; font-weight: 700; color: #514aca; }
QLabel#tag { color: #6861c9; background: #efedff; border-radius: 9px; padding: 5px 10px; }
QPushButton { background: #fff; border: 1px solid #dce1ed; border-radius: 8px; padding: 9px 16px; }
QPushButton:hover { background: #f1f0ff; border-color: #b7b2f5; }
QPushButton:pressed { background: #e7e4ff; }
QPushButton:disabled { color: #a2aabd; background: #f4f5f8; border-color: #e9ecf2; }
QPushButton[primary="true"] { background: #655bea; color: white; border: 1px solid #655bea; font-weight: 600; }
QPushButton[primary="true"]:hover { background: #554bd8; }
QPushButton[primary="true"]:disabled { background: #c1bcec; border-color: #c1bcec; }
QPushButton#nav { text-align: left; border: 0; padding: 13px 17px; color: #626d84; }
QPushButton#nav:checked { background: #efedff; color: #5950d4; font-weight: 600; }
QPushButton#danger { color: #ad5262; }
QListWidget { border: 0; background: white; outline: none; padding: 4px; }
QListWidget::item { padding: 14px 10px; border-radius: 9px; margin: 2px 0; }
QListWidget::item:selected { background: #efedff; color: #514aca; }
QListWidget::item:hover { background: #f5f4fd; }
QLineEdit, QComboBox { background: #fafbfe; border: 1px solid #dce1ed; border-radius: 8px; padding: 9px; min-height: 18px; }
QLineEdit:focus, QComboBox:focus { border-color: #8177ed; }
QComboBox::drop-down { border: 0; width: 25px; }
QComboBox QAbstractItemView { background: white; selection-background-color: #efedff; selection-color: #514aca; }
QTableWidget { border: 0; gridline-color: #eef1f7; background: white; selection-background-color: #efedff; selection-color: #514aca; }
QHeaderView::section { background: #f8f9fd; color: #7a8399; padding: 11px 8px; border: 0; border-bottom: 1px solid #e9edf4; }
QPlainTextEdit { background: #f8f9fd; border: 1px solid #e9edf4; border-radius: 9px; color: #657086; padding: 9px; font-size: 12px; }
QProgressBar { height: 7px; border: 0; border-radius: 3px; background: #e9e7fb; text-align: center; }
QProgressBar::chunk { background: #756bec; border-radius: 3px; }
QScrollBar:vertical { background: transparent; width: 8px; margin: 0; }
QScrollBar::handle:vertical { background: #d6dbe8; border-radius: 4px; min-height: 30px; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
QSplitter::handle { background: transparent; width: 16px; }
QToolTip { background: #25304a; color: white; padding: 6px; border: 0; }
"""


class Signals(QObject):
    result = pyqtSignal(object)
    failed = pyqtSignal(str)
    finished = pyqtSignal()


class Worker(QRunnable):
    def __init__(self, function):
        super().__init__()
        self.function, self.signals = function, Signals()

    def run(self):
        try:
            self.signals.result.emit(self.function())
        except DesktopError as error:
            self.signals.failed.emit(str(error))
        except Exception:
            self.signals.failed.emit("操作未完成，请检查配置和本机服务状态。")
        finally:
            self.signals.finished.emit()


def label(text, kind=None):
    widget = QLabel(text)
    if kind:
        widget.setObjectName(kind)
    return widget


def button(text, action=None, primary=False):
    widget = QPushButton(text)
    widget.setCursor(Qt.CursorShape.PointingHandCursor)
    widget.setProperty("primary", primary)
    if action:
        widget.clicked.connect(action)
    return widget


def card():
    frame = QFrame()
    frame.setObjectName("card")
    layout = QVBoxLayout(frame)
    layout.setContentsMargins(20, 17, 20, 17)
    layout.setSpacing(12)
    return frame, layout


class MainWindow(QMainWindow):
    def __init__(self, store=None, auto_discover=True):
        super().__init__()
        self.store = store or Store()
        self.snapshots, self.source = {}, None
        self.workers, self.polling, self.busy = set(), False, False
        self.process, self.queue, self.output_buffer = None, [], ""
        self._model_key = None
        self._state_generation = 0
        self._stop_targets = []
        self._closing_after_stop = self._allow_exit = False
        self.decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self.pool = QThreadPool(self)
        self.pool.setMaxThreadCount(4)
        self.setWindowTitle(f"Codex × DSH 桌面控制台 · {VERSION}")
        self.resize(1280, 900)
        self.setMinimumSize(1060, 680)
        available = QApplication.primaryScreen().availableGeometry()
        self.resize(min(1280, available.width()), min(900, available.height()))
        self.setStyleSheet(STYLE)
        self.build_ui()
        self.reload_projects()
        self.timer = QTimer(self)
        self.timer.setInterval(5000)
        self.timer.timeout.connect(self.refresh)
        if auto_discover:
            self.load_source()
            QTimer.singleShot(150, self.detect_monitors)
            self.timer.start()
        if self.store.warning:
            self.log(self.store.warning)

    def build_ui(self):
        canvas = QWidget()
        canvas.setObjectName("canvas")
        root = QHBoxLayout(canvas)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        self.setCentralWidget(canvas)
        side = QFrame()
        side.setObjectName("sidebar")
        side.setFixedWidth(204)
        nav = QVBoxLayout(side)
        nav.setContentsMargins(20, 30, 20, 22)
        nav.addWidget(label("◈  DSH TEAM", "brand"))
        nav.addWidget(label("Codex 的桌面工作台", "muted"))
        nav.addSpacing(36)
        self.nav_overview = button("◉   Monitor 工作台", lambda: self.show_page(0))
        self.nav_settings = button("☷   配置与模型", lambda: self.show_page(1))
        for item in (self.nav_overview, self.nav_settings):
            item.setObjectName("nav")
            item.setCheckable(True)
            nav.addWidget(item)
        nav.addStretch()
        note = label("本机配置 · 按需连接\n网页与桌面，各有所长", "muted")
        note.setWordWrap(True)
        nav.addWidget(note)
        nav.addSpacing(12)
        nav.addWidget(label(f"DESKTOP  /  v{VERSION}", "muted"))
        root.addWidget(side)
        main = QVBoxLayout()
        main.setContentsMargins(28, 24, 28, 20)
        main.setSpacing(18)
        root.addLayout(main, 1)
        header = QHBoxLayout()
        titles = QVBoxLayout()
        self.title = label("让团队状态，一目了然", "title")
        self.subtitle = label("从这里连接项目、同步配置，继续你的工作。", "muted")
        titles.addWidget(self.title)
        titles.addWidget(self.subtitle)
        header.addLayout(titles, 1)
        self.detect_button = button("检测 Monitor", self.detect_monitors)
        self.add_button = button("＋ 添加项目", self.add_project, True)
        header.addWidget(self.detect_button)
        header.addWidget(self.add_button)
        main.addLayout(header)
        self.pages = QStackedWidget()
        main.addWidget(self.pages, 1)
        self.build_overview()
        self.build_settings()
        log_card, log_layout = card()
        log_head = QHBoxLayout()
        log_head.addWidget(label("运行日志", "heading"))
        log_head.addStretch()
        self.job_label = label("就绪", "muted")
        log_head.addWidget(self.job_label)
        log_layout.addLayout(log_head)
        self.progress = QProgressBar()
        self.progress.setTextVisible(False)
        self.progress.setFixedHeight(6)
        self.progress.setValue(0)
        log_layout.addWidget(self.progress)
        self.logs = QPlainTextEdit()
        self.logs.setObjectName("logOutput")
        self.logs.setReadOnly(True)
        self.logs.setMaximumBlockCount(500)
        self.logs.setFixedHeight(110)
        log_layout.addWidget(self.logs)
        main.addWidget(log_card)
        self.footer = label("关闭网页或结束 Codex 对话不会停止后台；删除项目之前，请点击“停止后台”。", "muted")
        main.addWidget(self.footer)
        self.show_page(0)

    def build_overview(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(18)
        stats = QHBoxLayout()
        self.stat_labels = []
        for title, detail in (("在线 Monitor", "本机已验证的连接"), ("进行中的任务", "来自 Monitor 实时状态"), ("DSH 会话", "所选项目的原生会话")):
            frame, box = card()
            box.addWidget(label(title, "muted"))
            number = label("0", "number")
            self.stat_labels.append(number)
            box.addWidget(number)
            box.addWidget(label(detail, "muted"))
            stats.addWidget(frame)
        layout.addLayout(stats)
        split = QSplitter()
        split.setChildrenCollapsible(False)
        projects_card, projects_box = card()
        projects_box.setContentsMargins(12, 16, 12, 10)
        projects_box.addWidget(label("  项目", "heading"))
        self.project_list = QListWidget()
        self.project_list.setObjectName("projects")
        self.project_list.setMinimumWidth(175)
        self.project_list.currentRowChanged.connect(self.project_changed)
        projects_box.addWidget(self.project_list, 1)
        remove = button("从列表移除", self.remove_project)
        projects_box.addWidget(remove)
        split.addWidget(projects_card)
        detail, box = card()
        self.project_title = label("添加一个项目，开始连接", "heading")
        self.project_path = label("支持已有项目，也支持空白文件夹。", "muted")
        self.project_path.setWordWrap(True)
        self.project_path.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        box.addWidget(self.project_title)
        box.addWidget(self.project_path)
        conversation = QHBoxLayout()
        self.conversation = label("Codex 对话：尚未关联", "muted")
        self.conversation.setWordWrap(True)
        conversation.addWidget(self.conversation, 1)
        self.associate_button = button("关联对话", self.associate_conversation)
        conversation.addWidget(self.associate_button)
        box.addLayout(conversation)
        connection = QHBoxLayout()
        self.connection = label("●  尚未连接", "tag")
        self.address = label("—", "muted")
        self.address.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        connection.addWidget(self.connection)
        connection.addWidget(self.address, 1)
        copy = button("复制地址", self.copy_address)
        connection.addWidget(copy)
        box.addLayout(connection)
        actions = QHBoxLayout()
        self.start_button = button("启动 Monitor", self.start_monitor, True)
        self.open_button = button("打开网页", self.open_monitor)
        self.sync_button = button("同步配置", self.sync_settings)
        self.stop_button = button("停止后台", self.stop_monitor)
        self.stop_button.setObjectName("danger")
        for item in (self.start_button, self.open_button, self.sync_button, self.stop_button):
            actions.addWidget(item)
        actions.addStretch()
        box.addLayout(actions)
        self.model_summary = label("模型：等待连接", "muted")
        self.model_summary.setWordWrap(True)
        box.addWidget(self.model_summary)
        self.table = QTableWidget(0, 4)
        self.table.setObjectName("sessions")
        self.table.setHorizontalHeaderLabels(["任务 / Agent", "状态", "DSH 会话", "模型"])
        self.table.verticalHeader().hide()
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(3, QHeaderView.ResizeMode.Stretch)
        self.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setShowGrid(False)
        self.table.setMinimumHeight(140)
        box.addWidget(self.table, 1)
        self.empty = label("还没有任务。启动后，可在 Codex 中使用项目的 DSH Skill。", "muted")
        self.empty.setWordWrap(True)
        box.addWidget(self.empty)
        split.addWidget(detail)
        split.setSizes([210, 740])
        layout.addWidget(split, 1)
        self.add_page(page)

    def add_page(self, page):
        page.setMinimumHeight(515)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setStyleSheet("QScrollArea, QScrollArea > QWidget > QWidget { background: transparent; }")
        scroll.setWidget(page)
        self.pages.addWidget(scroll)

    def build_settings(self):
        page = QWidget()
        grid = QVBoxLayout(page)
        grid.setContentsMargins(0, 0, 0, 0)
        source_card, box = card()
        box.addWidget(label("连接你自己的 DSH", "heading"))
        helper = label("选择包含 settings.yaml 的配置文件夹。设置保持只读，运行时使用同步副本。", "muted")
        helper.setWordWrap(True)
        box.addWidget(helper)
        source_row = QHBoxLayout()
        self.source_path = QLineEdit()
        self.source_path.setObjectName("sourcePath")
        self.source_path.setPlaceholderText("尚未选择 DSH 配置目录")
        self.source_path.setReadOnly(True)
        source_row.addWidget(self.source_path, 1)
        self.browse_source = button("浏览目录…", self.choose_source, True)
        source_row.addWidget(self.browse_source)
        self.detect_source = button("检测本机 DSH", self.find_source)
        source_row.addWidget(self.detect_source)
        box.addLayout(source_row)
        self.source_summary = label("默认供应商 / 模型：尚未读取", "heading")
        self.source_summary.setWordWrap(True)
        self.source_note = label("只检查保存的位置、环境变量与用户默认目录，不搜索整个硬盘。", "muted")
        self.source_note.setWordWrap(True)
        box.addWidget(self.source_summary)
        box.addWidget(self.source_note)
        self.runtime_note = label("项目运行使用工具包自带的 DSH 依赖；无需填写 DSH 程序路径。", "muted")
        self.runtime_note.setWordWrap(True)
        box.addWidget(self.runtime_note)
        grid.addWidget(source_card)
        model_card, box = card()
        box.addWidget(label("所选项目的模型偏好", "heading"))
        self.settings_project = label("先在工作台选择一个项目", "muted")
        box.addWidget(self.settings_project)
        form = QHBoxLayout()
        self.provider_combo, self.model_combo = QComboBox(), QComboBox()
        self.provider_combo.setMinimumWidth(160)
        self.provider_combo.currentIndexChanged.connect(self.provider_changed)
        form.addWidget(self.provider_combo, 1)
        form.addWidget(self.model_combo, 1)
        self.apply_model = button("应用到后续任务", self.save_model, True)
        self.follow_default = button("跟随 DSH 默认", lambda: self.save_model(follow=True))
        form.addWidget(self.apply_model)
        form.addWidget(self.follow_default)
        box.addLayout(form)
        note = label("只影响所选 Monitor 的后续任务，不修改用户 settings.yaml，也不更换正在运行的任务模型。", "muted")
        note.setWordWrap(True)
        box.addWidget(note)
        grid.addWidget(model_card)
        guide, box = card()
        box.addWidget(label("第一次使用？三步就好", "heading"))
        box.addWidget(label("01  选择你的 DSH 配置目录\n02  添加项目，然后点击“启动 Monitor”\n03  回到 Codex 工作，随时在这里查看状态", "muted"))
        grid.addWidget(guide)
        grid.addStretch()
        self.add_page(page)

    def show_page(self, index):
        self.pages.setCurrentIndex(index)
        self.nav_overview.setChecked(index == 0)
        self.nav_settings.setChecked(index == 1)
        self.title.setText("让团队状态，一目了然" if index == 0 else "配置一次，安心开工")

    def run_worker(self, function, success, failure=None, done=None):
        worker = Worker(function)
        self.workers.add(worker)
        worker.signals.result.connect(success)
        worker.signals.failed.connect(failure or self.fail)
        worker.signals.finished.connect(lambda: self.workers.discard(worker))
        if done:
            worker.signals.finished.connect(done)
        self.pool.start(worker)

    def log(self, message):
        self.logs.appendPlainText(f"{datetime.now():%H:%M:%S}  {safe_log(str(message))}")

    def fail(self, message):
        self.job_label.setText("操作未完成")
        self.progress.setRange(0, 100)
        self.progress.setValue(0)
        self.log(message)

    def selected(self):
        row = self.project_list.currentRow()
        return self.store.projects[row] if 0 <= row < len(self.store.projects) else None

    def state(self):
        project = self.selected()
        return self.snapshots.get(project["workspace"], {}) if project else {}

    def reload_projects(self, select_path=None):
        selected = select_path or (self.selected() or {}).get("workspace")
        self.project_list.blockSignals(True)
        self.project_list.clear()
        selected_row = 0
        for i, project in enumerate(self.store.projects):
            state = self.snapshots.get(project["workspace"], {})
            status = "在线" if state.get("online") else ("后台仍在运行" if state.get("canStop") else "未连接")
            item = QListWidgetItem(f"{project['name']}\n{status}")
            item.setToolTip(project["workspace"])
            self.project_list.addItem(item)
            if same_path(project["workspace"], selected):
                selected_row = i
        if self.store.projects:
            self.project_list.setCurrentRow(selected_row)
        self.project_list.blockSignals(False)
        self.project_changed()

    def project_changed(self, *_):
        project, state = self.selected(), self.state()
        online = bool(state.get("online"))
        usable = online and not state.get("limited") and not self.busy
        self.project_title.setText(project["name"] if project else "添加一个项目，开始连接")
        self.project_path.setText(project["workspace"] if project else "支持已有项目，也支持空白文件夹。")
        self.conversation.setText("Codex 对话：" + ((project or {}).get("conversationLabel") or "尚未关联"))
        self.conversation.setToolTip((project or {}).get("conversationId", ""))
        self.address.setText(state.get("url") or "—")
        self.connection.setText(("●  在线 · 概览" if state.get("limited") else "●  在线") if online else ("●  后台仍在运行" if state.get("canStop") else "○  未连接"))
        self.start_button.setEnabled(bool(project) and not self.busy)
        self.start_button.setText("刷新连接" if online else "启动 Monitor")
        self.open_button.setEnabled(online)
        for item in (self.sync_button, self.apply_model, self.follow_default):
            item.setEnabled(usable)
        self.stop_button.setEnabled(bool(project) and not self.busy)
        self.associate_button.setEnabled(bool(project) and not self.busy)
        self.stat_labels[0].setText(str(sum(bool(s.get("online")) for s in self.snapshots.values())))
        self.stat_labels[1].setText(str(sum(s.get("active", 0) for s in self.snapshots.values())))
        rows = state.get("runs", [])
        self.stat_labels[2].setText(str(len({r.get("sessionId") for r in rows if r.get("sessionId")})))
        self.table.setRowCount(min(len(rows), 150))
        translated = {"running": "运行中", "starting": "启动中", "completed": "已完成", "failed": "失败",
                      "cancelled": "已取消", "cancelling": "取消中", "queued": "排队中"}
        for i, run in enumerate(rows[:150]):
            model = run.get("effectiveModelSelection") or run.get("requestedModelSelection") or {}
            values = [run.get("title") or run.get("agentId") or "任务", translated.get(run.get("status"), run.get("status") or "—"),
                      run.get("sessionId") or "待建立", model.get("model") or "—"]
            for j, text in enumerate(values):
                item = QTableWidgetItem(str(text))
                item.setToolTip(str(text) + (f"\nAgent: {run.get('agentId') or '—'}" if j == 0 else ""))
                if j == 1:
                    item.setForeground(QColor("#3b9b76" if run.get("status") == "completed" else "#6b62dd"))
                self.table.setItem(i, j, item)
            self.table.setRowHeight(i, 40)
        self.empty.setVisible(not rows)
        self.empty.setText(state.get("error") or ("暂无任务，详细事件会显示在网页 Monitor 中。" if online else "点击“启动 Monitor”连接所选项目。"))
        settings = state.get("settings") or {}
        effective = settings.get("effective") or {}
        mode = "手动偏好" if settings.get("mode") == "override" else "跟随用户默认"
        self.model_summary.setText(f"模型：{effective.get('provider', '—')} / {effective.get('model', '—')}  ·  {mode}")
        self.settings_project.setText("所选项目：" + (project["name"] if project else "尚未选择"))
        model_key = ((project or {}).get("workspace"), json.dumps(settings, sort_keys=True))
        if model_key != self._model_key:
            self._model_key = model_key
            self.provider_combo.blockSignals(True)
            self.provider_combo.clear()
            for provider in settings.get("providers", []):
                if provider.get("models"):
                    self.provider_combo.addItem(provider.get("name") or provider["id"], provider["id"])
            self.provider_combo.setCurrentIndex(self.provider_combo.findData(effective.get("provider")))
            self.provider_combo.blockSignals(False)
            self.provider_changed()
            self.model_combo.setCurrentIndex(self.model_combo.findData(effective.get("model")))
        self.provider_combo.setEnabled(usable)
        self.model_combo.setEnabled(usable)
        self.apply_model.setEnabled(usable and bool(self.provider_combo.currentData()) and bool(self.model_combo.currentData()))

    def provider_changed(self, *_):
        self.model_combo.clear()
        settings = self.state().get("settings", {})
        selected = next((p for p in settings.get("providers", []) if p["id"] == self.provider_combo.currentData()), {})
        for model in selected.get("models", []):
            self.model_combo.addItem(model.get("name") or model["id"], model["id"])
        self.apply_model.setEnabled(bool(self.model_combo.currentData()) and bool(self.state().get("online")) and not self.state().get("limited") and not self.busy)

    def refresh(self):
        if self.polling or self.busy or not self.store.projects:
            return
        self.polling = True
        generation = self._state_generation
        projects = list(self.store.projects)
        def complete(states):
            if self.busy or generation != self._state_generation:
                return
            self.snapshots = states
            self.reload_projects()
            self.footer.setText(f"最近刷新 {datetime.now():%H:%M:%S}  ·  删除项目之前，请点击“停止后台”。")
        self.run_worker(lambda: poll_projects(projects), complete,
                        done=lambda: setattr(self, "polling", False))

    def detect_monitors(self):
        self.detect_button.setEnabled(False)
        def complete(paths):
            try:
                for path in paths:
                    self.store.add_project(path)
                self.reload_projects()
                self.log(f"本机检测完成，发现 {len(paths)} 个 Monitor 项目。")
                self.refresh()
            except DesktopError as error:
                self.fail(str(error))
        self.run_worker(discover_monitors, complete, done=lambda: self.detect_button.setEnabled(True))

    def add_project(self):
        path = QFileDialog.getExistingDirectory(self, "选择项目文件夹", str(program_directory()))
        if not path:
            return
        try:
            self.store.add_project(path)
            self.reload_projects(path)
            self.refresh()
        except DesktopError as error:
            self.fail(str(error))

    def remove_project(self):
        project = self.selected()
        if not project or self.busy:
            return
        if QMessageBox.question(self, "移除项目", "只从桌面列表移除，不删除文件，也不停止 Monitor。") != QMessageBox.StandardButton.Yes:
            return
        self.store.projects.remove(project)
        try:
            self.store.save()
            self.snapshots.pop(project["workspace"], None)
            self.reload_projects()
        except DesktopError as error:
            self.store.projects.append(project)
            self.fail(str(error))

    def associate_conversation(self):
        project = self.selected()
        if not project:
            return
        dialog = QDialog(self)
        dialog.setWindowTitle("关联 Codex 对话")
        dialog.setMinimumWidth(460)
        layout = QFormLayout(dialog)
        text = label("用一个好认的名称标记所属对话。DSH 会话 ID 会从 Monitor 自动显示。", "muted")
        text.setWordWrap(True)
        layout.addRow(text)
        title, identifier = QLineEdit(project.get("conversationLabel", "")), QLineEdit(project.get("conversationId", ""))
        title.setPlaceholderText("例如：贪吃蛇项目开发")
        identifier.setPlaceholderText("可选，由 Codex 启动时传入或手动填写")
        layout.addRow("对话名称", title)
        layout.addRow("Codex 对话 ID", identifier)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(dialog.accept)
        buttons.rejected.connect(dialog.reject)
        layout.addRow(buttons)
        if dialog.exec() == QDialog.DialogCode.Accepted:
            old = dict(project)
            project.update(conversationLabel=title.text().strip(), conversationId=identifier.text().strip())
            try:
                self.store.save()
                self.project_changed()
            except DesktopError as error:
                project.update(old)
                self.fail(str(error))

    def load_source(self):
        found = self.store.candidates()
        if found:
            self.display_source(found[0])

    def display_source(self, source):
        self.source = source
        self.source_path.setText(source["directory"])
        self.source_summary.setText(f"{source.get('provider') or '未设置默认供应商'}  /  {source.get('model') or '未设置默认模型'}")
        self.source_note.setText(source.get("error") or ("已检测到凭据文件；凭据内容不会显示或写入桌面日志。" if source.get("credentialsPresent") else "未发现独立凭据文件；若通过环境变量提供密钥，可以继续使用。"))

    def choose_source(self):
        directory = QFileDialog.getExistingDirectory(self, "选择 DSH 配置目录（包含 settings.yaml）", self.source_path.text() or str(program_directory()))
        if not directory:
            return
        try:
            self.display_source(self.store.set_source(directory))
            self.log("已记住 DSH 配置目录，后续从此处读取用户设置。")
        except DesktopError as error:
            QMessageBox.information(self, "请检查配置目录", str(error))

    def find_source(self):
        found = self.store.candidates()
        state = readiness((self.selected() or {}).get("workspace", program_directory()))
        self.runtime_note.setText("Node：" + (state["node"] or "未找到") + "\n全局 DSH：" + (state["globalDsh"] or "未发现；项目可使用工具包固定依赖"))
        if not found:
            self.log("固定位置中未找到 DSH 配置，请点击“浏览目录”。")
            return
        options = [f"{row['source']}  ·  {row['directory']}" for row in found]
        choice, accepted = QInputDialog.getItem(self, "选择检测到的 DSH 配置", "发现以下配置目录，请选择要使用的一份：", options, 0, False)
        if accepted:
            try:
                self.display_source(self.store.set_source(found[options.index(choice)]["directory"]))
                self.log("DSH 配置检测完成，已保存选择。")
            except DesktopError as error:
                self.fail(str(error))

    def set_busy(self, value, title=""):
        self.busy = value
        for control in (self.add_button, self.browse_source, self.detect_source):
            control.setEnabled(not value)
        if title:
            self.job_label.setText(title)
            self.log(title)
        if value:
            self.progress.setRange(0, 0)
        self.project_changed()

    def operation_done(self, message):
        self._state_generation += 1
        self.set_busy(False)
        self.progress.setRange(0, 100)
        self.progress.setValue(100)
        self.job_label.setText("已完成")
        self.log(message)
        self.refresh()

    def operation_failed(self, message):
        self._closing_after_stop = False
        self._stop_targets = []
        self.set_busy(False)
        self.fail(message)

    def sync_settings(self):
        project = self.selected()
        if not project or self.busy:
            return
        if not self.source:
            self.show_page(1)
            self.log("请先选择用户 DSH 配置目录。")
            return
        workspace, source = project["workspace"], self.source["directory"]
        self.set_busy(True, f"正在同步 {project['name']} 的设置")
        def sync():
            result = MonitorClient(workspace).sync(source)
            return result, read_source(source)
        def complete(result):
            self.display_source(result[1])
            self.operation_done(f"同步完成：{result[0].get('provider', '')} / {result[0].get('model', '')}")
        self.run_worker(sync, complete, self.operation_failed)

    def save_model(self, _checked=False, follow=False):
        project, state = self.selected(), self.state()
        if not project or self.busy or not state.get("online"):
            return
        selection = None if follow else {"provider": self.provider_combo.currentData(), "model": self.model_combo.currentData()}
        if selection and not all(selection.values()):
            return
        revision, workspace = state.get("settings", {}).get("revision", 0), project["workspace"]
        self.set_busy(True, "正在保存所选项目的模型偏好")
        self.run_worker(lambda: MonitorClient(workspace).choose_model(selection, revision),
                        lambda _: self.operation_done("已跟随 DSH 默认。" if follow else "已保存，后续任务使用新的模型偏好。"), self.operation_failed)

    def open_monitor(self):
        if self.state().get("online"):
            QDesktopServices.openUrl(QUrl(self.state()["url"]))

    def copy_address(self):
        if self.state().get("online"):
            QApplication.clipboard().setText(self.state()["url"])
            self.log("Monitor 地址已复制。")

    def start_monitor(self):
        project = self.selected()
        if not project or self.busy:
            return
        if self.state().get("online"):
            self.refresh()
            return
        if not self.source or self.source.get("error"):
            self.show_page(1)
            self.log("请先选择一份有效的 DSH 配置。")
            return
        workspace = project["workspace"]
        self.set_busy(True, "正在检查项目连接")
        def checked(state):
            if state:
                self.snapshots[workspace] = state
                self.operation_done("Monitor 已在运行，已复用现有连接。")
            else:
                self.prepare_monitor(project)
        self.run_worker(lambda: existing_monitor(workspace), checked, self.operation_failed)

    def prepare_monitor(self, project):
        workspace = project["workspace"]
        ready = readiness(workspace)
        if not ready["node"]:
            self.operation_failed("未找到 Node.js。请先安装 Node ≥ 22.19.0，再重新打开控制台。")
            return
        try:
            queue = []
            package = bundled_toolkit()
            if not ready["installed"]:
                if not package:
                    raise DesktopError("未找到随附工具包，请使用完整桌面发行包。")
                queue.append(("安装项目工具包", bridge_command("Install", workspace, package=package)))
            if not ready["dependencies"]:
                queue.append(("准备 DSH 依赖（首次需要联网）", bridge_command("Prepare", workspace)))
            queue.append(("同步配置并启动 Monitor", bridge_command("Start", workspace, source=self.source["directory"])))
            if len(queue) > 1 and QMessageBox.question(self, "准备项目", "将为这个项目安装工具包和所需依赖，然后启动本机 Monitor。\n不会发起模型任务。是否继续？") != QMessageBox.StandardButton.Yes:
                self.set_busy(False)
                self.progress.setRange(0, 100)
                self.progress.setValue(0)
                self.job_label.setText("已取消")
                return
            self.queue = queue
            self.set_busy(True, f"正在准备 {project['name']}")
            self.next_process()
        except DesktopError as error:
            self.operation_failed(str(error))

    def stop_monitor(self):
        project = self.selected()
        if not project or self.busy:
            return
        active = self.state().get("active", 0)
        detail = f"当前有 {active} 个进行中的任务。" if self.state().get("online") and not self.state().get("limited") else "当前无法完整读取任务状态。"
        if QMessageBox.warning(self, "停止项目后台", f"将停止 {project['name']} 的 Monitor 及其子进程，释放文件占用。\n{detail}未完成的任务会被中断。", QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                               QMessageBox.StandardButton.No) != QMessageBox.StandardButton.Yes:
            return
        self.stop_projects([project])

    def stop_projects(self, projects, exit_after=False):
        try:
            self.queue = [(f"停止 {project['name']} 的后台", stop_command(project["workspace"])) for project in projects]
            self._stop_targets = [project["workspace"] for project in projects]
            self._closing_after_stop = exit_after
            self.set_busy(True, "正在停止项目后台并检查文件占用")
            self.next_process()
        except DesktopError as error:
            self.operation_failed(str(error))

    def next_process(self):
        if not self.queue:
            stopped = bool(self._stop_targets)
            for workspace in self._stop_targets:
                self.snapshots[workspace] = {"online": False, "canStop": False, "active": 0, "runs": [], "url": "",
                                             "error": "后台已停止，日志占用已释放。现在可以删除或移动项目。"}
            self._stop_targets = []
            self.operation_done("后台已停止，日志占用已释放。" if stopped else "操作完成，正在更新项目状态。")
            if self._closing_after_stop:
                self._allow_exit = True
                self._closing_after_stop = False
                self.close()
            return
        title, command = self.queue.pop(0)
        self.job_label.setText(title)
        self.log(title)
        process = QProcess(self)
        self.process, self.output_buffer = process, ""
        self.decoder.reset()
        process.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        process.readyReadStandardOutput.connect(self.process_output)
        process.finished.connect(self.process_finished)
        process.errorOccurred.connect(lambda _: self.process_error(process))
        process.start(command[0], command[1:])

    def process_output(self):
        if not self.process:
            return
        self.output_buffer += self.decoder.decode(bytes(self.process.readAllStandardOutput()))
        lines = self.output_buffer.split("\n")
        self.output_buffer = lines.pop()
        for line in lines:
            line = line.strip()
            if line.startswith("@@TK_PROGRESS@@|"):
                parts = line.split("|")
                if len(parts) == 4:
                    names = {"preflight": "检查安装条件", "stage": "准备文件", "apply": "写入文件", "verify": "验证安装", "commit": "完成安装记录", "rollback": "恢复项目"}
                    self.log(f"{names.get(parts[1], parts[1])} {parts[2]}/{parts[3]}")
                    if parts[1] == "apply" and parts[2].isdigit() and parts[3].isdigit() and int(parts[3]):
                        self.progress.setRange(0, int(parts[3]))
                        self.progress.setValue(int(parts[2]))
                continue
            if line:
                self.log(line)

    def process_error(self, process):
        if process.error() == QProcess.ProcessError.FailedToStart:
            self.queue.clear()
            self.process = None
            process.deleteLater()
            self.operation_failed("无法启动 PowerShell，请检查 Windows 运行环境。")

    def process_finished(self, code, status):
        self.process_output()
        self.output_buffer += self.decoder.decode(b"", final=True)
        if self.output_buffer.strip():
            self.log(self.output_buffer.strip())
        process, self.process = self.process, None
        if process:
            process.deleteLater()
        if code != 0 or status != QProcess.ExitStatus.NormalExit:
            self.queue.clear()
            self.operation_failed(f"操作未完成（退出码 {code}），请查看上方日志。")
        else:
            self.next_process()

    def confirm_background_exit(self, count):
        dialog = QMessageBox(self)
        dialog.setWindowTitle("退出桌面控制台")
        dialog.setText(f"还有 {count} 个项目后台在运行。")
        dialog.setInformativeText("关闭网页或结束 Codex 对话不会停止后台。\n停止后台会中断未完成的任务，并释放项目文件占用。")
        stop = dialog.addButton("停止后台并退出", QMessageBox.ButtonRole.AcceptRole)
        keep = dialog.addButton("保留后台", QMessageBox.ButtonRole.DestructiveRole)
        cancel = dialog.addButton("取消", QMessageBox.ButtonRole.RejectRole)
        dialog.setDefaultButton(stop)
        dialog.setEscapeButton(cancel)
        dialog.exec()
        return "stop" if dialog.clickedButton() == stop else ("keep" if dialog.clickedButton() == keep else "cancel")

    def closeEvent(self, event):
        if self.busy:
            self.log("正在完成安装或配置操作，请等待完成后再关闭。")
            event.ignore()
            return
        running = [project for project in self.store.projects if any(self.snapshots.get(project["workspace"], {}).get(key) for key in ("online", "canStop"))]
        if running and not self._allow_exit:
            choice = self.confirm_background_exit(len(running))
            if choice == "cancel":
                event.ignore()
                return
            if choice == "stop":
                event.ignore()
                self.stop_projects(running, exit_after=True)
                return
        self.timer.stop()
        super().closeEvent(event)
