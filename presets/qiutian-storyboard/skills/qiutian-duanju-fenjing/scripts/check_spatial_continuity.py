#!/usr/bin/env python3
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
from typing import Iterable, Sequence


BLOCK_RE = re.compile(r"^── Block\s+(\d+)\s+\|\s+[0-9.]+s\s+──\s*$", re.MULTILINE)
SPATIAL_RE = re.compile(r"^(?:🧭\s*)?(?:\*\*)?(?:起始)?空间状态(?:\*\*)?\s*[：:]\s*(.*)$", re.MULTILINE)
NESTED_GROUP_RE = re.compile(r"^\s*#{1,6}\s*G\d+\b|^\s*G\d+\s*[:：]", re.MULTILINE | re.IGNORECASE)
ENTRY_RE = re.compile(r"^@?([^（(]+)[（(]([^）)]+)[）)]$")

POSTURE_PREFIXES = (
    "站在", "站", "立在", "立", "伫立", "倚立",
    "坐在", "坐", "端坐", "盘坐", "瘫坐",
    "跪在", "跪", "半跪", "单膝跪",
    "蹲在", "蹲", "躺在", "躺", "卧在", "卧", "仰躺",
    "趴在", "趴", "伏在", "伏", "倚在", "倚", "靠在", "靠", "背靠",
    "俯身", "弯腰", "前倾", "悬浮", "腾空", "凌空",
    "骑在", "骑", "踏在", "踏", "踩在", "踩", "抱膝",
)


@dataclass(frozen=True)
class Issue:
    code: str
    line: int
    detail: str


def line_number(text: str, position: int) -> int:
    return text.count("\n", 0, position) + 1


def posture_is_valid(value: str) -> bool:
    state = value.strip()
    return state.startswith("已离场→") or state.startswith(POSTURE_PREFIXES)


def check_text(text: str) -> list[Issue]:
    issues: list[Issue] = []
    for match in NESTED_GROUP_RE.finditer(text):
        issues.append(Issue(
            "spatial_nested_group",
            line_number(text, match.start()),
            f"{match.group(0).strip()}｜Block 本身就是一个完整生成组，禁止再加 G 分组",
        ))

    matches = list(BLOCK_RE.finditer(text))
    if not matches:
        return issues + [Issue("spatial_no_blocks", 1, "未找到标准 Block 标题")]

    for index, match in enumerate(matches):
        block_no = int(match.group(1))
        start = match.start()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        block = text[start:end]
        block_line = line_number(text, start)
        state_matches = list(SPATIAL_RE.finditer(block))
        if not state_matches:
            issues.append(Issue(
                "spatial_state_missing",
                block_line,
                f"Block {block_no} 缺「🧭 起始空间状态：」",
            ))
            continue
        if len(state_matches) > 1:
            issues.append(Issue(
                "spatial_state_duplicate",
                block_line + block.count("\n", 0, state_matches[1].start()),
                f"Block {block_no} 有 {len(state_matches)} 条起始/旧空间状态；每个 Block 只能有一条",
            ))

        for state_match in state_matches:
            state_line = block_line + block.count("\n", 0, state_match.start())
            entries = [entry.strip() for entry in re.split(r"[｜|]", state_match.group(1)) if entry.strip()]
            for entry in entries:
                parsed = ENTRY_RE.match(entry)
                if not parsed:
                    issues.append(Issue(
                        "spatial_entry_invalid",
                        state_line,
                        f"Block {block_no} 空间项格式错误：{entry}",
                    ))
                    continue
                role, state = parsed.group(1).strip(), parsed.group(2).strip()
                if not posture_is_valid(state):
                    issues.append(Issue(
                        "spatial_posture_missing",
                        state_line,
                        f"Block {block_no}｜{role}({state}) 未以姿态动词或「已离场→」开头",
                    ))
    return issues


def collect_files(paths: Sequence[str]) -> list[Path]:
    files: set[Path] = set()
    for raw in paths:
        path = Path(raw)
        if path.is_file():
            files.add(path)
        elif path.is_dir():
            files.update(item for item in path.rglob("*") if item.suffix.lower() in {".txt", ".md"})
    return sorted(files)


def format_report(path: Path, issues: Iterable[Issue]) -> str:
    found = list(issues)
    if not found:
        return f"PASS {path}"
    lines = [f"FAIL {path} ({len(found)} issues)"]
    lines.extend(f"  [{issue.code}] line {issue.line}: {issue.detail}" for issue in found)
    return "\n".join(lines)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="检查分镜 Block 起始空间状态结构（兼容旧空间状态标签）")
    parser.add_argument("paths", nargs="+", help="分镜 .txt/.md 文件或目录")
    args = parser.parse_args(argv)
    files = collect_files(args.paths)
    if not files:
        parser.error("没有找到可检查的 .txt/.md 文件")

    failed = False
    for path in files:
        issues = check_text(path.read_text(encoding="utf-8"))
        print(format_report(path, issues))
        failed = failed or bool(issues)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
