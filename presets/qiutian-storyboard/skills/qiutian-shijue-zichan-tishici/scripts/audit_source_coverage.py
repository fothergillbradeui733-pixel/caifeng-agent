# -*- coding: utf-8 -*-
"""逐集对照剧本，审计视觉资产库的角色与场景覆盖。

用法：
  python audit_source_coverage.py <资产库.md> --project <项目目录> [--json]

退出码：0=无重复/前景资产覆盖缺口；1=存在必须修复的覆盖缺口。
一次性说话人或一次性场景仅 warning，允许由下游 inline，但须在交付报告解释。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

from validate_assets import (
    CJK,
    base_state,
    card_is_deprecated,
    find_section,
    parse_cards,
    parse_sections,
    read_text,
)


if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")


SCRIPT_RE = re.compile(r"^EP-(\d+)\.md$", re.I)
SCENE_RE = re.compile(
    r"^场次\s+[^：:]+[：:]\s*(?:内|外|内外|外内)\s+(.+?)\s{2,}(.+?)\s*$"
)
CAST_RE = re.compile(r"^出场人物[：:]\s*(.+)$")
STAGE_RE = re.compile(r"^（[^）]+）$")
ROLE_LIKE_RE = re.compile(
    r"(人|者|弟子|长老|仙修|修士|群像|百姓|侍从|侍女|属官|护卫|官员|"
    r"少女|少年|女孩|男孩|老人|父亲|母亲|掌柜|小二|师尊|师傅|首领|"
    r"公子|姑娘|阿婆|阿公|叔|姨|甲|乙|丙|丁)$"
)
IGNORED_CAST = {
    "众人", "所有人", "人群", "背景人群", "远景人群", "群演", "无",
}
INDIVIDUAL_LABEL_RE = re.compile(
    r"(?:甲|乙|丙|丁)$|(?:第?[一二三四五六七八九十\d]+长老)$"
)
GENERIC_PERSON_RE = re.compile(
    r"^(?:众人|人群|背景人群|百姓|城民|乡亲|乡邻|村民|守卫|仙修|修士|弟子|属官|护卫|"
    r"官员|侍从|侍女|军士|士兵|食客|茶客|客商|"
    r"(?:北燕|南庆|郝轩|王府|千黛楼|小城)(?:仙修|修士|弟子|属官|护卫|官员|侍从|侍女)|"
    r"[\u4e00-\u9fff]{2,8}(?:宗|门|府|山|城)(?:仙修|修士|弟子|属官|护卫|官员|侍从|侍女)|"
    r".*(?:群像|群声|众声|人群|虚影)|仙踪迷步)$"
)
AGE_PREFIX_RE = re.compile(r"^(幼年|童年|少年|老年|\d{1,2}岁)(.+)$")
DECISION_RESULTS = {"角色卡", "群像卡", "逐镜内联", "不资产化"}


@dataclass
class CoverageReport:
    library: str
    project: str
    fails: list[str] = field(default_factory=list)
    warns: list[str] = field(default_factory=list)
    info: list[str] = field(default_factory=list)
    mappings: list[dict[str, object]] = field(default_factory=list)

    def fail(self, code: str, message: str) -> None:
        self.fails.append(f"[{code}] {message}")

    def warn(self, code: str, message: str) -> None:
        self.warns.append(f"[{code}] {message}")


def strip_annotations(value: str) -> str:
    value = value.strip().strip("“”\"' ")
    value = re.sub(r"（[^）]*）", "", value)
    return re.sub(r"\s+", "", value).strip("；;、，,")


def split_aliases(value: str) -> set[str]:
    if not value or value == "无":
        return set()
    aliases: set[str] = set()
    for raw in re.split(r"[、；;，,/／]", value):
        cleaned = re.sub(r"（(?:仅台词|旧称|禁|EP-[^）]+)）", "", raw).strip()
        cleaned = strip_annotations(cleaned)
        if cleaned:
            aliases.add(cleaned)
    return aliases


def ep_label(path: Path) -> str:
    number = int(SCRIPT_RE.match(path.name).group(1))  # type: ignore[union-attr]
    return f"EP-{number:03d}"


def split_cast(value: str) -> list[str]:
    return [
        strip_annotations(item)
        for item in re.split(r"[；;、，,]", value)
        if strip_annotations(item)
    ]


def next_nonempty(lines: list[str], start: int) -> int | None:
    cursor = start
    while cursor < len(lines):
        if lines[cursor].strip():
            return cursor
        cursor += 1
    return None


def is_individual_label(value: str) -> bool:
    return bool(INDIVIDUAL_LABEL_RE.search(value))


def is_generic_person_label(value: str) -> bool:
    return bool(GENERIC_PERSON_RE.search(value)) and not is_individual_label(value)


def parse_decision_ledger(library_text: str) -> dict[str, tuple[str, str, str]]:
    section = find_section(parse_sections(library_text), "资产化决策台账")
    result: dict[str, tuple[str, str, str]] = {}
    if not section:
        return result
    for line in section.splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) < 4 or cells[0] in ("源标签", ":--", "---"):
            continue
        label = strip_annotations(cells[0])
        decision = cells[1]
        target = cells[2]
        reason = cells[3]
        if label:
            result[label] = (decision, target, reason)
    return result


def parse_project(project: Path) -> tuple[
    dict[str, set[str]], dict[str, set[str]], set[str],
    dict[str, list[tuple[str, str]]], set[str],
    dict[str, int], dict[str, set[str]],
]:
    scripts_dir = project if project.name.lower() == "scripts" else project / "scripts"
    if not scripts_dir.is_dir():
        raise FileNotFoundError(f"缺 scripts 目录：{scripts_dir}")

    cast_eps: dict[str, set[str]] = defaultdict(set)
    speaker_eps: dict[str, set[str]] = defaultdict(set)
    foreground: set[str] = set()
    scenes: dict[str, list[tuple[str, str]]] = defaultdict(list)
    source_labels: set[str] = set()
    dialogue_lines: dict[str, int] = defaultdict(int)
    person_scenes: dict[str, set[str]] = defaultdict(set)

    files = sorted(
        (path for path in scripts_dir.iterdir() if SCRIPT_RE.match(path.name)),
        key=lambda path: int(SCRIPT_RE.match(path.name).group(1)),  # type: ignore[union-attr]
    )
    for script in files:
        ep = ep_label(script)
        lines = read_text(script).replace("\r\n", "\n").split("\n")
        scene_cast: list[str] = []
        current_scene = ep
        for index, raw in enumerate(lines):
            line = raw.strip()
            scene_match = SCENE_RE.match(line)
            if scene_match:
                location, time_bucket = scene_match.groups()
                scenes[re.sub(r"\s+", "", location)].append((ep, time_bucket.strip()))
                scene_cast = []
                current_scene = f"{ep}:{line.split('：', 1)[0]}"
                continue

            cast_match = CAST_RE.match(line)
            if cast_match:
                scene_cast = split_cast(cast_match.group(1))
                for name in scene_cast:
                    if name not in IGNORED_CAST:
                        cast_eps[name].add(ep)
                        person_scenes[name].add(current_scene)
                        source_labels.add(name)
                continue

            if "群像分层锁" in line and "前景" in line:
                for name in scene_cast:
                    if name and name in line and not re.search(r"群像|群演|背景|后景", name):
                        foreground.add(name)

            speaker = strip_annotations(line)
            if (
                not speaker or len(speaker) > 24 or
                re.search(r"[：:△※#【】]", line) or
                line.startswith(("场次", "出场人物"))
            ):
                continue
            stage_index = next_nonempty(lines, index + 1)
            if stage_index is None or not STAGE_RE.match(lines[stage_index].strip()):
                continue
            text_index = next_nonempty(lines, stage_index + 1)
            if text_index is None:
                continue
            dialogue = lines[text_index].strip()
            if not dialogue or dialogue.startswith(("场次", "出场人物：", "△", "※", "【")):
                continue
            speaker_names = split_cast(speaker) if re.search(r"[、，,；;]", speaker) else [speaker]
            for speaker_name in speaker_names:
                if not speaker_name or speaker_name in IGNORED_CAST:
                    continue
                speaker_eps[speaker_name].add(ep)
                dialogue_lines[speaker_name] += 1
                person_scenes[speaker_name].add(current_scene)
                source_labels.add(speaker_name)

    return (
        cast_eps,
        speaker_eps,
        foreground,
        scenes,
        source_labels,
        dialogue_lines,
        person_scenes,
    )


def parse_asset_tokens(library_text: str) -> tuple[
    list,
    dict[str, set[str]],
    dict[str, set[str]],
    dict[str, set[str]],
    dict[str, set[str]],
    dict[str, set[str]],
]:
    cards, _ = parse_cards(library_text)
    role_tokens: dict[str, set[str]] = defaultdict(set)
    group_tokens: dict[str, set[str]] = defaultdict(set)
    scene_to_families: dict[str, set[str]] = defaultdict(set)
    scene_family_states: dict[str, set[str]] = defaultdict(set)
    role_family_states: dict[str, set[str]] = defaultdict(set)

    for card in cards:
        if card_is_deprecated(card):
            continue
        base, state = base_state(card.name)
        aliases = split_aliases(card.meta.get("别名", ""))
        if card.type in ("角色", "生物", "不可见声音角色"):
            family = strip_annotations(base)
            role_family_states[family].add(state or "基础")
            for token in {family, *aliases}:
                role_tokens[token].add(card.name)
        elif card.type == "群像":
            for token in {strip_annotations(base), *aliases}:
                group_tokens[token].add(card.name)
        elif card.type == "场景":
            family = strip_annotations(base)
            scene_family_states[family].add(state or "基础")
            for token in {family, *aliases}:
                scene_to_families[token].add(family)
    return (
        cards,
        role_tokens,
        group_tokens,
        scene_to_families,
        scene_family_states,
        role_family_states,
    )


def parse_character_table_aliases(project: Path, source_labels: set[str]) -> list[tuple[str, str]]:
    path = project / "character-cards.md"
    if not path.is_file():
        return []
    pairs: list[tuple[str, str]] = []
    for line in read_text(path).splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if not cells or cells[0] in ("角色", ":--", "---"):
            continue
        match = re.match(r"^([^（]+)（([^）]+)）$", cells[0])
        if match:
            base, inner = (strip_annotations(item) for item in match.groups())
            if inner in source_labels:
                pairs.append((base, inner))
        if len(cells) > 4 and cells[4] not in ("", "无", "—"):
            base = strip_annotations(re.sub(r"（.*$", "", cells[0]))
            for alias in split_aliases(cells[4]):
                if alias in source_labels:
                    pairs.append((base, alias))
    return pairs


def audit(library: Path, project: Path) -> CoverageReport:
    report = CoverageReport(str(library), str(project))
    library_text = read_text(library)
    (
        cards,
        role_tokens,
        group_tokens,
        scene_map,
        scene_states,
        role_states,
    ) = parse_asset_tokens(library_text)
    (
        cast_eps,
        speaker_eps,
        foreground,
        scenes,
        source_labels,
        dialogue_lines,
        person_scenes,
    ) = parse_project(project)
    decisions = parse_decision_ledger(library_text)
    handoff_locked_scene_families = {
        base_state(card.name)[0]
        for card in cards
        if card.type == "场景"
        and "全局实体索引建议状态强制闭环" in card.meta.get("说明", "")
    }

    all_people = sorted(set(cast_eps) | set(speaker_eps))
    missing_people: list[str] = []
    for name in all_people:
        normalized = strip_annotations(name)
        if not normalized or normalized in IGNORED_CAST:
            continue
        role_matches = sorted(role_tokens.get(normalized, set()))
        group_matches = sorted(group_tokens.get(normalized, set()))
        cast_count = len(cast_eps.get(name, set()))
        speech_count = len(speaker_eps.get(name, set()))
        line_count = dialogue_lines.get(name, 0)
        scene_count = len(person_scenes.get(name, set()))
        foreground_locked = name in foreground
        mapping_type = (
            "角色/生物/声音角色" if role_matches
            else ("群像" if group_matches else "未映射")
        )
        mapping_targets = role_matches or group_matches
        mapping_record: dict[str, object] = {
            "source_label": name,
            "mapped_cards": [f"@{item}" for item in mapping_targets],
            "card_type": mapping_type,
            "cast_episodes": cast_count,
            "speech_episodes": speech_count,
            "dialogue_lines": line_count,
            "scenes": scene_count,
            "foreground_locked": foreground_locked,
        }
        report.mappings.append(mapping_record)

        if role_matches and group_matches:
            representative_roles = [item for item in role_matches if item.endswith("代表")]
            if representative_roles:
                mapping_record["mapped_cards"] = [f"@{item}" for item in representative_roles]
                mapping_record["card_type"] = "固定发言代表（群像另承载背景）"
                continue
            else:
                report.fail(
                    "COV6",
                    f"人物「{name}」同时映射角色与群像："
                    + "、".join(f"@{item}" for item in role_matches + group_matches),
                )
                continue

        if role_matches:
            continue

        if group_matches:
            group_conflict = (
                foreground_locked
                or (line_count > 0 and is_individual_label(normalized))
                or (
                    speech_count >= 2
                    and line_count > 0
                    and not is_generic_person_label(normalized)
                )
            )
            if group_conflict:
                report.fail(
                    "COV6",
                    f"独立人物「{name}」仅映射到无具名群像 "
                    f"{'、'.join('@' + item for item in group_matches)}"
                    f"（出场{cast_count}集，对白{speech_count}集/{line_count}句，"
                    f"场次{scene_count}，前景锁={foreground_locked}）",
                )
                missing_people.append(name)
            continue

        age_match = AGE_PREFIX_RE.match(normalized)
        if age_match:
            age_state, base_name = age_match.groups()
            if base_name in role_tokens:
                family_states = role_states.get(base_name, set())
                expected = {age_state, "幼年" if age_state in ("童年",) or age_state.endswith("岁") else age_state}
                if not family_states.intersection(expected):
                    report.fail(
                        "COV8",
                        f"年龄变体「{name}」命中基础角色 @{base_name}，"
                        f"但缺独立年龄状态卡（现有状态：{'、'.join(sorted(family_states)) or '无'}）",
                    )
                    missing_people.append(name)
                    continue
                age_cards = [
                    card_name
                    for card_name in role_tokens.get(base_name, set())
                    if base_state(card_name)[1] in expected
                ]
                mapping_record["mapped_cards"] = [f"@{item}" for item in sorted(age_cards)]
                mapping_record["card_type"] = "角色年龄状态"
                continue

        repeated = cast_count >= 2 or speech_count >= 2
        role_like = bool(ROLE_LIKE_RE.search(normalized))
        decision = decisions.get(normalized)
        if (
            decision
            and decision[0] in ("逐镜内联", "不资产化")
            and decision[2]
            and decision[2] not in ("无", "—", "-")
        ):
            mapping_record["card_type"] = decision[0]
            mapping_record["decision"] = decision[0]
            mapping_record["target"] = decision[1]
            mapping_record["reason"] = decision[2]
            mapping_record["mapped_cards"] = [
                f"@{item}" for item in re.findall(rf"@([\w{CJK}·]+)", decision[1])
            ]
            continue
        if repeated and (speech_count or foreground_locked or role_like):
            report.fail(
                "COV1",
                f"重复/前景人物「{name}」未映射到角色、生物、声音角色或群像别名"
                f"（出场{cast_count}集，对白{speech_count}集，前景锁={foreground_locked}）",
            )
            missing_people.append(name)
        elif (
            speech_count == 1
            and (line_count >= 4 or (scene_count >= 2 and line_count >= 2))
        ):
            if decision and decision[0] in DECISION_RESULTS:
                if decision[0] in ("角色卡", "群像卡"):
                    report.fail(
                        "COV7",
                        f"高强度单集人物「{name}」台账决定为「{decision[0]}」"
                        "，但当前没有对应资产映射",
                    )
                elif not decision[2] or decision[2] in ("无", "—", "-"):
                    report.fail(
                        "COV7",
                        f"高强度单集人物「{name}」决定逐镜内联/不资产化，但台账缺判断依据",
                    )
                else:
                    mapping_record["card_type"] = decision[0]
                    mapping_record["decision"] = decision[0]
                    mapping_record["target"] = decision[1]
                    mapping_record["reason"] = decision[2]
                    mapping_record["mapped_cards"] = [
                        f"@{item}" for item in re.findall(rf"@([\w{CJK}·]+)", decision[1])
                    ]
            else:
                report.fail(
                    "COV7",
                    f"高强度单集人物「{name}」未资产化且未登记决策"
                    f"（对白{line_count}句，跨{scene_count}场）；"
                    "补角色卡，或在「资产化决策台账」登记逐镜内联/不资产化及依据",
                )
                missing_people.append(name)
        elif speech_count:
            report.warn(
                "COV1",
                f"一次性说话人「{name}」无资产映射"
                f"（对白{line_count}句，场次{scene_count}）；"
                "确认由下游 inline，或补角色/群像别名",
            )

    for base, alias in parse_character_table_aliases(project, source_labels):
        if base in role_tokens and alias not in role_tokens:
            report.fail("COV2", f"角色「{base}」漏收剧本称呼/旧称「{alias}」到别名")

    missing_scenes: list[str] = []
    mapped_times: dict[str, list[str]] = defaultdict(list)
    for location, occurrences in sorted(scenes.items()):
        families = scene_map.get(location, set())
        if not families:
            episodes = sorted({ep for ep, _ in occurrences})
            message = (
                f"场次头地点「{location}」未映射到场景资产名或别名"
                f"（{len(occurrences)}场，{len(episodes)}集：{'、'.join(episodes)}）"
            )
            if len(occurrences) >= 2 or len(episodes) >= 2:
                report.fail("COV3", message)
                missing_scenes.append(location)
            else:
                report.warn("COV3", message + "；确认由下游 inline 或补别名")
            continue
        if len(families) > 1:
            report.fail(
                "COV4",
                f"场次头地点「{location}」同时映射多个场景资产："
                + "、".join(f"@{family}" for family in sorted(families)),
            )
        for family in families:
            mapped_times[family].extend(time for _, time in occurrences)

    for family, times in mapped_times.items():
        day = any(re.search(r"日|晨|午|黄昏|白天", value) for value in times)
        night = any(re.search(r"夜|深夜", value) for value in times)
        states = scene_states.get(family, set())
        if (
            day and night
            and not {"日", "夜"}.issubset(states)
            and family not in handoff_locked_scene_families
        ):
            report.fail(
                "COV5",
                f"@{family} 的剧本证据同时含日/夜，但资产未成对拆分 `_日`/`_夜`",
            )
        if {"日", "夜"}.issubset(states) and not (day and night):
            report.warn(
                "COV5",
                f"@{family}_日/夜 已拆对，但当前已映射剧本证据未同时覆盖日夜；检查别名漏收或过度拆分",
            )

    scripts_path = project if project.name.lower() == "scripts" else project / "scripts"
    report.info.append(
        f"脚本{len(list(scripts_path.glob('EP-*.md')))}集 "
        f"源人物标签{len(all_people)} 场次头地点{len(scenes)} "
        f"人物语义缺口{len(set(missing_people))} 重复场景缺口{len(missing_scenes)}"
    )
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="逐集审计视觉资产库对剧本说话人、前景人物和场次头地点的覆盖。")
    parser.add_argument("library", help="视觉资产库 Markdown")
    parser.add_argument("--project", required=True, help="项目根目录，或直接传 scripts/ 目录")
    parser.add_argument("--json", action="store_true", help="只输出纯 JSON")
    args = parser.parse_args()

    try:
        report = audit(Path(args.library), Path(args.project))
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"FAIL [COV0] 无法完成源覆盖审计：{exc}")
        return 1

    if args.json:
        print(json.dumps({
            "file": report.library,
            "project": report.project,
            "fails": report.fails,
            "warns": report.warns,
            "info": report.info,
            "mappings": report.mappings,
        }, ensure_ascii=False, indent=2))
    else:
        status = "FAIL" if report.fails else ("WARN" if report.warns else "PASS")
        print(f"=== {Path(report.library).name} 源覆盖审计：{status}  {'; '.join(report.info)}")
        for item in report.fails:
            print(f"  FAIL {item}")
        for item in report.warns:
            print(f"  warn {item}")
    return 1 if report.fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
