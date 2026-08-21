#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_storyboard.py — 分镜交付格式确定性机检 v2（认用户拍板的新格式）
用法: python3 check_storyboard.py <分镜文件或目录>...

认的格式（2026-08-13 全局交付规范）:
  Block头        ── Block N | Ys ──
  字段序         📍场景 → 👤出场 → 视频整体基调 → 🧭起始空间状态 → 具体故事情节描述
                 → 【音频规范】(角色音色/全局音轨/最后一镜结束站位) → 🚫
  镜头行         🎬 镜头 N【取景主体 景别 运镜】  空格分隔，Block内从1连续编号
  音色五维       @角色音色=（【类型】嗓音演绎，音色…，音调…，…标准普通话…）
               （旧终稿的简化音色行也认：@角色音色=（…标准普通话…））

禁（旧V8格式残留）: 单镜时长行、镜头角度行、画面描述标签、台词/声线独立行、
  抽卡风险/生成风险公开字段、服装描述词。

只查确定性结构；源忠实、相邻Block缝合、空间语义另行审查（见 SKILL.md）。
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
from typing import Sequence

BLOCK_RE = re.compile(r"^──\s*Block\s+(\d+)\s*\|\s*([0-9.]+)s\s*──\s*$", re.MULTILINE)
SCENE_RE = re.compile(r"^📍\s*场景\s*[：:].+$", re.MULTILINE)
CAST_RE = re.compile(r"^👤\s*出场\s*[：:].+$", re.MULTILINE)
START_STATE_RE = re.compile(r"^🧭\s*起始空间状态\s*[：:]\s*(.+)$", re.MULTILINE)
TONE_RE = re.compile(r"^视频整体基调\s*[：:].+$", re.MULTILINE)
SHOT_RE = re.compile(r"^🎬\s*镜头\s+(\d+)【([^】]+)】\s*$", re.MULTILINE)
VOICE_LINE_RE = re.compile(r"^角色音色\s*[：:].*$", re.MULTILINE)
AUDIO_BLOCK_RE = re.compile(r"【音频规范】")
GLOBAL_TRACK_RE = re.compile(r"^全局音轨\s*[：:].+$", re.MULTILINE)
END_STATE_RE = re.compile(r"^最后一镜结束站位\s*[：:]\s*(.+)$", re.MULTILINE)

# 旧V8格式残留，出现即报错
FORBIDDEN_PATTERNS = [
    (re.compile(r"^镜头\s+\d+\s+持续时间\s*[：:]", re.MULTILINE), "旧格式镜头行（单镜时长）"),
    (re.compile(r"^镜头角度\s*[：:]", re.MULTILINE), "镜头角度行"),
    (re.compile(r"^画面描述\s*[：:]", re.MULTILINE), "画面描述标签"),
    (re.compile(r"^台词\s*[：:]", re.MULTILINE), "独立台词行（台词须揉入正文）"),
    (re.compile(r"^声线\s*[：:]", re.MULTILINE), "独立声线行"),
    (re.compile(r"^(?:🎲\s*)?(?:生成风险|抽卡风险)\s*[：:]", re.MULTILINE | re.IGNORECASE),
     "公开风险字段"),
]

STORY_LABEL_RE = re.compile(r"^具体故事情节描述\s*[：:]", re.MULTILINE)
BAN_RE = re.compile(r"^🚫.+", re.MULTILINE)
# 字段顺序锚点（各 Block 内必须按此顺序各出现一次）
FIELD_ANCHORS = (
    ("📍", re.compile(r"^📍\s*场景", re.MULTILINE), "scene_order"),
    ("👤", re.compile(r"^👤\s*出场", re.MULTILINE), "cast_order"),
    ("基调", re.compile(r"^视频整体基调", re.MULTILINE), "tone_order"),
    ("🧭", re.compile(r"^🧭\s*起始空间状态", re.MULTILINE), "state_order"),
    ("故事", STORY_LABEL_RE, "story_label_order"),
    ("音频", AUDIO_BLOCK_RE, "audio_order"),
    ("🚫", BAN_RE, "ban_order"),
)

