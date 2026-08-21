#!/usr/bin/env python3
"""Deterministic validation for a Chinese short-drama production project."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


DEFAULTS: dict[str, Any] = {
    "episodes": 60,
    "scene_min": 2,
    "scene_max": 4,
    "content_chars_min": 800,
    "content_chars_max": 1200,
    "dialogue_chars_max": 35,
    "require_ledger": True,
    "require_visual_ready": False,
    "require_body_assets_in_header": False,
}

EP_FILE_RE = re.compile(r"^EP-(\d{2,3})\.md$", re.IGNORECASE)
EP_HEADER_RE = re.compile(r"^集数：EP-(\d{1,3})\s+(.+?)\s*$", re.MULTILINE)
SCENE_RE = re.compile(r"^场次\s+(\d{1,3})-(\d+)：", re.MULTILINE)
ASSET_RE = re.compile(r"@[A-Za-z0-9_\-\u3400-\u9fff]+")
ASSET_SPLIT_RE = re.compile(r"[；;，,、\s|：:（）()\[\]【】]+")


@dataclass
class Finding:
    level: str
    code: str
    scope: str
    message: str


@dataclass
class EpisodeResult:
    episode: int
    filename: str
    title: str = ""
    core: str = ""
    hook: str = ""
    scenes: int = 0
    content_chars: int = 0
    assets: int = 0
    findings: list[Finding] = field(default_factory=list)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate a short-drama project")
    parser.add_argument("--project", required=True)
    parser.add_argument("--episodes", type=int)
    parser.add_argument("--scene-min", type=int)
    parser.add_argument("--scene-max", type=int)
    parser.add_argument("--content-chars-min", type=int)
    parser.add_argument("--content-chars-max", type=int)
    parser.add_argument("--dialogue-chars-max", type=int)
    parser.add_argument("--require-ledger", action="store_true", default=None)
    parser.add_argument("--require-visual-ready", action="store_true", default=None)
    parser.add_argument("--require-body-assets-in-header", action="store_true", default=None)
    parser.add_argument("--report", help="Optional Markdown report path")
    parser.add_argument("--json", dest="json_path", help="Optional JSON result path")
    return parser.parse_args()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_config(project: Path, args: argparse.Namespace) -> dict[str, Any]:
    config = dict(DEFAULTS)
    config_path = project / "project.json"
    if config_path.is_file():
        loaded = json.loads(read_text(config_path))
        if not isinstance(loaded, dict):
            raise SystemExit("project.json must contain a JSON object")
        config.update(loaded)

    for key in (
        "episodes",
        "scene_min",
        "scene_max",
        "content_chars_min",
        "content_chars_max",
        "dialogue_chars_max",
        "require_ledger",
        "require_visual_ready",
        "require_body_assets_in_header",
    ):
        value = getattr(args, key)
        if value is not None:
            config[key] = value
    return config


def field_value(text: str, label: str) -> str:
    match = re.search(rf"^{re.escape(label)}：(.+?)\s*$", text, re.MULTILINE)
    return match.group(1).strip() if match else ""


def visible_length(text: str) -> int:
    without_card = text.replace("【卡黑】", "")
    return len(re.sub(r"[\s═─@]+", "", without_card))


def extract_asset_list(text: str) -> set[str]:
    assets: set[str] = set()
    for piece in ASSET_SPLIT_RE.split(text):
        at = piece.find("@")
        if at < 0:
            continue
        match = ASSET_RE.match(piece, at)
        if match:
            assets.add(match.group(0))
    return assets


def resolve_body_assets(body: str, declared: set[str]) -> tuple[set[str], set[str]]:
    used: set[str] = set()
    unknown: set[str] = set()
    ordered = sorted(declared, key=len, reverse=True)
    for marker in re.finditer(r"@", body):
        suffix = body[marker.start() :]
        match = next((asset for asset in ordered if suffix.startswith(asset)), None)
        if match:
            used.add(match)
            continue
        raw = ASSET_RE.match(body, marker.start())
        unknown.add(raw.group(0) if raw else "@")
    return used, unknown


def normalize_unique(value: str) -> str:
    return re.sub(r"[\s，。！？、；：,.!?;:'\"“”‘’《》〈〉（）()\-—]+", "", value).lower()


def extract_body(text: str) -> str:
    scene = re.search(r"^场次\s+", text, re.MULTILINE)
    if not scene:
        return ""
    ledger = text.find("【台账登记块】", scene.start())
    end = ledger if ledger >= 0 else len(text)
    return text[scene.start() : end]


def extract_plot_titles(project: Path) -> dict[int, str]:
    path = project / "plot-map.md"
    if not path.is_file():
        return {}
    titles: dict[int, str] = {}
    row_re = re.compile(r"^\|\s*EP-(\d{1,3})\s*\|\s*([^|]+?)\s*\|", re.MULTILINE)
    for number, title in row_re.findall(read_text(path)):
        if title.strip() and title.strip() != "待定":
            titles[int(number)] = title.strip().strip("《》")
    return titles


def add(result: EpisodeResult, level: str, code: str, message: str) -> None:
    result.findings.append(Finding(level, code, result.filename, message))


def validate_episode(
    path: Path,
    expected_episode: int,
    config: dict[str, Any],
    plot_titles: dict[int, str],
    global_assets: set[str],
) -> EpisodeResult:
    text = read_text(path)
    result = EpisodeResult(expected_episode, path.name)

    header = EP_HEADER_RE.search(text)
    if not header:
        add(result, "FAIL", "E01", "缺少合法的“集数：EP-XX 标题”头部")
    else:
        header_episode = int(header.group(1))
        result.title = header.group(2).strip().strip("《》")
        if header_episode != expected_episode:
            add(result, "FAIL", "E02", f"头部集数EP-{header_episode:02d}与文件名不一致")
        expected_title = plot_titles.get(expected_episode)
        if expected_title and normalize_unique(expected_title) != normalize_unique(result.title):
            add(result, "FAIL", "E03", f"剧本标题“{result.title}”与plot-map“{expected_title}”不一致")

    mode = field_value(text, "模式")
    result.core = field_value(text, "本集核心看点")
    asset_line = field_value(text, "本集资产引用")
    header_assets = extract_asset_list(asset_line)
    result.assets = len(header_assets)
    if not mode:
        add(result, "FAIL", "E04", "缺少模式字段")
    if not result.core or "待填写" in result.core or "<" in result.core:
        add(result, "FAIL", "E05", "本集核心看点缺失或仍含占位符")
    if not asset_line:
        add(result, "FAIL", "E06", "缺少本集资产引用字段")

    scenes = [(int(ep), int(scene)) for ep, scene in SCENE_RE.findall(text)]
    result.scenes = len(scenes)
    if not config["scene_min"] <= result.scenes <= config["scene_max"]:
        add(
            result,
            "FAIL",
            "E07",
            f"场次数{result.scenes}不在{config['scene_min']}-{config['scene_max']}范围",
        )
    if scenes:
        prefixes = {ep for ep, _ in scenes}
        scene_numbers = [scene for _, scene in scenes]
        if prefixes != {expected_episode}:
            add(result, "FAIL", "E08", f"场次前缀应全部为{expected_episode:02d}")
        if scene_numbers != list(range(1, len(scene_numbers) + 1)):
            add(result, "FAIL", "E09", "场次编号不连续或不从1开始")

    card_count = text.count("【卡黑】")
    if card_count != 1:
        add(result, "FAIL", "E10", f"【卡黑】数量为{card_count}，应为1")
    if "下集预告" in text:
        add(result, "FAIL", "E11", "正式稿不得包含下集预告")

    if config.get("require_ledger", True):
        markers = {
            "【台账登记块】": 1,
            "【台账登记块·完】": 1,
            "【快照】": 1,
            "【快照·完】": 1,
        }
        for marker, expected in markers.items():
            actual = text.count(marker)
            if actual != expected:
                add(result, "FAIL", "E12", f"{marker}数量为{actual}，应为{expected}")
        if text.find("【卡黑】") > text.find("【台账登记块】") >= 0:
            add(result, "FAIL", "E13", "【卡黑】必须位于台账登记块之前")

    hook_match = re.search(r"^- 集尾钩子：(.+?)\s*$", text, re.MULTILINE)
    if hook_match:
        result.hook = hook_match.group(1).strip()
        if "待填写" in result.hook or "<" in result.hook:
            add(result, "FAIL", "E14", "集尾钩子仍含占位符")
    else:
        add(result, "FAIL", "E14", "快照中缺少集尾钩子")

    body = extract_body(text)
    result.content_chars = visible_length(body)
    if result.content_chars < config["content_chars_min"]:
        add(result, "FAIL", "E15", f"有效正文{result.content_chars}字符，低于{config['content_chars_min']}")
    elif result.content_chars > config["content_chars_max"]:
        add(result, "FAIL", "E16", f"有效正文{result.content_chars}字符，高于{config['content_chars_max']}")

    body_before_card = body.split("【卡黑】", 1)[0]
    resolution_assets = global_assets or header_assets
    used_body_assets, unknown_body_assets = resolve_body_assets(body_before_card, resolution_assets)
    if unknown_body_assets:
        add(result, "FAIL", "E17", "正文资产未进入头部引用：" + "；".join(sorted(unknown_body_assets)))
    missing_header = sorted(used_body_assets - header_assets)
    if missing_header:
        level = "FAIL" if config.get("require_body_assets_in_header") else "WARN"
        add(result, level, "W02", "正文使用但头部未列：" + "；".join(missing_header))

    if re.search(r"<[^>]+>|待填写", body_before_card):
        add(result, "FAIL", "E18", "正式正文仍含模板占位符")

    lines = text.splitlines()
    for index in range(2, len(lines)):
        previous = lines[index - 1].strip()
        current = lines[index].strip()
        if re.fullmatch(r"（[^）]*）", previous) and current:
            length = visible_length(current)
            if length > config["dialogue_chars_max"]:
                add(
                    result,
                    "WARN",
                    "W01",
                    f"疑似台词第{index + 1}行长{length}字符，建议拆句",
                )
    return result


def duplicate_findings(results: list[EpisodeResult], attr: str, code: str, label: str) -> list[Finding]:
    values: defaultdict[str, list[str]] = defaultdict(list)
    originals: dict[str, str] = {}
    for result in results:
        raw = getattr(result, attr)
        normalized = normalize_unique(raw)
        if normalized:
            values[normalized].append(result.filename)
            originals[normalized] = raw
    findings: list[Finding] = []
    for normalized, scopes in values.items():
        if len(scopes) > 1:
            findings.append(
                Finding("FAIL", code, "；".join(scopes), f"{label}精确重复：“{originals[normalized]}”")
            )
    return findings


def validate_visual(project: Path, expected: int, required: bool) -> tuple[list[Finding], dict[str, int]]:
    findings: list[Finding] = []
    stats = {"handoffs": 0, "ready": 0, "hash_mismatch": 0}
    handoff_dir = project / "visual-assets" / "episodes"
    files = [] if not handoff_dir.is_dir() else sorted(
        path for path in handoff_dir.iterdir() if path.is_file() and EP_FILE_RE.match(path.name)
    )
    stats["handoffs"] = len(files)
    if not files:
        level = "FAIL" if required else "WARN"
        findings.append(Finding(level, "V01", "visual-assets/episodes", "尚无逐集视觉交接"))
        return findings, stats

    by_episode = {int(EP_FILE_RE.match(path.name).group(1)): path for path in files}
    missing = sorted(set(range(1, expected + 1)) - set(by_episode))
    extra = sorted(set(by_episode) - set(range(1, expected + 1)))
    if missing:
        findings.append(Finding("FAIL", "V02", "visual-assets/episodes", f"缺少交接集：{missing}"))
    if extra:
        findings.append(Finding("FAIL", "V03", "visual-assets/episodes", f"超范围交接集：{extra}"))

    for episode, handoff in sorted(by_episode.items()):
        text = read_text(handoff)
        script = project / "scripts" / handoff.name
        status_ready = bool(re.search(r"^交接状态：READY\s*$", text, re.MULTILINE))
        if status_ready:
            stats["ready"] += 1
        elif required:
            findings.append(Finding("FAIL", "V04", handoff.name, "交接状态不是READY"))
        hash_match = re.search(r"^剧本SHA256：([0-9a-fA-F]{64})\s*$", text, re.MULTILINE)
        if not script.is_file():
            findings.append(Finding("FAIL", "V05", handoff.name, "对应剧本不存在"))
        elif not hash_match:
            findings.append(Finding("FAIL", "V06", handoff.name, "缺少合法剧本SHA256"))
        elif sha256(script) != hash_match.group(1).lower():
            stats["hash_mismatch"] += 1
            findings.append(Finding("FAIL", "V07", handoff.name, "交接中的剧本SHA256已过期"))
    return findings, stats


def known_assets(project: Path) -> set[str]:
    candidates = [
        project / "visual-assets" / "source-facts.md",
        project / "visual-assets" / "handoff.md",
        project / "WRITING-SPEC.md",
        project / "character-cards.md",
    ]
    asset_package = project / "asset-package"
    if asset_package.is_dir():
        candidates.extend(asset_package.rglob("*.md"))
    assets: set[str] = set()
    for path in candidates:
        if not path.is_file():
            continue
        for line in read_text(path).splitlines():
            assets.update(extract_asset_list(line))
    return assets


def markdown_report(
    project: Path,
    config: dict[str, Any],
    results: list[EpisodeResult],
    findings: list[Finding],
    visual_stats: dict[str, int],
) -> str:
    counts = Counter(f.level for f in findings)
    char_values = [result.content_chars for result in results]
    scene_values = [result.scenes for result in results]
    lines = [
        "# 短剧项目机器校验报告",
        "",
        f"> 项目：`{project}`",
        "",
        "## 总览",
        "",
        f"- 目标集数：{config['episodes']}",
        f"- 实际剧本：{len(results)}",
        f"- FAIL：{counts['FAIL']}",
        f"- WARN：{counts['WARN']}",
        f"- 场次数范围：{min(scene_values) if scene_values else 0}-{max(scene_values) if scene_values else 0}",
        f"- 有效正文范围：{min(char_values) if char_values else 0}-{max(char_values) if char_values else 0}",
        f"- 视觉交接：{visual_stats['handoffs']}，READY：{visual_stats['ready']}，哈希失配：{visual_stats['hash_mismatch']}",
        "",
        "## 逐集统计",
        "",
        "| 集数 | 标题 | 场次 | 有效正文 | 资产引用 | FAIL | WARN |",
        "|:--|:--|--:|--:|--:|--:|--:|",
    ]
    for result in results:
        local = Counter(f.level for f in result.findings)
        lines.append(
            f"| EP-{result.episode:02d} | {result.title or '未解析'} | {result.scenes} | "
            f"{result.content_chars} | {result.assets} | {local['FAIL']} | {local['WARN']} |"
        )

    lines.extend(["", "## 问题清单", ""])
    if findings:
        lines.extend(
            f"- **{finding.level} {finding.code}** `{finding.scope}`：{finding.message}"
            for finding in findings
        )
    else:
        lines.append("- 无。")
    lines.extend(["", f"结论：{'PASS' if counts['FAIL'] == 0 else 'FAIL'}", ""])
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    project = Path(args.project).expanduser().resolve()
    if not project.is_dir():
        raise SystemExit(f"Project directory does not exist: {project}")
    config = load_config(project, args)
    expected = int(config["episodes"])
    scripts_dir = project / "scripts"
    findings: list[Finding] = []
    results: list[EpisodeResult] = []

    if not scripts_dir.is_dir():
        findings.append(Finding("FAIL", "P01", "scripts", "scripts目录不存在"))
    else:
        files = sorted(
            path for path in scripts_dir.iterdir() if path.is_file() and EP_FILE_RE.match(path.name)
        )
        by_episode = {int(EP_FILE_RE.match(path.name).group(1)): path for path in files}
        missing = sorted(set(range(1, expected + 1)) - set(by_episode))
        extra = sorted(set(by_episode) - set(range(1, expected + 1)))
        if missing:
            findings.append(Finding("FAIL", "P02", "scripts", f"缺少正式剧本集：{missing}"))
        if extra:
            findings.append(Finding("FAIL", "P03", "scripts", f"存在超范围剧本集：{extra}"))

        plot_titles = extract_plot_titles(project)
        global_assets = known_assets(project)
        for episode in sorted(set(by_episode) & set(range(1, expected + 1))):
            result = validate_episode(by_episode[episode], episode, config, plot_titles, global_assets)
            results.append(result)
            findings.extend(result.findings)

    findings.extend(duplicate_findings(results, "title", "P04", "集标题"))
    findings.extend(duplicate_findings(results, "core", "P05", "核心看点"))
    findings.extend(duplicate_findings(results, "hook", "P06", "集尾钩子"))

    assets = known_assets(project)
    if assets:
        for result in results:
            text = read_text(project / "scripts" / result.filename)
            declared = extract_asset_list(field_value(text, "本集资产引用"))
            unknown = sorted(declared - assets)
            if unknown:
                level = "FAIL" if config.get("require_visual_ready") else "WARN"
                finding = Finding(level, "A01", result.filename, "资产源事实未登记：" + "；".join(unknown))
                findings.append(finding)
                result.findings.append(finding)
    else:
        findings.append(Finding("WARN", "A02", "visual-assets/source-facts.md", "尚未建立可解析的@资产集合"))

    visual_findings, visual_stats = validate_visual(
        project, expected, bool(config.get("require_visual_ready"))
    )
    findings.extend(visual_findings)

    report = markdown_report(project, config, results, findings, visual_stats)
    if args.report:
        report_path = Path(args.report).expanduser().resolve()
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(report, encoding="utf-8", newline="\n")
    if args.json_path:
        json_path = Path(args.json_path).expanduser().resolve()
        json_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "project": str(project),
            "config": config,
            "summary": dict(Counter(f.level for f in findings)),
            "visual": visual_stats,
            "episodes": [
                {
                    "episode": result.episode,
                    "file": result.filename,
                    "title": result.title,
                    "core": result.core,
                    "hook": result.hook,
                    "scenes": result.scenes,
                    "content_chars": result.content_chars,
                    "assets": result.assets,
                }
                for result in results
            ],
            "findings": [finding.__dict__ for finding in findings],
        }
        json_path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
            newline="\n",
        )

    counts = Counter(f.level for f in findings)
    print(
        f"VALIDATION-{'PASS' if counts['FAIL'] == 0 else 'FAIL'} "
        f"episodes={len(results)}/{expected}; fail={counts['FAIL']}; warn={counts['WARN']}; "
        f"visual_ready={visual_stats['ready']}/{expected}"
    )
    if args.report:
        print(f"report={Path(args.report).expanduser().resolve()}")
    return 0 if counts["FAIL"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
