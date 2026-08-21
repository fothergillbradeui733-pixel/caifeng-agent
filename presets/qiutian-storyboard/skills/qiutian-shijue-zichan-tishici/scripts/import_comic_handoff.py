#!/usr/bin/env python3
"""Validate and normalize a comic-adapt visual handoff for asset generation."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


SUPPORTED_SCHEMAS = {
    "comic-adapt-visual-handoff/1.0": "comic-adapt",
    "comic-adapt-fidelity-visual-handoff/1.0": "comic-adapt-fidelity",
}
ALLOWED_TYPES = {"角色", "场景", "道具", "群像", "生物", "不可见声音角色", "3D Q版小人"}
ALLOWED_TENDENCIES = {"必须建卡", "建议建卡", "逐镜内联", "不资产化", "待确认"}
ALLOWED_DECISIONS = {"建卡", "逐镜内联", "不资产化"}
ALLOWED_DIMENSIONS = {"—", "形态", "体态", "服装", "伤势", "身份呈现", "特殊"}
TYPE_PREFIXES = {
    "角色": "CHR",
    "场景": "SCN",
    "道具": "PRP",
    "群像": "GRP",
    "生物": "BIO",
    "不可见声音角色": "VOC",
    "3D Q版小人": "Q",
}
PLACEHOLDER_RE = re.compile(r"待补|待确认|待分配|DRAFT|\[[^\]]+\]|\{[^}]+\}")


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def metadata(text: str, key: str) -> str:
    match = re.search(rf"^{re.escape(key)}[：:]\s*(.+?)\s*$", text, re.MULTILINE)
    return match.group(1).strip() if match else ""


def section(text: str, heading: str) -> str:
    match = re.search(
        rf"^##\s+{re.escape(heading)}\s*$\n(?P<body>.*?)(?=^##\s+|\Z)",
        text.replace("\r\n", "\n"),
        re.MULTILINE | re.DOTALL,
    )
    return match.group("body").strip() if match else ""


def parse_table(text: str, heading: str) -> list[dict[str, str]]:
    lines = [line.strip() for line in section(text, heading).splitlines() if line.strip().startswith("|")]
    if len(lines) < 2:
        return []
    headers = [cell.strip() for cell in lines[0].strip("|").split("|")]
    rows: list[dict[str, str]] = []
    for line in lines[1:]:
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if all(re.fullmatch(r":?-+:?", cell) for cell in cells):
            continue
        if len(cells) != len(headers):
            raise ValueError(f"Malformed table row in {heading}: {line}")
        rows.append(dict(zip(headers, cells)))
    return rows


def unresolved_is_empty(text: str, heading: str) -> bool:
    values = [line.strip() for line in section(text, heading).splitlines() if line.strip()]
    return len(values) == 1 and re.fullmatch(r"-?\s*无", values[0]) is not None


def parse_episode_range(value: str | None) -> set[int] | None:
    if not value:
        return None
    single = re.fullmatch(r"\s*(\d+)\s*", value)
    if single:
        return {int(single.group(1))}
    ranged = re.fullmatch(r"\s*(\d+)\s*[-–—]\s*(\d+)\s*", value)
    if not ranged:
        raise ValueError("--episodes must be N or N-M")
    start, end = map(int, ranged.groups())
    if end < start:
        raise ValueError("--episodes end must not precede start")
    return set(range(start, end + 1))


def episode_number(token: str) -> int:
    match = re.fullmatch(r"EP-0*(\d+)", token.strip())
    if not match:
        raise ValueError(f"Invalid episode token: {token}")
    return int(match.group(1))


def resolve_relative(project_root: Path, value: str) -> Path:
    if not value.strip():
        raise ValueError("empty path in handoff")
    root = project_root.resolve()
    candidate = Path(value)
    resolved = (candidate if candidate.is_absolute() else root / candidate).resolve()
    if resolved != root and root not in resolved.parents:
        raise ValueError(f"handoff path escapes project root: {value}")
    return resolved


def split_aliases(value: str) -> list[str]:
    if not value or value == "无":
        return []
    return [item.strip() for item in re.split(r"[、，,；;]", value) if item.strip() and item.strip() != "无"]


def normalize_person_label(value: str) -> str:
    value = value.strip()
    wrapped = re.fullmatch(r"（(.+)）", value)
    if wrapped:
        value = wrapped.group(1).strip()
    return re.sub(r"（画外）$", "", value).strip()


def script_inventory(text: str) -> list[dict[str, object]]:
    body = re.split(r"^【台账登记块】\s*$", text.replace("\r\n", "\n"), maxsplit=1, flags=re.MULTILINE)[0]
    lines = body.splitlines()
    scenes: list[dict[str, object]] = []
    scene_re = re.compile(r"^场次\s+(?P<scene>\d+-\d+)[：:]\s*(?:内|外)\s+(?P<location>.+?)\s+(?P<time>日|夜|晨|黄昏(?:·\S+)?)\s*$")
    for index, line in enumerate(lines):
        match = scene_re.match(line)
        if not match:
            continue
        end = next((cursor for cursor in range(index + 1, len(lines)) if re.match(r"^场次\s+\d+-\d+[：:]", lines[cursor])), len(lines))
        people: list[str] = []
        for candidate in lines[index + 1 : end]:
            cast = re.match(r"^出场人物[：:]\s*(.+)$", candidate)
            if cast:
                people = [item.strip() for item in re.split(r"[；;]", cast.group(1)) if item.strip()]
                break
        scenes.append({"scene": match.group("scene"), "location": match.group("location").strip(), "people": people})
    return scenes


def valid_state_range_and_anchor(value: str, episode: int) -> bool:
    parts = [part.strip() for part in value.split("｜", 1)]
    if len(parts) != 2 or not all(parts):
        return False
    range_ok = re.fullmatch(r"(?:EP-0*\d+\s*[–—-]\s*EP-0*\d+|EP-0*\d+\s+起(?:\s*·\s*.+)?|仅\s+EP-0*\d+|全剧本)", parts[0])
    anchor = re.fullmatch(r"EP-0*(?P<episode>\d+)(?:\s+场次\s+\d+-\d+|\s+集首)(?:\s*.+)?", parts[1])
    return range_ok is not None and anchor is not None and int(anchor.group("episode")) <= episode


def valid_switch_anchor(value: str, episode: int) -> bool:
    parts = [part.strip() for part in value.split("｜", 1)]
    if len(parts) != 2 or not all(parts):
        return False
    anchor = re.fullmatch(r"EP-0*(?P<episode>\d+)(?:\s+场次\s+\d+-\d+|\s+集首)(?:\s*.+)?", parts[1])
    return anchor is not None and int(anchor.group("episode")) <= episode


def import_handoff(handoff_path: Path, requested: set[int] | None) -> dict[str, object]:
    errors: list[str] = []
    handoff_path = handoff_path.resolve()
    project_root = handoff_path.parent.parent
    handoff_text = read_text(handoff_path)

    input_schema = metadata(handoff_text, "schema_version")
    if input_schema not in SUPPORTED_SCHEMAS:
        errors.append(f"unsupported schema_version: {input_schema or 'missing'}")
    if metadata(handoff_text, "交接状态") != "READY":
        errors.append("handoff is not READY")
    if not unresolved_is_empty(handoff_text, "未解决项"):
        errors.append("handoff unresolved items are not empty")

    source_path = resolve_relative(project_root, metadata(handoff_text, "源事实路径"))
    if not source_path.is_file():
        errors.append(f"source facts missing: {source_path}")
        source_text = ""
    else:
        source_text = read_text(source_path)
        if sha256(source_path) != metadata(handoff_text, "源事实SHA256"):
            errors.append("source facts hash mismatch")
        if metadata(source_text, "schema_version") != input_schema:
            errors.append("source facts schema mismatch")
        if not unresolved_is_empty(source_text, "待确认"):
            errors.append("source facts pending decisions are not empty")

    manifest_rows = parse_table(handoff_text, "分集交接文件")
    selected_rows: list[dict[str, str]] = []
    manifest_number_list = [episode_number(row.get("集数", "")) for row in manifest_rows]
    manifest_numbers = set(manifest_number_list)
    if len(manifest_number_list) != len(manifest_numbers):
        errors.append("manifest contains duplicate episode rows")
    if not manifest_rows:
        errors.append("manifest has no episode rows")
    if requested is not None:
        missing = sorted(requested - manifest_numbers)
        if missing:
            errors.append("requested episodes missing from manifest: " + ",".join(f"EP-{n:02d}" for n in missing))
    for row in manifest_rows:
        number = episode_number(row.get("集数", ""))
        if requested is None or number in requested:
            selected_rows.append(row)

    episode_payloads: list[dict[str, object]] = []
    referenced_ids: set[str] = set()
    for row in selected_rows:
        token = row["集数"]
        script_path = resolve_relative(project_root, row["剧本路径"])
        episode_path = resolve_relative(project_root, row["交接路径"])
        if row.get("状态") != "READY":
            errors.append(f"{token} manifest status is not READY")
        script_text = ""
        if not script_path.is_file():
            errors.append(f"{token} script missing: {script_path}")
        else:
            script_text = read_text(script_path)
            if sha256(script_path) != row.get("剧本SHA256"):
                errors.append(f"{token} script hash mismatch")
        if not episode_path.is_file():
            errors.append(f"{token} episode handoff missing: {episode_path}")
            continue
        if sha256(episode_path) != row.get("交接SHA256"):
            errors.append(f"{token} episode handoff hash mismatch")
        episode_text = read_text(episode_path)
        if metadata(episode_text, "schema_version") != input_schema:
            errors.append(f"{token} episode schema mismatch")
        if metadata(episode_text, "交接状态") != "READY":
            errors.append(f"{token} episode is not READY")
        if metadata(episode_text, "剧本SHA256") != row.get("剧本SHA256"):
            errors.append(f"{token} internal script hash mismatch")
        declared_script_path = resolve_relative(project_root, metadata(episode_text, "剧本路径"))
        if declared_script_path != script_path:
            errors.append(f"{token} internal script path mismatch")
        if not unresolved_is_empty(episode_text, "未解决项"):
            errors.append(f"{token} unresolved items are not empty")
        people = parse_table(episode_text, "人物出现")
        scenes = parse_table(episode_text, "场景出现")
        props = parse_table(episode_text, "道具出现")
        episode_no = episode_number(token)
        for item in people + scenes + props:
            entity_id = item.get("实体ID", "")
            if entity_id:
                referenced_ids.add(entity_id)
            for key, value in item.items():
                if PLACEHOLDER_RE.search(value):
                    errors.append(f"{token} placeholder: {entity_id} | {key}={value}")
            decision = item.get("资产化决策", "")
            asset = item.get("建议状态@", "")
            if decision not in ALLOWED_DECISIONS:
                errors.append(f"{token} invalid asset decision: {entity_id} | {decision}")
            elif decision == "建卡" and not asset.startswith("@"):
                errors.append(f"{token} card missing @: {entity_id}")
            elif decision != "建卡" and asset != "无":
                errors.append(f"{token} inline/non-asset row must use 建议状态@=无: {entity_id}")
        for item in people:
            dimension = item.get("状态维度", "")
            asset = item.get("建议状态@", "")
            if dimension not in ALLOWED_DIMENSIONS:
                errors.append(f"{token} invalid state dimension: {item.get('实体ID', '')} | {dimension}")
            if "_" in asset and dimension == "—":
                errors.append(f"{token} state asset lacks dimension: {item.get('实体ID', '')} | {asset}")
            if dimension != "—" and item.get("资产化决策") == "建卡" and "_" not in asset:
                errors.append(f"{token} state dimension lacks state asset name: {item.get('实体ID', '')} | {dimension}")
            if item.get("资产化决策") == "建卡" and "_" in asset and not valid_state_range_and_anchor(item.get("生效区间/切换锚", ""), episode_no):
                errors.append(f"{token} state asset lacks valid range/switch anchor: {item.get('实体ID', '')} | {asset}")
        for item, column, label in [(entry, "状态/切换锚", "scene") for entry in scenes] + [
            (entry, "状态变化/切换锚", "prop") for entry in props
        ]:
            asset = item.get("建议状态@", "")
            if item.get("资产化决策") == "建卡" and "_" in asset and not valid_switch_anchor(item.get(column, ""), episode_no):
                errors.append(f"{token} {label} state lacks valid switch anchor: {item.get('实体ID', '')} | {asset}")

        if script_text:
            for script_scene in script_inventory(script_text):
                scene_hits = [
                    item
                    for item in scenes
                    if item.get("场次") == script_scene["scene"] and item.get("场次头原名") == script_scene["location"]
                ]
                if len(scene_hits) != 1:
                    errors.append(f"{token} scene coverage must be exactly one: {script_scene['scene']} | {script_scene['location']}")
                for raw_person in script_scene["people"]:
                    normalized = normalize_person_label(raw_person)
                    person_hits = [
                        item
                        for item in people
                        if item.get("场次") == script_scene["scene"]
                        and normalize_person_label(item.get("源标签", "")) == normalized
                    ]
                    if len(person_hits) != 1:
                        errors.append(f"{token} person coverage must be exactly one: {script_scene['scene']} | {raw_person}")
        episode_payloads.append(
            {
                "episode": token,
                "script_path": str(script_path),
                "script_sha256": row.get("剧本SHA256"),
                "handoff_path": str(episode_path),
                "handoff_sha256": row.get("交接SHA256"),
                "people": people,
                "scenes": scenes,
                "props": props,
            }
        )

    source_groups = {
        "people_and_conditional": parse_table(source_text, "人物与条件类型") if source_text else [],
        "scenes": parse_table(source_text, "场景") if source_text else [],
        "props": parse_table(source_text, "道具") if source_text else [],
    }
    entity_by_id: dict[str, dict[str, str]] = {}
    entity_type_by_id: dict[str, str] = {}
    label_to_id: dict[str, str] = {}
    for group_name, rows in source_groups.items():
        for source_row in rows:
            entity_id = source_row.get("实体ID", "")
            if group_name == "people_and_conditional":
                entity_type = source_row.get("类型", "")
                canonical_name = source_row.get("剧本规范名", "")
                alias_column = "别名"
            elif group_name == "scenes":
                entity_type = "场景"
                canonical_name = source_row.get("场次头规范名", "")
                alias_column = "精确别名"
            else:
                entity_type = "道具"
                canonical_name = source_row.get("剧本正式名", "")
                alias_column = "别名"
            if entity_id in entity_by_id:
                errors.append(f"source facts duplicate entity ID: {entity_id}")
            else:
                entity_by_id[entity_id] = source_row
                entity_type_by_id[entity_id] = entity_type
            if entity_type not in ALLOWED_TYPES:
                errors.append(f"source facts invalid type: {entity_id} | {entity_type}")
            elif not re.fullmatch(rf"{TYPE_PREFIXES[entity_type]}-\d+", entity_id):
                errors.append(f"source facts invalid entity ID prefix: {entity_id} | {entity_type}")
            if group_name == "people_and_conditional" and entity_type in {"场景", "道具"}:
                errors.append(f"source facts entity is in wrong table: {entity_id} | {entity_type}")
            if not canonical_name or PLACEHOLDER_RE.search(canonical_name):
                errors.append(f"source facts invalid canonical name: {entity_id} | {canonical_name}")
            suggested_asset = source_row.get("建议@资产名", "")
            if not suggested_asset.startswith("@"):
                errors.append(f"source facts invalid suggested asset: {entity_id} | {suggested_asset}")
            tendency = source_row.get("资产化倾向", "")
            if tendency not in ALLOWED_TENDENCIES:
                errors.append(f"source facts invalid tendency: {entity_id} | {tendency}")
            for label in [canonical_name, *split_aliases(source_row.get(alias_column, ""))]:
                normalized_label = label.casefold()
                previous_id = label_to_id.get(normalized_label)
                if previous_id and previous_id != entity_id:
                    errors.append(f"source facts name/alias points to multiple entities: {label} | {previous_id} | {entity_id}")
                elif normalized_label:
                    label_to_id[normalized_label] = entity_id

    known_ids = set(entity_by_id)
    unknown_ids = sorted(referenced_ids - known_ids)
    if unknown_ids:
        errors.append("episode handoff references unknown entities: " + ",".join(unknown_ids))
    assets_by_id: dict[str, set[str]] = {}
    asset_episodes: dict[tuple[str, str], set[str]] = {}
    candidate_asset_to_ids: dict[str, set[str]] = {}
    for payload in episode_payloads:
        for item in [*payload["people"], *payload["scenes"], *payload["props"]]:
            if item.get("资产化决策") != "建卡" or not item.get("建议状态@", "").startswith("@"):
                continue
            entity_id = item.get("实体ID", "")
            asset_name = item["建议状态@"]
            assets_by_id.setdefault(entity_id, set()).add(asset_name)
            asset_episodes.setdefault((entity_id, asset_name), set()).add(str(payload["episode"]))
            candidate_asset_to_ids.setdefault(asset_name, set()).add(entity_id)
    for entity_id, assets in assets_by_id.items():
        if any("_" in asset for asset in assets) and any("_" not in asset for asset in assets):
            errors.append(
                "mixed base/state asset names require explicit baseline state: "
                f"{entity_id} | {'、'.join(sorted(assets))}"
            )
    for asset_name, entity_ids in candidate_asset_to_ids.items():
        if len(entity_ids) > 1:
            errors.append(
                f"candidate asset name points to multiple entities: {asset_name} | {'、'.join(sorted(entity_ids))}"
            )
    for payload in episode_payloads:
        token = str(payload["episode"])
        for item in payload["people"]:
            entity_id = item.get("实体ID", "")
            if entity_id in entity_type_by_id and entity_type_by_id[entity_id] in {"场景", "道具"}:
                errors.append(f"{token} person row maps to wrong entity type: {entity_id} | {entity_type_by_id[entity_id]}")
        for item in payload["scenes"]:
            entity_id = item.get("实体ID", "")
            if entity_id in entity_type_by_id and entity_type_by_id[entity_id] != "场景":
                errors.append(f"{token} scene row maps to wrong entity type: {entity_id} | {entity_type_by_id[entity_id]}")
        for item in payload["props"]:
            entity_id = item.get("实体ID", "")
            if entity_id in entity_type_by_id and entity_type_by_id[entity_id] != "道具":
                errors.append(f"{token} prop row maps to wrong entity type: {entity_id} | {entity_type_by_id[entity_id]}")

    required_source_fields = {
        "people_and_conditional": ["设定性别/年龄", "原文稳定外观", "特殊标志", "服装事实", "资产化倾向", "证据"],
        "scenes": ["物理空间身份", "世界层", "固定结构/陈设/视觉符号", "资产化倾向", "证据"],
        "props": ["尺寸/材质/形状/颜色", "文字/关键标记", "初始持有人/状态", "资产化倾向", "证据"],
    }
    for group_name, rows in source_groups.items():
        for source_row in rows:
            entity_id = source_row.get("实体ID", "")
            if entity_id not in referenced_ids:
                continue
            for field in required_source_fields[group_name]:
                value = source_row.get(field, "")
                if not value or PLACEHOLDER_RE.search(value):
                    errors.append(f"incomplete source fact: {entity_id} | {field}")
            if group_name == "people_and_conditional" and source_row.get("类型") != "群像":
                identity = source_row.get("设定性别/年龄", "")
                if re.search(r"原文未明示|需用户确认", identity):
                    errors.append(f"unresolved identity fact: {entity_id} | 设定性别/年龄={identity}")

    if errors:
        raise ValueError("\n".join(sorted(set(errors))))

    filtered_groups = {
        name: [row for row in rows if row.get("实体ID") in referenced_ids]
        for name, rows in source_groups.items()
    }
    by_type = {entity_type: 0 for entity_type in sorted(ALLOWED_TYPES)}
    for row in filtered_groups["people_and_conditional"]:
        by_type[row.get("类型", "")] = by_type.get(row.get("类型", ""), 0) + 1
    by_type["场景"] = len(filtered_groups["scenes"])
    by_type["道具"] = len(filtered_groups["props"])
    candidate_cards_by_type = {entity_type: 0 for entity_type in sorted(ALLOWED_TYPES)}
    for entity_id, assets in assets_by_id.items():
        entity_type = entity_type_by_id.get(entity_id, "")
        candidate_cards_by_type[entity_type] = candidate_cards_by_type.get(entity_type, 0) + len(assets)
    candidate_cards = []
    for entity_id, assets in sorted(assets_by_id.items()):
        source_row = entity_by_id[entity_id]
        entity_type = entity_type_by_id[entity_id]
        if entity_type == "场景":
            canonical_name = source_row.get("场次头规范名", "")
        elif entity_type == "道具":
            canonical_name = source_row.get("剧本正式名", "")
        else:
            canonical_name = source_row.get("剧本规范名", "")
        for asset_name in sorted(assets):
            candidate_cards.append(
                {
                    "asset_name": asset_name,
                    "entity_id": entity_id,
                    "entity_type": entity_type,
                    "canonical_name": canonical_name,
                    "episodes": sorted(
                        asset_episodes.get((entity_id, asset_name), set()),
                        key=episode_number,
                    ),
                }
            )
    fingerprint_payload = {
        "schema_version": input_schema,
        "source_skill": SUPPORTED_SCHEMAS.get(input_schema, "unknown"),
        "coverage": metadata(handoff_text, "覆盖范围"),
        "source_facts_sha256": metadata(handoff_text, "源事实SHA256"),
        "episodes": [
            {
                "episode": payload["episode"],
                "script_sha256": payload["script_sha256"],
                "handoff_sha256": payload["handoff_sha256"],
            }
            for payload in episode_payloads
        ],
        "candidate_cards": candidate_cards,
    }
    contract_fingerprint = hashlib.sha256(
        json.dumps(
            fingerprint_payload,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    return {
        "schema_version": input_schema,
        "source_skill": SUPPORTED_SCHEMAS.get(input_schema, "unknown"),
        "contract_fingerprint": contract_fingerprint,
        "handoff_path": str(handoff_path),
        "project_root": str(project_root),
        "coverage": metadata(handoff_text, "覆盖范围"),
        "source_facts_path": str(source_path),
        "source_facts_sha256": metadata(handoff_text, "源事实SHA256"),
        "source_facts": filtered_groups,
        "episodes": episode_payloads,
        "candidate_cards": candidate_cards,
        "counts": {
            "entities": len(referenced_ids),
            "people_and_conditional": len(filtered_groups["people_and_conditional"]),
            "scenes": len(filtered_groups["scenes"]),
            "props": len(filtered_groups["props"]),
            "episodes": len(episode_payloads),
            "by_type": by_type,
            "candidate_cards": sum(candidate_cards_by_type.values()),
            "candidate_cards_by_type": candidate_cards_by_type,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("handoff", type=Path, help="Path to visual-assets/handoff.md")
    parser.add_argument("--episodes", help="Optional episode or range N / N-M")
    parser.add_argument("--output", type=Path, help="Write normalized JSON to this path")
    args = parser.parse_args()
    try:
        requested = parse_episode_range(args.episodes)
        payload = import_handoff(args.handoff, requested)
        encoded = json.dumps(payload, ensure_ascii=False, indent=2)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(encoded + "\n", encoding="utf-8")
        counts = payload["counts"]
        print(
            "COMIC-HANDOFF-IMPORT-PASS: "
            f"episodes={counts['episodes']} entities={counts['entities']} "
            f"people_and_conditional={counts['people_and_conditional']} "
            f"roles={counts['by_type'].get('角色', 0)} groups={counts['by_type'].get('群像', 0)} "
            f"scenes={counts['scenes']} props={counts['props']} "
            f"candidate_cards={counts['candidate_cards']}"
        )
        if args.output:
            print(f"NORMALIZED-JSON: {args.output.resolve()}")
        return 0
    except Exception as exc:  # noqa: BLE001 - CLI should return one deterministic failure surface.
        print(f"COMIC-HANDOFF-IMPORT-FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