SHOT_SIZES = (
    "大远景", "远景", "全景", "中全景", "中景", "双人中景",
    "中近景", "双人中近景", "近景", "特写", "大特写",
)
CHINESE_CLOTHING = (
    "身穿", "身着", "穿着", "上身是", "穿一件", "穿一条", "穿一双", "头戴",
    "戴帽子", "戴围巾", "系领带", "西装", "风衣", "大衣", "外套", "夹克",
    "衬衫", "毛衣", "卫衣", "旗袍", "长袍", "制服", "礼服", "睡衣", "工装",
    "高跟鞋", "皮鞋", "运动鞋", "鸭舌帽", "布鞋", "棉袄", "马甲",
)
# 道具/剧情用词的豁免（出现在这些片段中不算服装描述）
CLOTHING_EXEMPT_SNIPPETS = ("婚纱店", "婚纱照", "婚纱礼服店", "围裙", "工装裤口袋")
# 服装名词仅在与穿着语境组合时才判违规（裸名词常是群像制服标识/道具/剧情提及）
CLOTHING_NOUN_TERMS = frozenset((
    "西装", "风衣", "大衣", "外套", "夹克", "衬衫", "毛衣", "卫衣",
    "旗袍", "长袍", "制服", "礼服", "睡衣", "工装", "高跟鞋", "皮鞋",
    "运动鞋", "鸭舌帽", "布鞋", "棉袄", "马甲",
))
WEAR_CONTEXT_RE = re.compile(r"(身穿|身着|穿着|穿|头戴|戴|系|一身|一件|一条|一双)[^，。；]{0,4}$")
# 不进服装扫描的行：音色行、基调行、全局音轨行、结束站位行（姿态行）
CLOTHING_SKIP_LINE_PREFIXES = ("视频整体基调", "全局音轨", "最后一镜结束站位", "角色音色")

@dataclass(frozen=True)
class Issue:
    code: str
    line: int
    detail: str


def line_number(text: str, position: int) -> int:
    return text.count("\n", 0, position) + 1


def _count_issue(issues: list[Issue], block: str, block_line: int,
                 pattern: re.Pattern, code: str, label: str) -> None:
    n = len(pattern.findall(block))
    if n != 1:
        issues.append(Issue(code, block_line, f"{label} expected once, found {n}"))


def _check_field_order(issues: list[Issue], block: str, block_line: int, block_no: int) -> None:
    positions = []
    for label, pat, code in FIELD_ANCHORS:
        m = pat.search(block)
        if m is None:
            continue  # 缺失问题已由单项计数检查报告
        positions.append((m.start(), label, code))
    for i in range(1, len(positions)):
        if positions[i][0] < positions[i - 1][0]:
            issues.append(Issue(
                positions[i][2],
                block_line + block.count("\n", 0, positions[i][0]),
                f"Block {block_no}: 「{positions[i][1]}」字段顺序错误，"
                f"须排在「{positions[i - 1][1]}」之后（场景→出场→基调→空间状态→故事→音频→🚫）",
            ))
            break


ASSET_NAME_RE = re.compile(r"@[\w\u4e00-\u9fff_]*")
# 群像制服标识：群像逐镜内联无参考图，统一服装词是其唯一外观锚，豁免
CLOTHING_CONTEXT_EXEMPTS = ("黑西装",)
# 道具级用法：高跟鞋作为镜头道具动作（落地/踩着/声），不是人物着装描述
PROP_USE_RE = re.compile(r"高跟鞋(?:落地|落地声|着地|声)|踩着?高跟鞋")


def _check_clothing(issues: list[Issue], block: str, block_line: int, block_no: int) -> None:
    for ln_offset, line in enumerate(block.split("\n")):
        stripped = line.strip()
        if any(stripped.startswith(prefix) for prefix in CLOTHING_SKIP_LINE_PREFIXES):
            continue  # 音色/基调/音轨/站位行不在服装扫描范围
        scan_line = ASSET_NAME_RE.sub("", line)  # @资产名内的词不查
        for term in CHINESE_CLOTHING:
            if term not in scan_line:
                continue
            if any(ctx in scan_line and term in ctx for ctx in CLOTHING_CONTEXT_EXEMPTS):
                continue
            if term == "高跟鞋" and (PROP_USE_RE.search(scan_line) or "落地的高跟鞋" in scan_line):
                continue
            if any(snip in scan_line and term in snip for snip in CLOTHING_EXEMPT_SNIPPETS):
                continue
            # 服装名词：仅当处于穿着语境（穿/戴/系/一身/一件…+名词）才判违规；
            # 裸名词多为群像制服标识、道具或剧情提及，不误伤
            if term in CLOTHING_NOUN_TERMS:
                hit = False
                for m in re.finditer(re.escape(term), scan_line):
                    if WEAR_CONTEXT_RE.search(scan_line[:m.start()]):
                        hit = True
                        break
                if not hit:
                    continue
            issues.append(Issue(
                "clothing_description",
                block_line + ln_offset,
                f"Block {block_no}: 服装词「{term}」；人物外观由@资产参考图控制",
            ))


