# -*- coding: utf-8 -*-

"""Audit closure from comic-adapt global suggested @ names to full asset cards.

This parser intentionally ignores READY/import/hash validity.  Its only source is the
Markdown table below ``## 全局实体索引`` so a stale handoff can still provide the
mandatory suggested-state inventory while facts are reverified elsewhere.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from collections import defaultdict
from pathlib import Path
from typing import Iterable


AT_RE = re.compile(r"@([A-Za-z0-9_\-\u4e00-\u9fff·]+)")
CARD_RE = re.compile(
    r"(?ms)^###\s+@(?P<name>[A-Za-z0-9_\-\u4e00-\u9fff·]+)\s*$"
    r"(?P<body>.*?)(?=^###\s+@|^##\s+|\Z)"
)
REQUIRED_CARD_FIELDS = (
    "类型：",
    "使用状态：",
    "替代资产：",
    "别名：",
    "出现集：",
    "说明：",
    "文生图提示词：",
)


@dataclass(frozen=True)
class Suggestion:
    entity_id: str
    entity_type: str
    canonical_name: str
    suggested_name: str
    source_path: str
    row_number: int
    raw_cell: str


@dataclass
class AuditReport:
    handoff: str
    library: str | None
    suggestion_occurrences: int
    suggestion_count: int
    complete_card_count: int
    suggested_names: list[str]
    complete_card_names: list[str]
    missing_names: list[str]
    incomplete_cards: dict[str, list[str]]
    duplicate_cards: list[str]
    state_episode_mismatches: dict[str, dict[str, str]]
    timeline_episode_mismatches: dict[str, dict[str, str]]
    suggestions: list[Suggestion]
    fails: list[str]

    def to_dict(self) -> dict:
        payload = asdict(self)
        payload["status"] = "FAIL" if self.fails else "PASS"
        return payload


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def table_cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def global_index_lines(text: str) -> Iterable[tuple[int, str]]:
    in_section = False
    for line_number, line in enumerate(text.splitlines(), 1):
        if re.match(r"^##\s+全局实体索引\s*$", line.strip()):
            in_section = True
            continue
        if in_section and re.match(r"^##\s+", line.strip()):
            break
        if in_section:
            yield line_number, line


def parse_handoff_suggestions(path: str | Path) -> list[Suggestion]:
    handoff = Path(path)
    lines = list(global_index_lines(read_text(handoff)))
    header_index = -1
    headers: list[str] = []
    for index, (_, line) in enumerate(lines):
        if not line.lstrip().startswith("|"):
            continue
        candidate = table_cells(line)
        if "实体ID" in candidate and any("建议@" in cell for cell in candidate):
            header_index = index
            headers = candidate
            break
    if header_index < 0:
        raise ValueError("未找到 ## 全局实体索引 下含建议@列的 Markdown 表")

    id_col = headers.index("实体ID")
    type_col = headers.index("类型")
    canonical_col = headers.index("剧本规范名")
    suggestion_col = next(i for i, value in enumerate(headers) if "建议@" in value)
    source_col = headers.index("源事实路径") if "源事实路径" in headers else None

    suggestions: list[Suggestion] = []
    for row_number, line in lines[header_index + 1 :]:
        if not line.lstrip().startswith("|") or re.match(r"^\s*\|\s*:?-+", line):
            continue
        row = table_cells(line)
        required_index = max(id_col, type_col, canonical_col, suggestion_col)
        if len(row) <= required_index:
            continue
        raw_cell = row[suggestion_col]
        for match in AT_RE.finditer(raw_cell):
            suggestions.append(
                Suggestion(
                    entity_id=row[id_col],
                    entity_type=row[type_col],
                    canonical_name=row[canonical_col],
                    suggested_name=match.group(1),
                    source_path=(
                        row[source_col]
                        if source_col is not None and source_col < len(row)
                        else ""
                    ),
                    row_number=row_number,
                    raw_cell=raw_cell,
                )
            )
    return suggestions


def parse_complete_cards(path: str | Path) -> tuple[set[str], dict[str, list[str]], list[str]]:
    text = read_text(Path(path))
    bodies: dict[str, list[str]] = {}
    for match in CARD_RE.finditer(text):
        bodies.setdefault(match.group("name"), []).append(match.group("body"))

    complete: set[str] = set()
    incomplete: dict[str, list[str]] = {}
    duplicates = sorted(name for name, blocks in bodies.items() if len(blocks) > 1)
    for name, blocks in bodies.items():
        body = blocks[0]
        missing = [field for field in REQUIRED_CARD_FIELDS if field not in body]
        prompt = re.search(
            r"(?ms)^文生图提示词：\s*\n\s*```(?:text)?\s*\n(?P<prompt>.*?)\n```",
            body,
        )
        if not prompt or not prompt.group("prompt").strip():
            missing.append("非空文生图提示词代码块")
        if missing:
            incomplete[name] = missing
        else:
            complete.add(name)
    return complete, incomplete, duplicates


def episode_number(value: str) -> int:
    match = re.search(r"\d+", value)
    return int(match.group()) if match else 10**9


def format_episode_set(values: set[str]) -> str:
    numbers = sorted({episode_number(value) for value in values if re.search(r"\d+", value)})
    if not numbers:
        return ""
    groups: list[tuple[int, int]] = []
    start = previous = numbers[0]
    for number in numbers[1:]:
        if number == previous + 1:
            previous = number
            continue
        groups.append((start, previous))
        start = previous = number
    groups.append((start, previous))
    return "、".join(
        f"EP-{start:02d}" if start == end else f"EP-{start:02d}–EP-{end:02d}"
        for start, end in groups
    )


def parse_episode_expression(value: str) -> set[str]:
    episodes: set[str] = set()
    for start_raw, end_raw in re.findall(
        r"EP-?(\d{1,3})\s*[–—至到-]\s*EP-?(\d{1,3})", value
    ):
        start, end = int(start_raw), int(end_raw)
        if start <= end:
            episodes.update(f"EP-{number:02d}" for number in range(start, end + 1))
    for raw in re.findall(r"EP-?(\d{1,3})", value):
        episodes.add(f"EP-{int(raw):02d}")
    return episodes


def parse_episode_suggestion_occurrences(handoff_path: str | Path) -> dict[str, set[str]]:
    """Read exact @ occurrences from visual-assets/episodes/EP-*.md.

    A later row may carry the true first switch anchor (for example, a state begins
    midway through EP-32 but first receives its exact @ row in EP-33).  In that case
    only that anchored first episode is added; open-ended declared ranges are not
    expanded because doing so would erase later state interruptions.
    """
    episodes_dir = Path(handoff_path).parent / "episodes"
    result: dict[str, set[str]] = defaultdict(set)
    for path in sorted(episodes_dir.glob("EP-*.md"), key=lambda item: episode_number(item.stem)):
        current_ep = path.stem
        header: list[str] | None = None
        for line in read_text(path).splitlines():
            if line.startswith("## "):
                header = None
                continue
            if not line.lstrip().startswith("|"):
                continue
            row = table_cells(line)
            if any("建议" in value and "@" in value for value in row):
                header = row
                continue
            if header is None or not row or re.match(r"^:?-+", row[0]):
                continue
            if len(row) < len(header):
                row += [""] * (len(header) - len(row))
            suggestion_col = next(
                (index for index, value in enumerate(header) if "建议" in value and "@" in value),
                None,
            )
            if suggestion_col is None or suggestion_col >= len(row):
                continue
            names = AT_RE.findall(row[suggestion_col])
            anchor_col = next((index for index, value in enumerate(header) if "切换锚" in value), None)
            for name in names:
                result[name].add(current_ep)
                if anchor_col is None or not row[anchor_col]:
                    continue
                anchored = re.findall(r"EP-?(\d{1,3})", row[anchor_col])
                if anchored:
                    first_ep = f"EP-{int(anchored[0]):02d}"
                    if episode_number(first_ep) < episode_number(current_ep):
                        result[name].add(first_ep)
    return dict(result)


def parse_library_episode_fields(path: str | Path) -> tuple[dict[str, str], dict[str, str]]:
    text = read_text(Path(path))
    card_episodes: dict[str, str] = {}
    for match in CARD_RE.finditer(text):
        episode_match = re.search(r"(?m)^出现集：\s*(.+?)\s*$", match.group("body"))
        if episode_match:
            card_episodes[match.group("name")] = episode_match.group(1).strip()

    timeline_episodes: dict[str, str] = {}
    timeline_match = re.search(
        r"(?ms)^##\s+状态时间线总表\s*$\n(?P<body>.*?)(?=^##\s+|\Z)", text
    )
    if timeline_match:
        for line in timeline_match.group("body").splitlines():
            row = table_cells(line) if line.lstrip().startswith("|") else []
            if len(row) >= 4 and row[0].startswith("@") and row[0] != "@资产名_状态词":
                timeline_episodes[row[0][1:]] = row[2]
    return card_episodes, timeline_episodes


def audit(handoff_path: str | Path, library_path: str | Path | None = None) -> AuditReport:
    suggestions = parse_handoff_suggestions(handoff_path)
    suggested_names = list(dict.fromkeys(item.suggested_name for item in suggestions))
    complete: set[str] = set()
    incomplete: dict[str, list[str]] = {}
    duplicates: list[str] = []
    state_episode_mismatches: dict[str, dict[str, str]] = {}
    timeline_episode_mismatches: dict[str, dict[str, str]] = {}
    fails: list[str] = []

    if not suggestions:
        fails.append("[HSG1] 全局实体索引的建议@列没有解析到任何 @资产名")
    if library_path is not None:
        complete, incomplete, duplicates = parse_complete_cards(library_path)
        missing = [name for name in suggested_names if name not in complete]
        for name in missing:
            if name in incomplete:
                fields = "、".join(incomplete[name])
                fails.append(f"[HSG2] @{name} 存在卡标题但卡片不完整：{fields}")
            else:
                fails.append(f"[HSG2] 缺少建议状态完整卡：@{name}")
        for name in duplicates:
            if name in suggested_names:
                fails.append(f"[HSG3] 建议资产卡重复：@{name}")

        entity_names: dict[str, set[str]] = defaultdict(set)
        for item in suggestions:
            entity_names[item.entity_id].add(item.suggested_name)
        state_names = {
            name
            for names in entity_names.values()
            for name in names
            if len(names) > 1 or "_" in name
        }
        exact_occurrences = parse_episode_suggestion_occurrences(handoff_path)
        card_episodes, timeline_episodes = parse_library_episode_fields(library_path)
        for name in sorted(state_names):
            expected_set = exact_occurrences.get(name, set())
            if not expected_set or name not in complete:
                continue
            expected = format_episode_set(expected_set)
            actual = card_episodes.get(name, "")
            if parse_episode_expression(actual) != expected_set:
                state_episode_mismatches[name] = {"expected": expected, "actual": actual}
                fails.append(
                    f"[HSG4] 状态卡 @{name} 出现集不等于逐集精确记录："
                    f"应为 {expected}，实际为 {actual or '缺失'}"
                )
            timeline_actual = timeline_episodes.get(name, "")
            if parse_episode_expression(timeline_actual) != expected_set:
                timeline_episode_mismatches[name] = {
                    "expected": expected,
                    "actual": timeline_actual,
                }
                fails.append(
                    f"[HSG5] 状态时间线 @{name} 生效集不等于逐集精确记录："
                    f"应为 {expected}，实际为 {timeline_actual or '缺失'}"
                )
    else:
        missing = []

    return AuditReport(
        handoff=str(Path(handoff_path)),
        library=str(Path(library_path)) if library_path is not None else None,
        suggestion_occurrences=len(suggestions),
        suggestion_count=len(suggested_names),
        complete_card_count=len(complete),
        suggested_names=suggested_names,
        complete_card_names=sorted(complete),
        missing_names=missing,
        incomplete_cards={name: fields for name, fields in incomplete.items() if name in suggested_names},
        duplicate_cards=duplicates,
        state_episode_mismatches=state_episode_mismatches,
        timeline_episode_mismatches=timeline_episode_mismatches,
        suggestions=suggestions,
        fails=fails,
    )


def print_human(report: AuditReport) -> None:
    status = "FAIL" if report.fails else "PASS"
    print(f"HANDOFF_SUGGESTIONS {status}")
    print(f"handoff={report.handoff}")
    if report.library:
        print(f"library={report.library}")
    print(f"suggestion_occurrences={report.suggestion_occurrences}")
    print(f"suggestion_count={report.suggestion_count}")
    print(f"complete_card_count={report.complete_card_count}")
    print(f"missing_count={len(report.missing_names)}")
    print(f"state_episode_mismatch_count={len(report.state_episode_mismatches)}")
    print(f"timeline_episode_mismatch_count={len(report.timeline_episode_mismatches)}")
    for item in report.fails:
        print(f"FAIL {item}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="核对 comic-adapt 全局实体索引的每个建议 @ 是否拥有独立完整卡"
    )
    parser.add_argument("handoff", help="visual-assets/handoff.md 路径")
    parser.add_argument("--library", help="待核对的完整视觉资产库 Markdown")
    parser.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    parser.add_argument("--output", help="另存 JSON 报告路径")
    args = parser.parse_args()

    try:
        report = audit(args.handoff, args.library)
    except (OSError, ValueError) as exc:
        payload = {"status": "FAIL", "fails": [f"[HSG0] {exc}"]}
        if args.json:
            print(json.dumps(payload, ensure_ascii=False, indent=2))
        else:
            print("HANDOFF_SUGGESTIONS FAIL")
            print(f"FAIL [HSG0] {exc}")
        return 1

    payload = report.to_dict()
    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print_human(report)
    return 1 if report.fails else 0


if __name__ == "__main__":
    sys.exit(main())
