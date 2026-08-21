#!/usr/bin/env python3
"""Build a new, checksummed delivery package from a validated project."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import zipfile
from datetime import datetime
from pathlib import Path


EP_FILE_RE = re.compile(r"^EP-(\d{2,3})\.md$", re.IGNORECASE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build a short-drama delivery package")
    parser.add_argument("--project", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--name", help="Package directory name; defaults to title plus timestamp")
    parser.add_argument("--title", help="Fallback title when project.json is absent")
    parser.add_argument("--volume-size", type=int, default=20)
    parser.add_argument("--zip", action="store_true", dest="make_zip")
    parser.add_argument(
        "--scripts-only",
        action="store_true",
        help="Allow delivery before visual handoffs are READY",
    )
    parser.add_argument(
        "--require-assets",
        action="store_true",
        help="Fail when asset-package contains no files",
    )
    return parser.parse_args()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text.rstrip() + "\n", encoding="utf-8", newline="\n")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_file(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def copy_tree(source: Path, destination: Path) -> int:
    if not source.is_dir():
        return 0
    count = 0
    for item in sorted(source.rglob("*")):
        if item.is_file():
            copy_file(item, destination / item.relative_to(source))
            count += 1
    return count


def sanitize_name(value: str) -> str:
    cleaned = re.sub(r"[^\w\u3400-\u9fff-]+", "_", value, flags=re.UNICODE).strip("_.-")
    return cleaned or "shortdrama"


def load_project(project: Path, title_arg: str | None) -> tuple[dict, str, int]:
    config_path = project / "project.json"
    config: dict = {}
    if config_path.is_file():
        config = json.loads(read_text(config_path))
    title = (title_arg or config.get("title") or "").strip()
    episodes = int(config.get("episodes", 0) or 0)

    scripts = sorted(
        path
        for path in (project / "scripts").glob("EP-*.md")
        if path.is_file() and EP_FILE_RE.match(path.name)
    )
    if not episodes:
        episodes = len(scripts)
    if not title and scripts:
        match = re.search(r"^剧名：《(.+?)》\s*$", read_text(scripts[0]), re.MULTILINE)
        if match:
            title = match.group(1).strip()
    if not title:
        raise SystemExit("Cannot determine title; add project.json or pass --title")
    if episodes < 1:
        raise SystemExit("Cannot determine a positive episode count")
    return config, title, episodes


def run_validation(project: Path, episodes: int, scripts_only: bool) -> str:
    validator = Path(__file__).with_name("validate_project.py")
    command = [
        sys.executable,
        str(validator),
        "--project",
        str(project),
        "--episodes",
        str(episodes),
    ]
    if not scripts_only:
        command.append("--require-visual-ready")
    completed = subprocess.run(command, text=True, encoding="utf-8", capture_output=True)
    output = (completed.stdout + completed.stderr).strip()
    if completed.returncode != 0:
        raise SystemExit("Validation failed; delivery was not created.\n" + output)
    return output


def episode_files(project: Path, episodes: int) -> list[Path]:
    width = max(2, len(str(episodes)))
    files = [project / "scripts" / f"EP-{episode:0{width}d}.md" for episode in range(1, episodes + 1)]
    missing = [path.name for path in files if not path.is_file()]
    if missing:
        raise SystemExit("Missing episode files: " + ", ".join(missing))
    return files


def build_volume(files: list[Path], title: str, label: str, destination: Path) -> None:
    parts = [
        f"# 《{title}》{label}",
        "",
        "> 本文件由正式单集源文件自动汇编；请勿直接在合订本修改。",
    ]
    for path in files:
        parts.extend(["", "---", "", read_text(path).strip()])
    write_text(destination, "\n".join(parts))


def build_reading_files(
    project: Path,
    reading: Path,
    files: list[Path],
    title: str,
    volume_size: int,
) -> list[str]:
    reading.mkdir(parents=True, exist_ok=True)
    created: list[str] = []
    next_index = 1
    bible = project / "STORY-BIBLE.md"
    if bible.is_file():
        destination = reading / f"{next_index:02d}_项目圣经与逐集大纲.md"
        copy_file(bible, destination)
        created.append(destination.name)
        next_index += 1
    benchmark = project / "BENCHMARK-ANALYSIS.md"
    if benchmark.is_file():
        destination = reading / f"{next_index:02d}_参考样本机制拆解.md"
        copy_file(benchmark, destination)
        created.append(destination.name)
        next_index += 1

    start_index = next_index
    for offset in range(0, len(files), volume_size):
        chunk = files[offset : offset + volume_size]
        first = int(EP_FILE_RE.match(chunk[0].name).group(1))
        last = int(EP_FILE_RE.match(chunk[-1].name).group(1))
        name = f"{start_index:02d}_正式剧本_EP{first:02d}-{last:02d}.md"
        build_volume(chunk, title, f"正式剧本 EP{first:02d}-{last:02d}", reading / name)
        created.append(name)
        start_index += 1

    combined = f"{start_index:02d}_全季正式剧本合订本_EP01-{len(files):02d}.md"
    build_volume(files, title, "全季正式剧本合订本", reading / combined)
    created.append(combined)
    return created


def create_manifest(package: Path) -> tuple[int, list[tuple[str, str, int]]]:
    manifest = package / "SHA256文件清单.md"
    records: list[tuple[str, str, int]] = []
    for path in sorted(p for p in package.rglob("*") if p.is_file() and p != manifest):
        relative = path.relative_to(package).as_posix()
        records.append((relative, sha256(path), path.stat().st_size))

    lines = [
        "# SHA256 文件清单",
        "",
        "| 相对路径 | SHA256 | 字节 |",
        "|:--|:--|--:|",
    ]
    for relative, digest, size in records:
        escaped = relative.replace("|", "\\|")
        lines.append(f"| {escaped} | `{digest}` | {size} |")
    write_text(manifest, "\n".join(lines))

    actual = [p for p in package.rglob("*") if p.is_file() and p != manifest]
    if len(actual) != len(records):
        raise SystemExit("Manifest verification failed: file count changed during build")
    for relative, digest, size in records:
        path = package / Path(relative)
        if not path.is_file() or sha256(path) != digest or path.stat().st_size != size:
            raise SystemExit(f"Manifest verification failed: {relative}")
    return len(records), records


def make_zip(package: Path) -> Path:
    zip_path = package.with_suffix(".zip")
    if zip_path.exists():
        raise SystemExit(f"Refusing to overwrite existing ZIP: {zip_path}")
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(p for p in package.rglob("*") if p.is_file()):
            archive.write(path, (Path(package.name) / path.relative_to(package)).as_posix())
    return zip_path


def main() -> int:
    args = parse_args()
    if args.volume_size < 1:
        raise SystemExit("--volume-size must be positive")
    project = Path(args.project).expanduser().resolve()
    output_root = Path(args.output_root).expanduser().resolve()
    if not project.is_dir():
        raise SystemExit(f"Project directory does not exist: {project}")
    output_root.mkdir(parents=True, exist_ok=True)

    config, title, episodes = load_project(project, args.title)
    validation_output = run_validation(project, episodes, args.scripts_only)

    asset_source = project / "asset-package"
    asset_files = [path for path in asset_source.rglob("*") if path.is_file()] if asset_source.is_dir() else []
    if args.require_assets and not asset_files:
        raise SystemExit("asset-package is empty; delivery was not created")

    timestamp = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
    package_name = sanitize_name(args.name) if args.name else f"{sanitize_name(title)}_正式制作包_{timestamp}"
    package = output_root / package_name
    if package.exists():
        raise SystemExit(f"Refusing to overwrite existing delivery directory: {package}")

    reading = package / "01_阅读交付"
    production = package / "02_AI制作源文件"
    qa_destination = package / "03_质检与连续性"
    asset_destination = package / "04_视觉资产包"
    package.mkdir(parents=True)

    files = episode_files(project, episodes)
    reading_files = build_reading_files(project, reading, files, title, args.volume_size)

    root_sources = [
        "project.json",
        "PROJECT-BRIEF.md",
        "BENCHMARK-ANALYSIS.md",
        "STORY-BIBLE.md",
        "WRITING-SPEC.md",
        "plot-map.md",
        "character-cards.md",
        "ledger-foreshadow.md",
        "progress.md",
    ]
    root_count = 0
    for name in root_sources:
        source = project / name
        if source.is_file():
            copy_file(source, production / name)
            root_count += 1
    script_source_count = copy_tree(project / "scripts", production / "scripts")
    visual_count = copy_tree(project / "visual-assets", production / "visual-assets")
    qa_count = copy_tree(project / "qa", qa_destination)
    asset_count = copy_tree(asset_source, asset_destination)
    write_text(
        qa_destination / "构建时机器校验.md",
        "# 构建时机器校验\n\n```text\n" + validation_output + "\n```",
    )
    qa_count += 1

    handoff_files = list((project / "visual-assets" / "episodes").glob("EP-*.md"))
    ready_count = sum(
        1 for path in handoff_files if re.search(r"^交接状态：READY\s*$", read_text(path), re.MULTILINE)
    )
    readme = [
        f"# 《{title}》正式制作包",
        "",
        f"> 规格：{config.get('mode', '中文短剧')}｜{episodes}集｜单集约{config.get('duration_seconds', '未标')}秒",
        "",
        "## 建议阅读顺序",
        "",
    ]
    readme.extend(f"{index}. `01_阅读交付/{name}`" for index, name in enumerate(reading_files, 1))
    readme.extend(
        [
            "",
            "## 制作文件",
            "",
            f"- 单集正式剧本：{len(files)}集；脚本目录共{script_source_count}个文件（含模板时一并保留）。",
            f"- 视觉事实文件：{visual_count}个；逐集READY：{ready_count}/{episodes}。",
            f"- 质检文件：{qa_count}个。",
            f"- 正式视觉资产包文件：{asset_count}个。",
            f"- 全局制作文档：{root_count}个。",
            "- `SHA256文件清单.md` 用于完整性复核。",
            "",
            "## 构建校验",
            "",
            f"- `{validation_output}`",
        ]
    )
    write_text(package / "00_交付说明.md", "\n".join(readme))

    manifest_rows, _ = create_manifest(package)
    zip_path = make_zip(package) if args.make_zip else None
    print(
        f"DELIVERY-PASS package={package}; episodes={episodes}; ready={ready_count}; "
        f"assets={asset_count}; manifest={manifest_rows}"
    )
    if zip_path:
        print(f"zip={zip_path}; sha256={sha256(zip_path)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
