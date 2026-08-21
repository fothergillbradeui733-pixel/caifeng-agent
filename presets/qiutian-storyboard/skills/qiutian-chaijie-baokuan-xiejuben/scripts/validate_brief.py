#!/usr/bin/env python3
"""Validate that a short-drama project brief is ready for story mapping."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path


REQUIRED_DECISIONS = (
    "目标受众与平台",
    "格式、集数与时长",
    "核心情绪与观看承诺",
    "类型、年代与世界边界",
    "主角身份与开局状态",
    "开篇剥夺",
    "外部欲望与量化目标",
    "内在误区与成长方向",
    "故事引擎",
    "规则、代价与禁区",
    "首次触发与发现过程",
    "核心资产与事业阶梯",
    "核心关系与边界",
    "阶段反派与资源升级",
    "前5集承诺",
    "中段最大失败与修复",
    "终局对决与回收",
    "视觉气质与冲突尺度",
    "内容与制作禁区",
    "原创隔离边界",
)

REQUIRED_ENGINE_RULES = (
    "功能",
    "触发",
    "输入与输出",
    "成败反馈",
    "代价",
    "禁区",
    "错误后果",
    "知识边界",
    "升级",
    "终局退出",
)

REQUIRED_STRESS_TESTS = (
    "欲望独立性",
    "因果必要性",
    "引擎边界",
    "关系能动性",
    "理性反派",
    "全季承载力",
    "中段反证",
    "终局回收",
    "原创隔离",
)

REQUIRED_REPLAY_FIELDS = (
    "一句话故事",
    "前5集承诺",
    "故事引擎成功/失败/升级",
    "中段最大失败",
    "终局兑现",
    "独特性锚点",
)

DECISION_SOURCES = ("用户确认", "主创判断", "文本事实", "有限推断")
PLACEHOLDERS = ("待填写", "待探索", "暂定", "未通过", "{{", "}}")


@dataclass(frozen=True)
class Finding:
    code: str
    message: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate PROJECT-BRIEF.md before story-bible and plot-map work."
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--project", help="Project directory containing PROJECT-BRIEF.md")
    group.add_argument("--brief", help="Direct path to PROJECT-BRIEF.md")
    parser.add_argument("--report", help="Optional Markdown report path")
    return parser.parse_args()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def extract_section(text: str, heading: str) -> str:
    match = re.search(rf"^##\s+{re.escape(heading)}\s*$", text, re.MULTILINE)
    if not match:
        return ""
    next_heading = re.search(r"^##\s+", text[match.end() :], re.MULTILINE)
    end = match.end() + next_heading.start() if next_heading else len(text)
    return text[match.end() : end].strip()


def table_rows(section: str) -> list[list[str]]:
    rows: list[list[str]] = []
    for line in section.splitlines():
        stripped = line.strip()
        if not stripped.startswith("|") or not stripped.endswith("|"):
            continue
        cells = [cell.strip() for cell in stripped[1:-1].split("|")]
        if cells and all(re.fullmatch(r":?-{2,}:?", cell) for cell in cells):
            continue
        rows.append(cells)
    return rows[1:] if rows else []


def is_complete(value: str) -> bool:
    normalized = value.strip().strip("。")
    return bool(normalized) and not any(token in normalized for token in PLACEHOLDERS)


def rows_by_key(section: str, expected_columns: int) -> dict[str, list[str]]:
    indexed: dict[str, list[str]] = {}
    for row in table_rows(section):
        if len(row) >= expected_columns and row[0]:
            indexed[row[0]] = row
    return indexed


def validate_brief(text: str) -> list[Finding]:
    findings: list[Finding] = []

    state = rows_by_key(extract_section(text, "访谈状态"), 2)
    required_state = {
        "访谈阶段": {"已完成", "自主决策已完成"},
        "下一高影响未决问题": {"无"},
        "当前矛盾": {"无"},
        "立项门状态": {"通过"},
    }
    for key, accepted in required_state.items():
        row = state.get(key)
        if not row:
            findings.append(Finding("B01", f"访谈状态缺少“{key}”"))
        elif row[1].strip().strip("。") not in accepted:
            findings.append(
                Finding("B02", f"访谈状态“{key}”尚未完成：{row[1] or '空'}")
            )

    decisions = rows_by_key(extract_section(text, "已锁定契约"), 4)
    for key in REQUIRED_DECISIONS:
        row = decisions.get(key)
        if not row:
            findings.append(Finding("B03", f"已锁定契约缺少“{key}”"))
            continue
        if not is_complete(row[1]):
            findings.append(Finding("B04", f"“{key}”的决定仍为空或含占位符"))
        if not is_complete(row[2]) or not any(source in row[2] for source in DECISION_SOURCES):
            findings.append(
                Finding("B05", f"“{key}”缺少合法决定来源和取舍理由")
            )
        if row[3].strip() != "已锁定":
            findings.append(Finding("B06", f"“{key}”状态不是“已锁定”"))

    replay = extract_section(text, "立项共识回放")
    for label in REQUIRED_REPLAY_FIELDS:
        match = re.search(rf"^-\s*{re.escape(label)}：(.+?)\s*$", replay, re.MULTILINE)
        if not match or not is_complete(match.group(1)):
            findings.append(Finding("B07", f"立项共识回放缺少有效的“{label}”"))

    decision_log = table_rows(extract_section(text, "决策日志"))
    if not decision_log or not any(
        len(row) >= 6 and all(is_complete(cell) for cell in row[:6])
        for row in decision_log
    ):
        findings.append(Finding("B08", "决策日志至少需要一条完整记录"))

    assumptions = table_rows(extract_section(text, "主创假设台账"))
    if not assumptions or any(
        len(row) < 4
        or not all(is_complete(cell) for cell in row[:3])
        or row[3].strip() not in {"已锁定", "不适用"}
        for row in assumptions
    ):
        findings.append(Finding("B09", "主创假设台账存在空项、占位符或未锁定状态"))

    engine = rows_by_key(extract_section(text, "故事引擎规则"), 3)
    for key in REQUIRED_ENGINE_RULES:
        row = engine.get(key)
        if not row or not is_complete(row[1]) or not is_complete(row[2]):
            findings.append(Finding("B10", f"故事引擎规则“{key}”缺少决定或场面证据"))

    tests = rows_by_key(extract_section(text, "矛盾与压力测试"), 3)
    for key in REQUIRED_STRESS_TESTS:
        row = tests.get(key)
        if not row:
            findings.append(Finding("B11", f"压力测试缺少“{key}”"))
            continue
        if not is_complete(row[1]):
            findings.append(Finding("B12", f"压力测试“{key}”缺少具体证据"))
        if row[2].strip() != "通过":
            findings.append(Finding("B13", f"压力测试“{key}”尚未通过"))

    taboo = extract_section(text, "明确禁区")
    if not is_complete(taboo):
        findings.append(Finding("B14", "明确禁区为空或仍含占位符"))

    unresolved = extract_section(text, "未决事项")
    unresolved_lines = [line.strip() for line in unresolved.splitlines() if line.strip()]
    if unresolved_lines != ["- 无阻塞项。"]:
        findings.append(
            Finding("B15", "未决事项必须精确收敛为一行“- 无阻塞项。”")
        )

    return findings


def render_report(brief: Path, findings: list[Finding]) -> str:
    status = "PASS" if not findings else "FAIL"
    lines = [
        "# 立项访谈校验报告",
        "",
        f"- 文件：`{brief}`",
        f"- 结果：**{status}**",
        f"- 问题数：{len(findings)}",
        "",
    ]
    if findings:
        lines.extend(["## 问题", ""])
        lines.extend(f"- `{item.code}` {item.message}" for item in findings)
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    brief = (
        Path(args.brief).expanduser().resolve()
        if args.brief
        else Path(args.project).expanduser().resolve() / "PROJECT-BRIEF.md"
    )
    if not brief.is_file():
        raise SystemExit(f"PROJECT-BRIEF.md is missing: {brief}")

    findings = validate_brief(read_text(brief))
    if args.report:
        report = Path(args.report).expanduser().resolve()
        report.parent.mkdir(parents=True, exist_ok=True)
        report.write_text(render_report(brief, findings), encoding="utf-8", newline="\n")

    if findings:
        print(f"BRIEF-FAIL file={brief}; findings={len(findings)}")
        for item in findings:
            print(f"{item.code}: {item.message}")
        return 1

    print(f"BRIEF-PASS file={brief}; findings=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
