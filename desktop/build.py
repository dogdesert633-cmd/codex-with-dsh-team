"""Build an additive desktop distribution; do not modify the legacy toolkit sources."""
import argparse
from importlib.metadata import distribution
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import zipfile

from version import VERSION

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolkit-package", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "dist" / "desktop")
    args = parser.parse_args()
    package = args.toolkit_package.resolve()
    if not (package / "release-manifest.json").is_file():
        raise SystemExit("需要完整的现有工具包目录。")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    app_name = "CodexDshDesktop"
    app_dir = output / app_name
    if app_dir.exists():
        raise SystemExit("输出应用目录已经存在；请使用新的输出目录，保留之前的构建。")
    # Generate the executable icon from the same Qt artwork used in the window.
    from PyQt6.QtCore import QBuffer, QIODevice, QLibraryInfo
    from PyQt6.QtWidgets import QApplication
    from main import app_icon
    app = QApplication.instance() or QApplication([])
    buffer = QBuffer()
    buffer.open(QIODevice.OpenModeFlag.WriteOnly)
    app_icon().pixmap(128, 128).save(buffer, "PNG")
    png = bytes(buffer.data())
    icon = output / "desktop.ico"
    icon.write_bytes(struct.pack("<HHH", 0, 1, 1) + struct.pack("<BBBBHHII", 128, 128, 0, 0, 1, 32, len(png), 22) + png)
    version_file = output / "version-info.txt"
    numeric = tuple(int(part) for part in VERSION.split(".")) + (0,)
    version_file.write_text(f'''VSVersionInfo(ffi=FixedFileInfo(filevers={numeric}, prodvers={numeric}, mask=0x3f, flags=0x0, OS=0x40004, fileType=0x1, subtype=0x0, date=(0, 0)), kids=[StringFileInfo([StringTable('080404b0', [StringStruct('FileDescription', 'Codex × DSH 桌面控制台'), StringStruct('FileVersion', '{VERSION}'), StringStruct('ProductVersion', '{VERSION}'), StringStruct('ProductName', 'Codex × DSH Desktop'), StringStruct('OriginalFilename', 'CodexDshDesktop.exe')])]), VarFileInfo([VarStruct('Translation', [2052, 1200])])])''', encoding="utf-8")
    translation = Path(QLibraryInfo.path(QLibraryInfo.LibraryPath.TranslationsPath)) / "qtbase_zh_CN.qm"
    extra_binaries = []
    # Conda's _ctypes extension loads ffi.dll from Library/bin. It must travel
    # with the app so DPAPI works on machines without this development environment.
    conda_ffi = Path(sys.prefix) / "Library/bin/ffi.dll"
    if conda_ffi.is_file():
        extra_binaries = ["--add-binary", f"{conda_ffi}:."]
    command = [sys.executable, "-m", "PyInstaller", "--noconfirm", "--windowed", "--onedir", "--noupx",
               "--name", app_name, "--distpath", str(output), "--workpath", str(output / "build"),
               "--specpath", str(output / "spec"), "--add-data", f"{ROOT / 'desktop' / 'bridge.ps1'}:.",
               "--icon", str(icon), "--version-file", str(version_file),
               "--add-data", f"{translation}:PyQt6/Qt6/translations",
               "--exclude-module", "PyQt5", "--exclude-module", "PySide6", *extra_binaries, str(ROOT / "desktop/main.py")]
    # Collect DLLs only from this interpreter, Qt and Windows. Other installed
    # applications can put an incompatible ICU DLL on PATH with the same filename.
    build_environment = dict(os.environ)
    build_environment["PATH"] = os.pathsep.join([
        QLibraryInfo.path(QLibraryInfo.LibraryPath.BinariesPath), sys.prefix,
        str(Path(sys.prefix) / "Library/bin"), str(Path(os.environ["WINDIR"]) / "System32"),
        os.environ["WINDIR"],
    ])
    subprocess.run(command, check=True, cwd=ROOT, env=build_environment)
    if (app_dir / "_internal/icuuc.dll").exists():
        raise SystemExit("构建混入了外部 ICU 运行库；本版 Qt 使用 Windows 自带 ICU，请检查构建环境。")
    target_toolkit = app_dir / "toolkit"
    if target_toolkit.exists():
        raise SystemExit("输出目录已经存在 toolkit；请使用新的输出目录，避免混入旧文件。")
    shutil.copytree(package, target_toolkit)
    source_dir = app_dir / "desktop-source"
    source_dir.mkdir(exist_ok=True)
    for source in (ROOT / "desktop").iterdir():
        if source.suffix in {".py", ".ps1", ".md", ".txt"} or source.name == "LICENSE":
            shutil.copy2(source, source_dir / source.name)
    shutil.copytree(ROOT / "desktop/tests", source_dir / "tests", ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copy2(ROOT / "desktop/README.md", app_dir / "使用说明.md")
    notices = app_dir / "licenses"
    notices.mkdir(exist_ok=True)
    shutil.copy2(ROOT / "LICENSE", notices / "toolkit-MIT.txt")
    for package_name in ("PyQt6", "PyQt6-Qt6", "PyInstaller", "PyYAML"):
        dist = distribution(package_name)
        for file in dist.files or []:
            if any(part.lower() in {"licenses", "license", "copying"} for part in file.parts) or file.name.lower().startswith(("license", "copying")):
                source = Path(dist.locate_file(file))
                if source.is_file():
                    dest = notices / package_name / Path(str(file))
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, dest)
    archive = output / f"codex-dsh-desktop-v{VERSION}-windows-x64.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as stream:
        for path in sorted(app_dir.rglob("*")):
            if path.is_file():
                stream.write(path, str(Path(app_name) / path.relative_to(app_dir)))
    report = {"version": VERSION, "exe": str(app_dir / f"{app_name}.exe"), "zip": str(archive),
              "bytes": archive.stat().st_size, "toolkitVersion": json.loads((package / "release-manifest.json").read_text(encoding="utf-8-sig"))["version"]}
    (output / "build-report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