def check_text(text: str) -> list[Issue]:
    issues: list[Issue] = []
    blocks = list(BLOCK_RE.finditer(text))
    if not blocks:
        return [Issue("no_blocks", 1, "未找到 ── Block N | Ys ── 标题")]

    for index, match in enumerate(blocks):
        block_no = int(match.group(1))
        block_seconds = float(match.group(2))
        start = match.start()
        end = blocks[index + 1].start() if index + 1 < len(blocks) else len(text)
        block = text[start:end]
        block_line = line_number(text, start)

        if index == 0 and block_no != 1:
            issues.append(Issue("block_number", block_line, f"首个 Block 应为 1，实际 {block_no}"))
        elif index > 0 and block_no != int(blocks[index - 1].group(1)) + 1:
            issues.append(Issue("block_number", block_line, f"Block 编号不连续：{block_no}"))

        if block_seconds > 30.0 + 1e-9:
            issues.append(Issue("block_too_long", block_line, f"Block {block_no}: {block_seconds}s > 30s"))
        if block_seconds < 1.0:
            issues.append(Issue("block_too_short", block_line, f"Block {block_no}: {block_seconds}s < 1s"))

        _count_issue(issues, block, block_line, SCENE_RE, "scene_count", "📍场景行")
        _count_issue(issues, block, block_line, CAST_RE, "cast_count", "👤出场行")
        _count_issue(issues, block, block_line, START_STATE_RE, "start_state_count", "🧭起始空间状态行")
        _count_issue(issues, block, block_line, TONE_RE, "tone_count", "视频整体基调行")
        _count_issue(issues, block, block_line, STORY_LABEL_RE, "story_label_count", "具体故事情节描述标签")
        _count_issue(issues, block, block_line, BAN_RE, "ban_count", "🚫禁用行")
        _check_field_order(issues, block, block_line, block_no)

        state_m = START_STATE_RE.search(block)
        if state_m and state_m.group(1).strip() == "":
            issues.append(Issue("start_state_empty", block_line, f"Block {block_no}: 起始空间状态为空"))

        # 镜头行：格式 + 编号 + 景别
        shots = list(SHOT_RE.finditer(block))
        if not shots:
            issues.append(Issue("no_shots", block_line, f"Block {block_no}: 未找到 🎬 镜头行"))
        for si, sm in enumerate(shots):
            shot_no = int(sm.group(1))
            shot_line = block_line + block.count("\n", 0, sm.start())
            if shot_no != si + 1:
                issues.append(Issue("shot_number", shot_line,
                                    f"Block {block_no}: expected 镜头 {si + 1}, found 镜头 {shot_no}"))
            parts = [p.strip() for p in sm.group(2).split() if p.strip()]
            if len(parts) < 3:
                issues.append(Issue("shot_header_fields", shot_line,
                                    f"Block {block_no} 镜头 {shot_no}: 【取景主体 景别 运镜】至少三段"))
                continue
            subject, size, move = parts[0], parts[-2], parts[-1]
            if not subject:
                issues.append(Issue("shot_subject", shot_line,
                                    f"Block {block_no} 镜头 {shot_no}: 缺少取景主体"))
            if not any(size.endswith(sz) for sz in SHOT_SIZES):
                issues.append(Issue("shot_size", shot_line,
                                    f"Block {block_no} 镜头 {shot_no}: 「{size}」须以标准景别结尾"))

        # 旧格式残留
        for pat, label in FORBIDDEN_PATTERNS:
            for fm in pat.finditer(block):
                issues.append(Issue("legacy_format", block_line + block.count("\n", 0, fm.start()),
                                    f"Block {block_no}: 禁止{label}"))

        # 服装词
        _check_clothing(issues, block, block_line, block_no)

        # 音频规范
        audio = AUDIO_BLOCK_RE.search(block)
        if not audio:
            issues.append(Issue("audio_block_missing", block_line, f"Block {block_no}: 缺【音频规范】"))
        else:
            voice_lines = VOICE_LINE_RE.findall(block)
            if not voice_lines:
                issues.append(Issue("voice_missing", block_line,
                                    f"Block {block_no}: 缺 角色音色 行"))
            # 音色收尾以权威音色锁定为准；无权威锁时默认"标准普通话。"，
            # 有方言锁（如 带轻微华中乡音）时以锁定值收尾，不硬查字面。
            _count_issue(issues, block, block_line, GLOBAL_TRACK_RE, "global_track_count", "全局音轨行")
            if not END_STATE_RE.search(block):
                issues.append(Issue("end_state_missing", block_line,
                                    f"Block {block_no}: 缺 最后一镜结束站位 行"))

    return issues


def collect_files(paths: Sequence[str]) -> list[Path]:
    files: set[Path] = set()
    for raw in paths:
        p = Path(raw)
        if p.is_file():
            files.add(p)
        elif p.is_dir():
            files.update(item for item in p.rglob("*") if item.suffix.lower() in {".txt", ".md"})
    return sorted(files)


def format_report(path: Path, issues: Sequence[Issue]) -> str:
    found = list(issues)
    if not found:
        return f"PASS {path}"
    lines = [f"FAIL {path} ({len(found)} issues)"]
    lines.extend(f"  [{i.code}] line {i.line}: {i.detail}" for i in found)
    return "\n".join(lines)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="分镜交付格式确定性机检 v2（新格式）")
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
