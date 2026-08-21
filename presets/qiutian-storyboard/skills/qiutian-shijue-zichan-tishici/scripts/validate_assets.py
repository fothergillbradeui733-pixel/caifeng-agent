# -*- coding: utf-8 -*-
"""qiutian-shijue-zichan-tishici 资产库机检（Codex 版）。

用法：
  python validate_assets.py <资产库.md> [更多库或目录] [--prev 旧库.md]
         [--index 索引.md] [--json]

退出码：0=无 FAIL（允许 warning）；1=存在 FAIL。
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

CJK = r"一-鿿"
TYPES = ("角色", "场景", "道具", "群像", "生物", "不可见声音角色", "3D Q版小人")
SHARP_WORDS = (
    "精细", "复杂", "繁复", "浓郁", "HDR", "8K", "超高清", "高细节",
    "锐利", "ultra sharp", "hyper-detailed", "intricate",
)
REAL_WORDS = ("毛孔", "红血丝", "皮肤纹理", "青春痘", "胶片颗粒", "photoreal", "真人实拍")
POLLUTION = ("雨夜", "霓虹", "街景", "街灯", "老城区", "港片")
DAY_INCOMPATIBLE = ("夜色", "夜幕", "深夜", "月夜", "月光", "红月", "星空", "星夜")
NIGHT_INCOMPATIBLE = ("烈日", "正午", "晨光", "朝阳", "夕阳", "日照", "白昼")
VISIBLE_META = ("设定性别", "外观呈现", "呈现性质", "颜值定位", "特殊标志")
GENDERS = ("男", "女", "非二元", "无性别", "剧情刻意未明示")
APPEARANCES = ("男性", "女性", "中性")
PRESENTATION_NATURES = ("本貌", "日常穿着", "身份伪装", "舞台扮装")
GENDER_PROMPT_TOKENS = {
    "男": ("男性角色", "男性人物", "成年男性", "青年男性", "少年男性", "男童角色", "男孩角色"),
    "女": ("女性角色", "女性人物", "成年女性", "青年女性", "少女角色", "女童角色", "女孩角色"),
    "非二元": ("非二元",),
    "无性别": ("无性别",),
    "剧情刻意未明示": ("性别身份保留悬念", "性别设定保留悬念", "剧情保留性别悬念"),
}
APPEARANCE_PROMPT_TOKENS = {
    "男性": ("男性外观", "男性身份", "男性呈现", "少年男性", "青年男性", "成年男性"),
    "女性": ("女性外观", "女性身份", "女性呈现", "女性化外观", "年轻女性", "成年女性"),
    "中性": ("中性外观", "中性呈现", "中性人物", "中性气质"),
}
NATURE_PROMPT_TOKENS = {
    "本貌": ("本貌",),
    "日常穿着": ("日常穿着", "日常造型"),
    "身份伪装": ("身份伪装", "伪装", "女扮男装", "男扮女装"),
    "舞台扮装": ("舞台扮装", "舞台反串", "舞台造型"),
}
FACE_DETAIL_GROUPS = (
    ("脸型", "骨相", "面部轮廓", "颧", "下颌", "眉骨"),
    ("眉", "眼", "瞳"),
    ("鼻",),
    ("唇", "嘴角"),
    ("比例", "留白", "中庭", "三庭", "五眼", "肤质", "皮肤", "成年感", "少年感", "生活痕迹"),
)
FACE_IDENTITY_TOKENS = (
    "脸型", "骨相", "面部轮廓", "下颌", "眉骨", "眉形", "眉眼", "眼形",
    "眼尾", "眼裂", "瞳色", "异瞳", "鼻梁", "鼻根", "鼻尖", "鼻头",
    "唇形", "唇峰", "嘴角", "五官比例", "中庭", "三庭", "五眼", "年龄感",
)
FACE_AESTHETIC_TOKENS = (
    "清冷", "明艳", "温润", "端方", "英气", "俊朗", "耐看", "亲和",
    "凌厉", "妩媚", "沉静", "粗粝", "朴素", "惊艳", "少年感", "成熟",
    "雌雄莫辨", "角色脸", "国漫女主", "国漫男主",
)
SPECIAL_NONE = ("无", "无特殊标志", "无明确特殊标志")
CLOTHING_UNCERTAIN = (
    "长裤或", "裙装或", "或半身裙", "或长裤", "或裙装", "任选",
    "可搭配", "二选一", "随机搭配", "按场合佩戴",
)
CLOTHING_DIRECTION_GROUPS = (
    ("身份", "职业", "场合", "时代", "阶层", "宗门", "学生", "设计师", "主理人", "宴会", "日常", "行动", "伪装"),
    ("性格", "气质", "克制", "锋芒", "温柔", "外柔内韧", "沉稳", "张扬", "独立", "主见", "叛逆", "亲和", "压迫"),
    ("轮廓", "肩线", "纵向", "修长", "利落", "飘逸", "宽松", "收束", "流畅"),
    ("色彩", "配色", "主色", "辅色", "低饱和", "冷色", "暖色", "撞色", "同色"),
    ("材质", "面料", "垂顺", "挺括", "轻薄", "厚重", "皮革", "织物", "丝"),
    ("结构", "剪裁", "切线", "层叠", "不对称", "暗纹", "装饰", "纹样"),
)
UNFINISHED = ("提示词回填：初建未开始", "提示词回填:初建未开始", "待回填", "TODO", "TBD", "占位提示词")
VOICE_RE = re.compile(rf"^([\w{CJK}·]{{1,24}})音色\s*=\s*（(.+)）\s*$")
VOICE_LOOSE_RE = re.compile(rf"^[\w{CJK}·]{{1,24}}音色\s*=")
CARD_RE = re.compile(rf"^###\s*@([\w{CJK}·]+)\s*$")
RENAME_RE = re.compile(rf"改名\s*[:：]?\s*@?([\w{CJK}·]+)\s*(?:→|->)\s*@?([\w{CJK}·]+)")
DEPRECATE_RE = re.compile(rf"废弃\s*[:：]?\s*@?([\w{CJK}·]+)")
ACTIVE_STATUSES = ("有效", "已废弃")
NONVISUAL_STATE_WORDS = ("历史重复", "兼容", "废弃", "旧版", "修订", "占位")
INDIVIDUAL_ALIAS_RE = re.compile(
    r"(?:甲|乙|丙|丁)$|(?:第?[一二三四五六七八九十\d]+长老)$"
)
GROUP_COUNT_RE = re.compile(
    r"(?:(?:3\s*[-–—至到]\s*6|三\s*至\s*六)|[3-6三四五六])\s*名"
)
GROUP_FACE_PROMPT_TOKENS = (
    "每个人都有完整、清晰", "每个人都有完整清晰", "每人都有完整、清晰",
    "每人都有完整清晰", "每张脸清晰可见", "所有人物面部清晰",
    "逐一具有完整、清晰", "逐一具备完整、清晰",
)
FACE_EXCEPTION_TOKENS = (
    "蒙面", "面具", "遮脸", "遮面", "面容遮挡", "面部遮挡", "无脸", "无面",
)
FACE_EXCEPTION_EVIDENCE = ("原著明确", "原文明确", "剧本证据", "剧本明确")


def compact(value: str) -> str:
    return re.sub(r"\s", "", value)


def cjk_len(value: str) -> int:
    return len(re.findall(rf"[{CJK}]", value))


def has_any(value: str, candidates: tuple[str, ...]) -> bool:
    return any(candidate in value for candidate in candidates)


def has_original_face_exception(card: "Card", prompt: str) -> bool:
    explanation = card.meta.get("说明", "")
    return has_any(prompt, FACE_EXCEPTION_TOKENS) and has_any(
        explanation, FACE_EXCEPTION_EVIDENCE
    )


def split_alias_values(value: str) -> list[str]:
    if not value or value == "无":
        return []
    return [
        re.sub(r"（[^）]*）", "", item).strip()
        for item in re.split(r"[、；;，,/／]", value)
        if re.sub(r"（[^）]*）", "", item).strip()
    ]


def card_is_deprecated(card: "Card") -> bool:
    return (
        card.meta.get("使用状态") == "已废弃"
        or "已废弃" in card.meta.get("说明", "")
    )


def base_state(name: str) -> tuple[str, str | None]:
    if "_" in name:
        return tuple(name.split("_", 1))  # type: ignore[return-value]
    return name, None


def read_text(path: str | Path) -> str:
    return Path(path).read_text(encoding="utf-8-sig", errors="strict")


@dataclass
class Card:
    name: str
    line_no: int
    end_line: int = 0
    type: str = ""
    meta: dict[str, str] = field(default_factory=dict)
    prompt_markers: int = 0
    prompts: list[str] = field(default_factory=list)
    voices: list[str] = field(default_factory=list)
    bad_voices: list[str] = field(default_factory=list)


@dataclass
class Report:
    path: str
    fails: list[str] = field(default_factory=list)
    warns: list[str] = field(default_factory=list)
    info: list[str] = field(default_factory=list)

    def fail(self, code: str, message: str) -> None:
        self.fails.append(f"[{code}] {message}")

    def warn(self, code: str, message: str) -> None:
        self.warns.append(f"[{code}] {message}")


def parse_sections(text: str) -> dict[str, str]:
    matches = list(re.finditer(r"(?m)^##\s+([^\r\n]+?)\s*$", text))
    sections: dict[str, str] = {}
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        sections[match.group(1).strip()] = text[match.start():end].rstrip()
    return sections


def find_section(sections: dict[str, str], wanted: str) -> str | None:
    if wanted in sections:
        return sections[wanted]
    for title, body in sections.items():
        if wanted in title:
            return body
    return None


def parse_cards(text: str) -> tuple[list[Card], list[str]]:
    lines = text.splitlines()
    starts: list[tuple[int, str]] = []
    for index, line in enumerate(lines):
        match = CARD_RE.match(line.strip())
        if match:
            starts.append((index, match.group(1).rstrip("。，,.")))

    cards: list[Card] = []
    for position, (start, name) in enumerate(starts):
        end = starts[position + 1][0] if position + 1 < len(starts) else len(lines)
        for section_line in range(start + 1, end):
            if re.match(r"^##(?:[^#]|$)", lines[section_line].strip()):
                end = section_line
                break
        card = Card(name=name, line_no=start + 1, end_line=end)
        block = lines[start + 1:end]
        prompt_buffers: list[list[str]] = []
        active_prompt: list[str] | None = None
        for raw in block:
            stripped = raw.strip()
            field_match = re.match(
                r"^(类型|使用状态|替代资产|设定性别|外观呈现|呈现性质|颜值定位|特殊标志|别名|出现集|说明)\s*[:：]\s*(.*)$",
                stripped,
            )
            if field_match:
                key, value = field_match.groups()
                if key == "类型":
                    card.type = value.strip()
                else:
                    card.meta[key] = value.strip()
            if re.match(r"^文生图提示词\s*[:：]", stripped):
                card.prompt_markers += 1
                active_prompt = []
                prompt_buffers.append(active_prompt)
                continue
            if active_prompt is not None:
                if stripped.startswith("音色行") or VOICE_RE.match(stripped) or VOICE_LOOSE_RE.match(stripped):
                    active_prompt = None
                elif not stripped.startswith("```"):
                    active_prompt.append(raw)
            if VOICE_RE.match(stripped):
                card.voices.append(compact(stripped))
            elif VOICE_LOOSE_RE.match(stripped):
                card.bad_voices.append(stripped)
        card.prompts = ["\n".join(buffer).strip() for buffer in prompt_buffers if "\n".join(buffer).strip()]
        cards.append(card)
    return cards, lines


def validate_voice(report: Report, card: Card, voice: str) -> None:
    match = VOICE_RE.match(voice)
    if not match:
        report.fail("V3", f"@{card.name} 音色行内容为空或不完整")
        return
    voice_name, inner = match.groups()
    if inner.startswith("（"):
        report.fail("V3", f"@{card.name} 音色行多包一层括号")
    if "嗓音演绎" not in inner or "音色" not in inner or "音调" not in inner:
        report.fail("V3", f"@{card.name} 音色行缺四槽字段")
    if not inner.endswith("。"):
        report.fail("V3", f"@{card.name} 音色行句号须在括号内收尾")
    base, state = base_state(card.name)
    accepted = {card.name, base, card.name.replace("_", "")}
    accepted.update(split_alias_values(card.meta.get("别名", "")))
    if card.type == "群像":
        accepted.update({card.name + "群声", base + "群声"})
    if voice_name not in accepted:
        report.warn("V3", f"@{card.name} 音色主名「{voice_name}」与卡名/基础名/变体名不一致")


def validate_visual_identity(report: Report, card: Card, prompt: str) -> None:
    tag = f"@{card.name}"
    for key in VISIBLE_META:
        if not card.meta.get(key):
            report.fail("V15", f"{tag} 缺角色视觉身份字段「{key}」")
    if any(not card.meta.get(key) for key in VISIBLE_META):
        return

    gender = card.meta["设定性别"]
    appearance = card.meta["外观呈现"]
    nature = card.meta["呈现性质"]
    beauty = card.meta["颜值定位"]
    special = card.meta["特殊标志"]

    if gender not in GENDERS:
        report.fail("V15", f"{tag} 设定性别「{gender}」不合法")
    elif not has_any(prompt, GENDER_PROMPT_TOKENS[gender]):
        report.fail("V15", f"{tag} 文生图正文未明确转写设定性别「{gender}」")

    if appearance == "刻意模糊":
        report.fail(
            "V15",
            f"{tag} 外观呈现旧值「刻意模糊」须迁移为「中性」，"
            "并以呈现性质与说明保存剧情证据",
        )
    elif appearance not in APPEARANCES:
        report.fail("V15", f"{tag} 外观呈现「{appearance}」不合法")
    elif not has_any(prompt, APPEARANCE_PROMPT_TOKENS[appearance]):
        report.fail("V15", f"{tag} 文生图正文未明确转写外观呈现「{appearance}」")

    if nature not in PRESENTATION_NATURES:
        report.fail("V15", f"{tag} 呈现性质「{nature}」不合法")
    elif not has_any(prompt, NATURE_PROMPT_TOKENS[nature]):
        report.fail("V15", f"{tag} 文生图正文未明确转写呈现性质「{nature}」")

    if not beauty or beauty in ("无", "待定", "未明示"):
        report.fail("V16", f"{tag} 颜值定位为空泛；须给出明确审美层级与气质")
    elif beauty not in prompt:
        report.fail("V16", f"{tag} 文生图正文未逐字包含颜值定位「{beauty}」")

    if not special:
        report.fail("V16", f"{tag} 特殊标志为空；无内容须写「无」")
    elif special not in SPECIAL_NONE:
        markers = [
            re.sub(r"[（(][^）)]*[）)]", "", item).strip()
            for item in re.split(r"[、，,；;]", special)
        ]
        missing = [marker for marker in markers if marker and marker not in prompt]
        if missing:
            report.fail("V16", f"{tag} 特殊标志未逐项进入文生图正文：{'、'.join(missing)}")

    if gender == "剧情刻意未明示":
        if appearance != "中性":
            report.fail("V15", f"{tag} 剧情刻意未明示时外观呈现须为「中性」")
        if not re.search(r"刻意|隐瞒|未明示|不揭示|悬念", card.meta.get("说明", "")):
            report.fail("V15", f"{tag} 使用「剧情刻意未明示」但说明缺剧情证据")

    if card.type == "角色":
        face_exception = has_original_face_exception(card, prompt)
        if not face_exception and not has_any(prompt, FACE_IDENTITY_TOKENS):
            report.fail("V16", f"{tag} 缺至少一个可执行脸部识别锚点；不能只写颜值结论或通用肤质")
        if not face_exception and not has_any(prompt, FACE_AESTHETIC_TOKENS):
            report.warn("V16", f"{tag} 未检测到协调的脸部审美簇；建议先写整体气质，再写 1–2 个识别锚点")
        face_hits = sum(1 for group in FACE_DETAIL_GROUPS if has_any(prompt, group))
        if not face_exception and face_hits >= 4:
            report.warn("V16", f"{tag} 同时覆盖 {face_hits}/5 类脸部微结构，可能过度描写；保留有识别作用的 1–2 个锚点和原文特殊标志")
        if (
            not face_exception
            and ("主演" in beauty or "主角" in card.meta.get("说明", ""))
            and not ("40%" in prompt or "第一视觉重点" in prompt)
        ):
            report.warn("V16", f"{tag} 主演级角色未声明头部特写约 40%/面部第一视觉重点")

        clothing_match = re.search(r"服装设计方向\s*[:：]\s*(.+?)(?:。|\n|$)", prompt, re.S)
        if not clothing_match:
            report.warn("V18", f"{tag} 缺 `服装设计方向：`；服装须外化身份场合、性格与内在张力")
        else:
            clothing = clothing_match.group(1)
            uncertain = [word for word in CLOTHING_UNCERTAIN if word in clothing]
            if uncertain:
                report.fail("V18", f"{tag} 服装方向含不确定选项：{'、'.join(uncertain)}")
            direction_hits = sum(
                1 for group in CLOTHING_DIRECTION_GROUPS if has_any(clothing, group)
            )
            if direction_hits < 3:
                report.warn("V18", f"{tag} 服装方向仅覆盖 {direction_hits}/6 类设计信息；至少写身份/性格与 2 个视觉维度")
        if not ("同一套" in prompt and ("保持一致" in prompt or "相同饰品" in prompt)):
            report.warn("V18", f"{tag} 未明确头部特写与三视图保持同一套服装和相同饰品")


def parse_list(section: str | None) -> tuple[dict[str, str], int]:
    result: dict[str, str] = {}
    untyped = 0
    if not section:
        return result, untyped
    for line in section.splitlines()[1:]:
        match = re.match(rf"^@([\w{CJK}·]+)(?:\s*[（(]([^）)]+)[）)])?", line.strip())
        if not match:
            continue
        name = match.group(1).rstrip("。，,.")
        asset_type = (match.group(2) or "").strip()
        result[name] = asset_type
        if not asset_type:
            untyped += 1
    return result, untyped


def parse_timeline(section: str | None) -> dict[str, tuple[str, str, str]]:
    result: dict[str, tuple[str, str, str]] = {}
    if not section:
        return result
    for line in section.splitlines():
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        cells = [cell.strip() for cell in stripped.strip("|").split("|")]
        if len(cells) >= 4 and cells[0].startswith("@"):
            name = cells[0].lstrip("@").rstrip("。，,.")
            result[name] = (cells[1], cells[2], cells[3])
    return result


def normalized_section(section: str | None) -> str:
    if section is None:
        return ""
    return section.replace("\r\n", "\n").strip()


def validate(path: str, prev_path: str = "", index_path: str = "") -> Report:
    report = Report(path)
    try:
        text = read_text(path)
    except (OSError, UnicodeError) as exc:
        report.fail("F0", f"无法读取 UTF-8 文件：{exc}")
        return report

    cards, _ = parse_cards(text)
    sections = parse_sections(text)
    for marker in UNFINISHED:
        if marker.lower() in text.lower():
            report.fail("V17", f"成品残留未完成标记「{marker}」")
    style_match = re.search(r"(?m)^视觉风格\s*[:：]\s*(.+?)\s*$", text)
    style = style_match.group(1).strip() if style_match else ""
    if not style:
        report.fail("V1", "缺 `视觉风格：` 行")
    elif "下游" not in style:
        report.fail("V1", "视觉风格行缺下游管线括注")
    is_real = any(word in style for word in ("写实", "真人", "现实主义", "胶片"))

    if not cards:
        report.fail("V2", "未解析到 `### @资产名` 卡")
        return report

    by_name: dict[str, Card] = {}
    states_by_base: dict[str, list[Card]] = {}
    for card in cards:
        if card.name in by_name:
            report.fail("V5", f"资产名重复：@{card.name}")
        by_name[card.name] = card
        base, state = base_state(card.name)
        if state is not None:
            states_by_base.setdefault(base, []).append(card)

    for base, state_cards in states_by_base.items():
        if base in by_name:
            report.fail("V5", f"@{base} 总卡与状态卡并存；多状态资产不设总卡")
        state_types = {card.type for card in state_cards if card.type}
        if len(state_types) > 1:
            report.fail("V2", f"@{base} 各状态卡类型不一致")

    all_card_voices: set[str] = set()
    for card in cards:
        tag = f"@{card.name}"
        base, state = base_state(card.name)
        deprecated_card = card_is_deprecated(card)
        if not card.type:
            report.fail("V2", f"{tag} 缺类型行")
        elif card.type not in TYPES:
            report.fail("V2", f"{tag} 类型「{card.type}」不在七类资产中")
        status = card.meta.get("使用状态", "")
        replacement = card.meta.get("替代资产", "")
        if not status:
            report.fail("V20", f"{tag} 缺 `使用状态：有效/已废弃`")
        elif status not in ACTIVE_STATUSES:
            report.fail("V20", f"{tag} 使用状态「{status}」不合法")
        if not replacement:
            report.fail("V20", f"{tag} 缺 `替代资产：无/@有效项/逐镜内联`")
        if deprecated_card:
            if status != "已废弃":
                report.fail("V20", f"{tag} 说明已标废弃，但缺 `使用状态：已废弃`")
            if not replacement or replacement == "无":
                report.fail("V20", f"{tag} 已废弃但缺有效 `替代资产：@.../逐镜内联`")
        elif status == "有效" and replacement and replacement != "无":
            report.warn("V20", f"{tag} 为有效资产却登记替代资产；通常应写「无」")
        for key in ("别名", "出现集", "说明"):
            if not card.meta.get(key):
                report.fail("V2", f"{tag} 元信息缺「{key}」；无内容写「无」")
        if card.prompt_markers != 1:
            report.fail("V2", f"{tag} 应有且仅有一个文生图提示词块，实有 {card.prompt_markers}")
        if not card.prompts:
            report.fail("V2", f"{tag} 文生图提示词为空")
        if card.type == "3D Q版小人":
            if not card.name.endswith("·Q版小人"):
                report.fail("V5", f"{tag} 须使用 `·Q版小人` 后缀")
            if "全片统一造型" not in card.meta.get("说明", ""):
                report.fail("V2", f"{tag} 说明须含「全片统一造型」")
        if "·" in card.name and not card.name.endswith("·Q版小人"):
            report.fail("V5", f"{tag} 非 Q版小人却使用 `·`")
        if card.name.endswith("_Q版小人"):
            report.fail("V5", f"{tag} Q版小人须用 `·`，不能用 `_`")
        if cjk_len(base_state(card.name.split("·")[0])[0]) > 12:
            report.warn("V5", f"{tag} 基础名超过 12 个汉字")
        if state is not None:
            if cjk_len(state) > 18:
                report.warn("V5", f"{tag} 状态词超过 18 个汉字")
            if has_any(state, NONVISUAL_STATE_WORDS) and not deprecated_card:
                report.fail("V20", f"{tag} 状态词不是可见画面差异；兼容/历史/废弃语义不得作为有效状态")

        for prompt in card.prompts:
            if card.type != "不可见声音角色" and "16:9" not in prompt and "16：9" not in prompt:
                report.fail("V4", f"{tag} 提示词未含 16:9")
            if re.search(r"\{[^{}\r\n]+\}", prompt):
                report.fail("V17", f"{tag} 文生图正文残留模板占位符")
            sharp = [word for word in SHARP_WORDS if word.lower() in prompt.lower()]
            if sharp:
                report.fail("V4", f"{tag} 含过锐/堆料词：{'、'.join(sharp)}")
            if state is not None and re.search(r"保留\s*@", prompt):
                report.fail("V4", f"{tag} 使用跨卡 `保留 @xxx`，提示词不自包含")
            if card.type == "角色":
                if "纯白无缝背景" not in prompt:
                    report.fail("V4", f"{tag} 角色提示词缺纯白无缝背景")
                pollution = [word for word in POLLUTION if word in prompt]
                if pollution:
                    report.fail("V4", f"{tag} 角色提示词混入场景词：{'、'.join(pollution)}")
                validate_visual_identity(report, card, prompt)
            elif card.type == "场景":
                if "无人空镜" not in prompt:
                    report.fail("V4", f"{tag} 场景提示词缺无人空镜")
                if not deprecated_card and state == "日":
                    incompatible = [word for word in DAY_INCOMPATIBLE if word in prompt]
                    if incompatible:
                        report.warn(
                            "V19",
                            f"{tag} 白天状态含夜间专属词：{'、'.join(incompatible)}；"
                            "若为世界观常驻天象，须在说明给出剧本证据",
                        )
                elif not deprecated_card and state == "夜":
                    incompatible = [word for word in NIGHT_INCOMPATIBLE if word in prompt]
                    if incompatible:
                        report.warn(
                            "V19",
                            f"{tag} 夜晚状态含日间专属词：{'、'.join(incompatible)}；"
                            "若为世界观常驻天象，须在说明给出剧本证据",
                        )
                if not deprecated_card and "现实层" in prompt and "极境层" in prompt and not re.search(
                    r"双层叠合|虚实叠合|同屏交错|剧本证据", card.meta.get("说明", "")
                ):
                    report.warn(
                        "V19",
                        f"{tag} 同一场景提示词混写现实层与极境层，"
                        "但说明没有同屏叠合证据；应拆状态或只保留当前层",
                    )
                if not deprecated_card and "固定视觉符号" in prompt and not re.search(
                    r"固定视觉符号证据|美术补足：场景|原文明确", card.meta.get("说明", "")
                ):
                    report.warn(
                        "V19",
                        f"{tag} 写入固定视觉符号但说明未标明原文证据或授权美术补足",
                    )
            elif card.type == "道具" and not any(word in prompt for word in ("白底", "中性背景")):
                report.fail("V4", f"{tag} 道具提示词缺白底/中性背景")
            elif card.type == "群像":
                if not any(word in prompt for word in ("纯白", "中性背景")):
                    report.fail("V4", f"{tag} 群像提示词缺纯白/中性背景")
                if "无具名" not in prompt and "generic" not in prompt.lower():
                    report.warn("V4", f"{tag} 群像未声明 generic 身份")
                if (
                    not has_original_face_exception(card, prompt)
                    and not has_any(prompt, GROUP_FACE_PROMPT_TOKENS)
                ):
                    report.warn(
                        "V22",
                        f"{tag} 群像应逐一描述完整、清晰、自然差异化的人脸；"
                        "原著遮脸例外须在提示词与说明中登记证据",
                    )
                if not any(word in prompt for word in ("男性群像", "女性群像", "男女混合群像", "中性人形群像")):
                    report.fail("V15", f"{tag} 群像提示词缺明确性别构成")
                if not deprecated_card and not GROUP_COUNT_RE.search(prompt):
                    report.fail("V21", f"{tag} 群像人数须明确为 3–6 名")
                conflicting_aliases = [
                    alias for alias in split_alias_values(card.meta.get("别名", ""))
                    if INDIVIDUAL_ALIAS_RE.search(alias)
                ]
                if (
                    not deprecated_card
                    and conflicting_aliases
                    and ("无具名" in prompt or "generic" in prompt.lower())
                ):
                    report.fail(
                        "V21",
                        f"{tag} 的无具名群像别名含可独立辨识人物：{'、'.join(conflicting_aliases)}",
                    )
            elif card.type == "生物" and "纯白无缝背景" not in prompt:
                report.fail("V4", f"{tag} 生物提示词缺纯白无缝背景")
            elif card.type == "3D Q版小人":
                if "纯白" not in prompt or not ("chibi" in prompt.lower() or "Q版" in prompt):
                    report.fail("V4", f"{tag} Q版提示词缺纯白背景或 chibi/Q版")
                validate_visual_identity(report, card, prompt)
            if not is_real and card.type in ("角色", "生物", "群像", "3D Q版小人"):
                real_hits = [word for word in REAL_WORDS if word.lower() in prompt.lower()]
                if real_hits:
                    report.warn("V4", f"{tag} 非写实风格含写实/负向写实词：{'、'.join(real_hits)}")

        voice_required = card.type in ("角色", "不可见声音角色")
        if voice_required and not (card.voices or card.bad_voices):
            report.fail("V3", f"{tag} 缺音色行")
        if card.type == "3D Q版小人" and (card.voices or card.bad_voices):
            report.fail("V3", f"{tag} 不得单列音色")
        if card.type in ("场景", "道具") and (card.voices or card.bad_voices):
            report.fail("V3", f"{tag} 不应带音色")
        for bad in card.bad_voices:
            report.fail("V3", f"{tag} 音色行不符合 `角色名音色=（…。）`：{bad[:40]}")
        for voice in card.voices:
            validate_voice(report, card, voice)
            all_card_voices.add(voice)

    prompt_owners: dict[str, list[str]] = {}
    for card in cards:
        if card.type == "不可见声音角色":
            continue
        for prompt in card.prompts:
            prompt_owners.setdefault(compact(prompt), []).append(card.name)
    for owners in prompt_owners.values():
        if len(owners) > 1:
            report.fail("V17", "不同资产卡复制了完全相同的文生图提示词：" + "、".join("@" + name for name in owners))

    for base, state_cards in states_by_base.items():
        family = {
            voice for card in state_cards for voice in card.voices
            if VOICE_RE.match(voice) and VOICE_RE.match(voice).group(1) == base
        }
        if len(family) > 1:
            report.fail("V3", f"@{base} 各状态基础音色不一致")
        visible_states = [card for card in state_cards if card.type in ("角色", "3D Q版小人")]
        if visible_states:
            genders = {card.meta.get("设定性别", "") for card in visible_states}
            beauties = {card.meta.get("颜值定位", "") for card in visible_states}
            if len(genders) > 1:
                report.fail("V15", f"@{base} 各状态设定性别不一致")
            if len(beauties) > 1:
                report.fail("V16", f"@{base} 各状态颜值定位不一致")

    # 日夜母版全文一致性。
    for base, state_cards in states_by_base.items():
        mapping = {base_state(card.name)[1]: card for card in state_cards}
        if "日" in mapping and "夜" in mapping:
            day = mapping["日"].prompts[0] if mapping["日"].prompts else ""
            night = mapping["夜"].prompts[0] if mapping["夜"].prompts else ""
            day_norm = compact(day.replace("白天", "{时段}", 1))
            night_norm = compact(night.replace("夜晚", "{时段}", 1))
            if day_norm != night_norm:
                report.fail("V14", f"@{base}_日/夜 提示词除时间词外不一致")
        elif "日" in mapping or "夜" in mapping:
            report.warn("V14", f"@{base} 只有单一 `_日/_夜` 卡；单一时段新项目应使用基础名")

    voice_section = find_section(sections, "角色音色表")
    if voice_section is None:
        report.fail("V3", "缺角色音色表")
        table_voices: set[str] = set()
    else:
        table_voices = {
            compact(line.strip()) for line in voice_section.splitlines()
            if VOICE_RE.match(line.strip())
        }
        for voice in sorted(all_card_voices - table_voices):
            report.fail("V3", f"卡内音色未逐字汇入音色表：{voice[:40]}")
        for voice in sorted(table_voices - all_card_voices):
            report.warn("V3", f"音色表条目无对应卡内音色：{voice[:40]}")

    list_section = find_section(sections, "可引用 @资产清单")
    listed, untyped = parse_list(list_section)
    if list_section is None:
        report.fail("V6", "缺可引用 @资产清单")
    if untyped:
        report.warn("V6", f"清单 {untyped} 行缺 `（类型）` 括注；新库必须补齐")
    card_names = set(by_name)
    for name, asset_type in listed.items():
        if name not in by_name:
            report.fail("V6", f"清单 @{name} 无对应资产卡")
        elif card_is_deprecated(by_name[name]):
            report.fail("V20", f"已废弃资产 @{name} 不得进入可引用清单")
        elif asset_type and asset_type not in TYPES:
            report.fail("V6", f"清单 @{name} 类型「{asset_type}」不合法")
        elif asset_type and asset_type != by_name[name].type:
            report.fail("V6", f"清单 @{name} 类型「{asset_type}」≠卡内「{by_name[name].type}」")
    for card in cards:
        if not card_is_deprecated(card) and card.name not in listed:
            report.fail("V6", f"资产卡 @{card.name} 未列入可引用清单")
        if card_is_deprecated(card):
            replacement = card.meta.get("替代资产", "")
            if replacement not in ("", "无", "逐镜内联"):
                targets = re.findall(rf"@([\w{CJK}·]+)", replacement)
                if not targets:
                    report.fail("V20", f"@{card.name} 的替代资产须写 @有效资产名或「逐镜内联」")
                for target in targets:
                    if target not in by_name:
                        report.fail("V20", f"@{card.name} 的替代资产 @{target} 不存在")
                    elif card_is_deprecated(by_name[target]):
                        report.fail("V20", f"@{card.name} 的替代资产 @{target} 也已废弃")

    timeline_section = find_section(sections, "状态时间线总表")
    timeline = parse_timeline(timeline_section)
    state_cards = [
        card for card in cards
        if base_state(card.name)[1] is not None and not card_is_deprecated(card)
    ]
    cross_ep = any("EP-" in card.meta.get("出现集", "") for card in cards)
    if state_cards and cross_ep and timeline_section is None:
        report.fail("V9", "跨集多状态项目缺状态时间线总表")
    for card in state_cards:
        if cross_ep and card.name not in timeline:
            report.fail("V9", f"状态卡 @{card.name} 未登记时间线")
    for name, (dimension, span, anchor) in timeline.items():
        if name not in card_names:
            report.fail("V9", f"时间线 @{name} 无对应资产卡")
        if dimension not in ("形态", "体态", "服装", "伤势", "身份呈现", "特殊", "—", "-", "－"):
            report.fail("V9", f"@{name} 维度「{dimension}」不合法")
        if not re.search(r"全剧本|EP-?\d+", span):
            report.warn("V9", f"@{name} 生效区间无法解析：{span}")
        if re.search(r"\d+\s*[/、]\s*\d+", span):
            report.warn("V9", f"@{name} 使用离散集号白名单，建议改场合语义")
        if dimension in ("形态", "服装", "伤势", "身份呈现") and not anchor.strip():
            report.fail("V9", f"@{name}（{dimension}）缺切换锚")

    for base, family_cards in states_by_base.items():
        visible_states = [card for card in family_cards if card.type == "角色"]
        if not visible_states:
            continue
        presentations = {
            (card.meta.get("外观呈现", ""), card.meta.get("呈现性质", ""))
            for card in visible_states
        }
        if len(presentations) > 1:
            identity_rows = [
                card.name for card in visible_states
                if timeline.get(card.name, ("", "", ""))[0] == "身份呈现"
            ]
            if not identity_rows:
                report.fail("V15", f"@{base} 各状态外观呈现/呈现性质发生变化，但时间线没有「身份呈现」维度")

    fx_section = find_section(sections, "技能特效登记表")
    fx_count = 0
    if fx_section:
        for line in fx_section.splitlines():
            stripped = line.strip()
            match = re.match(rf"^([\w{CJK}·]+)特效\s*=\s*（(.+)）\s*$", stripped)
            if match:
                fx_count += 1
                inner = match.group(2)
                for slot in ("颜色", "形态", "粒子光效", "来源", "余波", "等级递进"):
                    if slot not in inner:
                        report.fail("V10", f"{match.group(1)}特效缺「{slot}」槽")
                if not inner.endswith("。"):
                    report.fail("V10", f"{match.group(1)}特效句号须在括号内")
            elif re.match(rf"^[\w{CJK}·]+特效\s*=", stripped):
                report.fail("V10", f"特效行格式错误：{stripped[:40]}")

    image_section = find_section(sections, "图片文件名对照表")
    mapped: set[str] = set()
    if image_section is None:
        report.warn("V11", "缺图片文件名对照表")
    else:
        for line in image_section.splitlines():
            if not line.strip().startswith("|"):
                continue
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            if len(cells) < 2 or not cells[0].startswith("@") or cells[0] in ("@资产", "@资产名"):
                continue
            name = cells[0].lstrip("@").rstrip("。，,.")
            mapped.add(name)
            if name not in by_name:
                report.warn("V11", f"对照表 @{name} 无对应卡")
            elif not cells[1].startswith(name + "."):
                report.warn("V11", f"@{name} 文件名应为 `{name}.png`")
        for card in cards:
            if (
                card.type != "不可见声音角色"
                and not card_is_deprecated(card)
                and card.name not in mapped
            ):
                report.warn("V11", f"@{card.name} 未列入图片文件名对照表")

    basename = os.path.basename(path)
    version_match = re.search(r"_视觉资产库_V(\d+)\.md$", basename)
    version = int(version_match.group(1)) if version_match else None
    if version is None:
        report.warn("V8", "文件名不符合 `{剧本名}_视觉资产库_V{N}.md`")
    has_changelog = any("变更记录" in title for title in sections)
    if version and version >= 2 and not has_changelog:
        report.fail("V8", f"V{version} 缺变更记录")

    if prev_path:
        try:
            previous_text = read_text(prev_path)
            previous_cards, _ = parse_cards(previous_text)
        except (OSError, UnicodeError) as exc:
            report.fail("V7", f"无法读取 --prev：{exc}")
            previous_cards = []
        renames = {old: new for old, new in RENAME_RE.findall(text)}
        deprecated = set(DEPRECATE_RE.findall(text))
        if not has_changelog:
            report.fail("V7", "更新模式缺变更记录")
        for old_card in previous_cards:
            if old_card.name in by_name:
                continue
            if old_card.name in renames and renames[old_card.name] in by_name:
                continue
            if old_card.name in deprecated:
                report.fail("V7", f"@{old_card.name} 登记废弃但卡被删除；废弃不删卡")
            elif old_card.name in states_by_base:
                report.fail("V7", f"旧单卡 @{old_card.name} 首拆多状态未登记受控改名")
            else:
                report.fail("V7", f"旧库资产 @{old_card.name} 在新库消失")
        for name in deprecated:
            if name in by_name and by_name[name].meta.get("使用状态") != "已废弃":
                report.fail("V20", f"变更记录登记废弃 @{name}，但卡内未写 `使用状态：已废弃`")
        new_compact = compact(text)
        exempt = set(renames) | deprecated
        for old_card in previous_cards:
            for voice in old_card.voices:
                owner = voice.split("音色", 1)[0]
                if owner not in exempt and voice not in new_compact:
                    report.fail("V7", f"旧库音色漂移/缺失：{voice[:40]}")

    if index_path:
        try:
            index_text = read_text(index_path)
            index_sections = parse_sections(index_text)
        except (OSError, UnicodeError) as exc:
            report.fail("V12", f"无法读取 --index：{exc}")
            index_text = ""
            index_sections = {}
        library_version = re.search(r"_V(\d+)\.md$", basename)
        index_version = re.search(r"_V(\d+)\.md$", os.path.basename(index_path))
        if library_version and index_version and library_version.group(1) != index_version.group(1):
            report.fail("V12", "索引与库版本不一致")
        index_style = re.search(r"(?m)^视觉风格\s*[:：]\s*(.+?)\s*$", index_text)
        if style and (not index_style or compact(index_style.group(1)) != compact(style)):
            report.fail("V12", "索引视觉风格行与库不一致")
        for title in ("可引用 @资产清单", "角色音色表"):
            if normalized_section(find_section(sections, title)) != normalized_section(find_section(index_sections, title)):
                report.fail("V12", f"索引「{title}」未从库逐字摘录")
        for title in ("技能特效登记表", "状态时间线总表", "资产兼容映射表"):
            library_body = find_section(sections, title)
            index_body = find_section(index_sections, title)
            if library_body is not None and normalized_section(library_body) != normalized_section(index_body):
                report.fail("V12", f"索引「{title}」缺失或与库不一致")
            if library_body is None and index_body is not None:
                report.fail("V12", f"索引多出「{title}」")

    if not any(card.type == "群像" for card in cards):
        report.warn("V13", "群像资产数为 0；须核对全剧本群像排查台账")

    def count(asset_type: str) -> str:
        selected = [card for card in cards if card.type == asset_type]
        bases = {base_state(card.name)[0] for card in selected}
        return str(len(selected)) if len(bases) == len(selected) else f"{len(bases)}(卡{len(selected)})"

    report.info.append(
        f"角色{count('角色')} 场景{count('场景')} 道具{count('道具')} 群像{count('群像')} "
        f"生物{count('生物')} 不可见声音{count('不可见声音角色')} Q版小人{count('3D Q版小人')} "
        f"状态卡{len(state_cards)} 音色行{len(all_card_voices)} 特效登记{fx_count} 时间线{len(timeline)}"
    )
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="校验视觉资产库、旧版锁定和资产索引同步。")
    parser.add_argument("paths", nargs="+", help="资产库文件或包含资产库的目录")
    parser.add_argument("--prev", default="", help="旧版资产库")
    parser.add_argument("--index", default="", help="同版本资产索引")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    files: list[str] = []
    for raw in args.paths:
        if os.path.isdir(raw):
            files.extend(sorted(glob.glob(os.path.join(raw, "*视觉资产库*.md"))))
        else:
            files.append(raw)

    reports: list[Report] = []
    for file_path in files:
        report = validate(file_path, args.prev, args.index)
        reports.append(report)

    if args.json:
        payload = [
            {"file": report.path, "fails": report.fails, "warns": report.warns, "info": report.info}
            for report in reports
        ]
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        for report in reports:
            status = "FAIL" if report.fails else ("WARN" if report.warns else "PASS")
            print(f"\n=== {os.path.basename(report.path)} : {status}  {'; '.join(report.info)}")
            for item in report.fails:
                print(f"  FAIL {item}")
            for item in report.warns:
                print(f"  warn {item}")

        print("\n===== 汇总 =====")
        print("| 文件 | 资产统计 | 机检 |")
        print("|:--|:--|:-:|")
        for report in reports:
            status = "FAIL" if report.fails else ("WARN" if report.warns else "PASS")
            print(f"| {os.path.basename(report.path)} | {'; '.join(report.info) or '-'} | {status} |")
    return 1 if any(report.fails for report in reports) else 0


if __name__ == "__main__":
    raise SystemExit(main())
