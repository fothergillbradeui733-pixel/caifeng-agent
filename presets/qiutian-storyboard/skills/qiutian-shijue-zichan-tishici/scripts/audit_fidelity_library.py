#!/usr/bin/env python3
"""Audit an exact full-season library against a normalized READY handoff."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from audit_handoff_suggestions import (
    CARD_RE,
    format_episode_set,
    parse_complete_cards,
    parse_episode_expression,
)
from import_comic_handoff import import_handoff
from prepare_fidelity_library import CONTRACT_VERSION


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def metadata(text: str, key: str) -> str:
    match = re.search(rf"(?m)^{re.escape(key)}\s*[：:]\s*(.+?)\s*$", text)
    return match.group(1).strip() if match else ""


def card_metadata(text: str) -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    for match in CARD_RE.finditer(text):
        body = match.group("body")
        values: dict[str, str] = {}
        for key in ("类型", "使用状态", "出现集"):
            value = re.search(rf"(?m)^{key}\s*[：:]\s*(.+?)\s*$", body)
            values[key] = value.group(1).strip() if value else ""
        result[match.group("name")] = values
    return result


def audit(
    handoff: Path, library: Path, style: str, pipeline: str = "16:9 3D漫"
) -> dict[str, object]:
    payload = import_handoff(handoff, requested=None)
    text = read_text(library)
    complete, incomplete, duplicates = parse_complete_cards(library)
    cards = card_metadata(text)
    expected = {
        str(item["asset_name"])[1:]: item for item in payload["candidate_cards"]
    }
    active = {
        name for name, values in cards.items() if values.get("使用状态") == "有效"
    }
    expected_names = set(expected)
    fails: list[str] = []

    provenance = {
        "生成契约版本": CONTRACT_VERSION,
        "来源技能": str(payload["source_skill"]),
        "来源交接schema": str(payload["schema_version"]),
        "来源交接指纹": str(payload["contract_fingerprint"]),
        "建库视觉风格": style,
        "建库下游管线": pipeline,
    }
    for key, wanted in provenance.items():
        actual = metadata(text, key)
        if actual != wanted:
            fails.append(f"[FAL1] {key} 不匹配：应为 {wanted}，实际为 {actual or '缺失'}")

    for name in sorted(expected_names - complete):
        if name in incomplete:
            fails.append(
                f"[FAL2] @{name} 卡片不完整：{'、'.join(incomplete[name])}"
            )
        else:
            fails.append(f"[FAL2] 缺少上游建卡资产：@{name}")
    for name in sorted(expected_names - active):
        if name in cards:
            fails.append(f"[FAL3] 上游建卡资产未标记为有效：@{name}")
    for name in sorted(active - expected_names):
        fails.append(f"[FAL4] 存在上游建卡清单之外的有效资产：@{name}")
    for name in duplicates:
        fails.append(f"[FAL5] 资产卡重复：@{name}")

    episode_mismatches: dict[str, dict[str, str]] = {}
    type_mismatches: dict[str, dict[str, str]] = {}
    for name, item in expected.items():
        if name not in cards:
            continue
        wanted_type = str(item["entity_type"])
        actual_type = cards[name].get("类型", "")
        if actual_type != wanted_type:
            type_mismatches[name] = {"expected": wanted_type, "actual": actual_type}
            fails.append(
                f"[FAL6] @{name} 类型不匹配：应为 {wanted_type}，实际为 {actual_type or '缺失'}"
            )
        wanted_episodes = set(str(value) for value in item["episodes"])
        actual_expression = cards[name].get("出现集", "")
        if parse_episode_expression(actual_expression) != wanted_episodes:
            expected_expression = format_episode_set(wanted_episodes)
            episode_mismatches[name] = {
                "expected": expected_expression,
                "actual": actual_expression,
            }
            fails.append(
                f"[FAL7] @{name} 出现集不匹配：应为 {expected_expression}，"
                f"实际为 {actual_expression or '缺失'}"
            )

    return {
        "status": "FAIL" if fails else "PASS",
        "handoff": str(handoff),
        "library": str(library),
        "source_skill": payload["source_skill"],
        "schema_version": payload["schema_version"],
        "contract_fingerprint": payload["contract_fingerprint"],
        "expected_card_count": len(expected_names),
        "active_card_count": len(active),
        "expected_cards": sorted(expected_names),
        "active_cards": sorted(active),
        "extra_active_cards": sorted(active - expected_names),
        "missing_active_cards": sorted(expected_names - active),
        "episode_mismatches": episode_mismatches,
        "type_mismatches": type_mismatches,
        "fails": fails,
    }


def print_human(report: dict[str, object]) -> None:
    print(f"FIDELITY-LIBRARY-AUDIT {report['status']}")
    if "handoff" in report:
        print(f"handoff={report['handoff']}")
    if "library" in report:
        print(f"library={report['library']}")
    if "expected_card_count" in report:
        print(f"expected_cards={report['expected_card_count']}")
    if "active_card_count" in report:
        print(f"active_cards={report['active_card_count']}")
    for failure in report["fails"]:
        print(f"FAIL {failure}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="核对正式资产库是否精确等于 READY 分集中的建卡资产集合"
    )
    parser.add_argument("handoff", type=Path, help="visual-assets/handoff.md")
    parser.add_argument("--library", type=Path, required=True, help="正式视觉资产库")
    parser.add_argument("--style", required=True, help="建库视觉风格值")
    parser.add_argument("--pipeline", default="16:9 3D漫", help="建库下游管线值")
    parser.add_argument("--json", action="store_true", help="输出 JSON")
    parser.add_argument("--output", type=Path, help="另存 JSON 报告")
    args = parser.parse_args()

    try:
        report = audit(
            args.handoff.resolve(strict=True),
            args.library.resolve(strict=True),
            args.style.strip(),
            args.pipeline.strip(),
        )
    except (OSError, ValueError) as exc:
        report = {"status": "FAIL", "fails": [f"[FAL0] {exc}"]}

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print_human(report)
    return 1 if report["status"] == "FAIL" else 0


if __name__ == "__main__":
    sys.exit(main())
