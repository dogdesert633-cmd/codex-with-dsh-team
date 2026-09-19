import argparse
import json
import os
from pathlib import Path
import sys

from PyQt6.QtCore import QTimer, QTranslator, QLibraryInfo
from PyQt6.QtGui import QIcon, QPixmap, QPainter, QColor, QFont
from PyQt6.QtWidgets import QApplication

from backend import Store, DesktopError
from version import VERSION
from window import MainWindow


def app_icon():
    pixmap = QPixmap(128, 128)
    pixmap.fill(QColor("transparent"))
    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    painter.setBrush(QColor("#655bea"))
    painter.setPen(QColor("#655bea"))
    painter.drawRoundedRect(4, 4, 120, 120, 28, 28)
    painter.setPen(QColor("white"))
    painter.setFont(QFont("Segoe UI", 55, QFont.Weight.Bold))
    painter.drawText(pixmap.rect(), 0x84, "D")
    painter.end()
    return QIcon(pixmap)


def smoke_window(output):
    """Explicit offline packaged-app check; uses only a synthetic temporary project."""
    output.mkdir(parents=True, exist_ok=True)
    store = Store(output / "local-state")
    project = output / "示例项目"
    project.mkdir(exist_ok=True)
    store.add_project(project, "贪吃蛇游戏 · 界面验证示例")
    window = MainWindow(store, auto_discover=False)
    window.subtitle.setText("界面验证 · 以下为示例数据，不代表真实任务")
    selection = {"provider": "my-provider", "model": "my-model"}
    window.snapshots[str(project.resolve())] = {
        "online": True, "url": "http://127.0.0.1:4317", "active": 1,
        "settings": {"effective": selection, "revision": 0, "mode": "dsh-default",
                     "providers": [{"id": "my-provider", "models": [{"id": "my-model"}]}]},
        "runs": [{"id": "demo-run", "agentId": "Coder", "title": "实现游戏控制与计分", "status": "running",
                  "sessionId": "demo-session-001", "effectiveModelSelection": selection},
                 {"id": "demo-review", "agentId": "Reviewer", "title": "检查碰撞与重新开始", "status": "completed",
                  "sessionId": "demo-session-002", "effectiveModelSelection": selection}]}
    window.reload_projects()
    window.log("界面验证：示例项目已连接。")
    window.log("配置同步完成，后续任务跟随用户默认模型。")
    window.show()

    def finish():
        try:
            assert window.table.rowCount() == 2
            assert window.connection.text() == "●  在线"
            assert window.stat_labels[1].text() == "1"
            assert window.grab().save(str(output / "desktop-overview.png"))
            window.show_page(1)
            window.display_source({"directory": str(output / "用户 DSH 配置"), "provider": "my-provider",
                                   "model": "my-model", "credentialsPresent": True})
            QApplication.processEvents()
            assert window.grab().save(str(output / "desktop-settings.png"))
            (output / "smoke-result.json").write_text(json.dumps({"status": "PASS", "version": VERSION,
                "qtWidgets": True, "renderedTasks": 2, "offline": True}, ensure_ascii=False), encoding="utf-8")
        except Exception as error:
            (output / "smoke-result.json").write_text(json.dumps({"status": "FAIL", "kind": type(error).__name__}), encoding="utf-8")
            QApplication.exit(1)
            return
        window._allow_exit = True  # Synthetic monitor data must never invoke a real stop.
        window.close()
        QApplication.quit()
    QTimer.singleShot(500, finish)
    return window


def main():
    parser = argparse.ArgumentParser(description="Codex × DSH 桌面控制台")
    parser.add_argument("--version", action="version", version=VERSION)
    parser.add_argument("--project", help="添加或选中的项目目录（供 Codex 自动化调用）")
    parser.add_argument("--conversation-label", default="")
    parser.add_argument("--conversation-id", default="")
    parser.add_argument("--smoke-test", type=Path, help="离线验证界面并将结果保存到指定目录")
    args = parser.parse_args()
    app = QApplication(sys.argv[:1])
    app.setApplicationName("CodexDshDesktop")
    app.setApplicationVersion(VERSION)
    app.setOrganizationName("CodexDshTeam")
    app.setStyle("Fusion")
    app.setWindowIcon(app_icon())
    translator = QTranslator(app)
    if translator.load("qtbase_zh_CN", QLibraryInfo.path(QLibraryInfo.LibraryPath.TranslationsPath)):
        app.installTranslator(translator)
    if args.smoke_test:
        window = smoke_window(args.smoke_test.resolve())
    else:
        store = Store()
        error = None
        if args.project:
            try:
                project = store.add_project(args.project)
                identifier = args.conversation_id or os.environ.get("CODEX_THREAD_ID", "")
                if args.conversation_label or identifier:
                    project.update(conversationLabel=args.conversation_label or project.get("conversationLabel", ""),
                                   conversationId=identifier)
                    store.save()
            except DesktopError as issue:
                error = str(issue)
        window = MainWindow(store)
        if args.project:
            window.reload_projects(args.project)
        if error:
            window.log(error)
        window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
