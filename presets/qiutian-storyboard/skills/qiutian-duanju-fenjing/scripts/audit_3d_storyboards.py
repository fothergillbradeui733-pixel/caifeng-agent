#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path

DEFAULT_TONE = ""
DEFAULT_BAN = "🚫 无BGM，无字幕，无水印，无非剧情画面文字，人物外观沿用参考图，禁止生成同一张脸的角色，禁止生成双胞胎，禁止生成角色一样的人物。"

REQUIRED_HEADERS = [
    "剧情摘要",
    "导演/编剧处理",
    "节奏走向",
    "本集调用模块",
    "本集新增资产",
    "抽卡/资产参考基调",
    "本集使用人物/资产索引",
]

BAD_VISUAL_TERMS = [
    "分给", "安排", "负责", "意味着", "说明", "证明",
    "心里有数", "意识到", "反应过来", "明白", "知道", "判断",
    "像是在", "仿佛", "重新对上", "心里已经明白",
    "心里", "脑子里", "盘算", "觉得", "以为", "相信", "怀疑",
]

BAD_LENS_TERMS = [
    "心动", "蓄力", "爆点", "命令", "起势", "时间恢复",
    "短钩", "爽点", "钩子", "反应落点", "情绪", "压迫",
]

GENERIC_VISUAL_TERMS = [
    "他", "她", "男人", "女人", "老人", "小孩", "孩子", "众人",
]

ORDINARY_CAST_TERMS = [
    "食物", "饭菜", "菜盘", "骨头", "碗", "筷", "桌", "椅",
    "灰尘", "窗帘", "衣服", "蒸汽", "雨", "烟", "火光",
]

Q_ENTITY_TERMS = [
    "实体Q版小人", "实体Q版", "Q版贴纸", "角落Q版", "左上角Q版",
]

END_SUMMARY_MARKERS = [
    "本集总时长", "遗留信息", "最后一帧画面", "未解决悬念",
    "人物状态", "模块延续", "OS表现设定", "继续？",
]

SAME_AS_ABOVE_TERMS = [
    "同上", "延续上个Block", "参考本集基调", "参考上文", "同前",
]

SHOT_SIZES = (
    "大远景", "中全景", "中近景", "大特写", "极特写",
    "远景", "全景", "中景", "近景", "特写",
)


def parse_range_list(value):
    allowed = set()
    if not value:
        return allowed
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            start, end = part.split("-", 1)
            allowed.update(range(int(start), int(end) + 1))
        else:
            allowed.add(int(part))
    return allowed


def episode_number(path):
    m = re.search(r"第(\d+)集", path.name)
    return int(m.group(1)) if m else None


def split_blocks(text):
    matches = list(re.finditer(r"^── Block\s+(\d+)\s+\|\s+([0-9.]+)s\s+──\s*$", text, re.M))
    blocks = []
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        if i + 1 == len(matches):
            endings = [
                pos for marker in ["\n⏱ 本集总时长", "\n本集总时长", "\n🧷 遗留信息", "\n遗留信息", "\n继续提示", "\n继续？"]
                for pos in [text.find(marker, m.end())]
                if pos != -1
            ]
            if endings:
                end = min(endings)
        blocks.append((int(m.group(1)), float(m.group(2)), m.start(), text[m.start():end]))
    return blocks


def line_number(text, pos):
    return text.count("\n", 0, pos) + 1


def voice_line_ok(line):
    normal = r"^声线/语气：@\S+｜固定声线：[^｜]+｜语速(正常|快|慢)｜状态：[^｜]+｜语气：.+$"
    simplified = r"^声线/语气：@\S+｜[^｜]+｜[^｜]+｜[^｜]+｜.+$"
    return re.match(normal, line) or re.match(simplified, line)


def dialogue_line(line):
    return line.startswith("@") and "：“" in line and any(x in line for x in ["说：", "问：", "喊：", "叫：", "吼：", "答："])


def normalize_for_match(value):
    return re.sub(r"\s+", "", value.strip())


def dialogue_text_length(line):
    m = re.search(r"：“(.+?)”", line)
    if not m:
        return 0
    payload = re.sub(r"[，。！？、；：,.!?;:\s]", "", m.group(1))
    return len(payload)


def previous_nonempty(lines, idx):
    for prev in range(idx - 1, -1, -1):
        if lines[prev].strip():
            return lines[prev]
    return ""


def ordinary_cast_hits(line):
    payload = line.split("：", 1)[1] if "：" in line else line
    items = [part.strip() for part in re.split(r"[，,、]", payload) if part.strip()]
    hits = []
    for item in items:
        name = item.lstrip("@").strip()
        for term in ORDINARY_CAST_TERMS:
            if term not in name:
                continue
            if term in {"雨", "烟"} and name != term and not name.startswith(term):
                continue
            hits.append(term)
    return sorted(set(hits))


def find_same_as_above(text, term):
    for match in re.finditer(re.escape(term), text):
        prev_char = text[match.start() - 1] if match.start() > 0 else ""
        next_char = text[match.end()] if match.end() < len(text) else ""
        if term == "同上" and prev_char == "一" and next_char == "奏":
            continue
        return match.start()
    return -1


def audit_file(path, tone, ban, q_allowed):
    text = path.read_text(encoding="utf-8")
    ep = episode_number(path)
    issues = []

    for header in REQUIRED_HEADERS:
        if header not in text:
            issues.append(("missing_header", 1, header))

    blocks = split_blocks(text)
    if not blocks:
        issues.append(("no_blocks", 1, "no Block headers found"))

    for marker in END_SUMMARY_MARKERS:
        if marker not in text:
            issues.append(("missing_episode_ending_marker", 1, marker))

    for term in SAME_AS_ABOVE_TERMS:
        pos = find_same_as_above(text, term)
        if pos != -1:
            issues.append(("same_as_above_reference", line_number(text, pos), term))

    for block_no, seconds, start, block in blocks:
        base_line = line_number(text, start)
        lines = block.splitlines()

        if seconds > 15:
            issues.append(("block_too_long", base_line, f"Block {block_no}: {seconds}s"))

        tone_lines = [line for line in lines if line.startswith("视频整体基调：")]
        if tone:
            if block.count(tone) != 1:
                issues.append(("tone_not_exact_once", base_line, f"Block {block_no}"))
        else:
            if len(tone_lines) != 1:
                issues.append(("tone_line_not_once", base_line, f"Block {block_no}: {len(tone_lines)} tone lines"))
            elif "无字幕" not in tone_lines[0] or "无水印" not in tone_lines[0]:
                issues.append(("tone_missing_no_subtitle_watermark", base_line, tone_lines[0]))
        if block.count(ban) != 1:
            issues.append(("ban_not_exact_once", base_line, f"Block {block_no}"))
        if not any(line.startswith("📍 场景：") for line in lines):
            issues.append(("missing_scene", base_line, f"Block {block_no}"))
        if not any(line.startswith("👤 出场：") for line in lines):
            issues.append(("missing_cast", base_line, f"Block {block_no}"))
        start_state_lines = [line for line in lines if line.startswith("🧭 起始空间状态：")]
        if len(start_state_lines) != 1:
            issues.append(("start_state_not_exact_once", base_line, f"Block {block_no}: {len(start_state_lines)} lines"))
        for idx, line in enumerate(lines):
            if re.match(r"^(?:🎲\s*)?(?:生成风险|抽卡风险|Generation\s+risk)\s*[：:]", line, re.I):
                issues.append((
                    "unexpected_public_risk",
                    base_line + idx,
                    f"Block {block_no}: 复杂度只保存在内部台账，不得输出风险/备选方案",
                ))

        lens_total = 0.0
        lens_count = 0
        lens_matches = list(re.finditer(r"^镜头\s+\d+\s+持续时间:\s*([0-9.]+)s【([^】]+)】", block, re.M))
        for lens_index, lm in enumerate(lens_matches):
            lens_line = base_line + block[:lm.start()].count("\n")
            lens_count += 1
            lens_seconds = float(lm.group(1))
            lens_total += lens_seconds
            bracket = lm.group(2)
            if "+" not in bracket and "＋" not in bracket:
                issues.append(("lens_missing_plus", lens_line, bracket))
            else:
                lens_parts = [part.strip() for part in re.split(r"[+＋]", bracket) if part.strip()]
                subject_size = lens_parts[0] if lens_parts else ""
                shot_size = next((size for size in SHOT_SIZES if subject_size.endswith(size)), None)
                if shot_size is None:
                    issues.append(("lens_size_missing", lens_line, bracket))
                elif not subject_size[:-len(shot_size)].strip():
                    issues.append(("lens_subject_missing", lens_line, bracket))
            if any(term in bracket for term in BAD_LENS_TERMS):
                issues.append(("lens_intent_word", lens_line, bracket))
            if lens_seconds > 6:
                issues.append(("lens_too_long_needs_action_or_split", lens_line, f"Block {block_no}: lens={lens_seconds}s"))
            lens_end = lens_matches[lens_index + 1].start() if lens_index + 1 < len(lens_matches) else len(block)
            lens_body = block[lm.end():lens_end]
            angle_count = len(re.findall(r"^镜头角度[：:].+$", lens_body, re.M))
            if angle_count != 1:
                issues.append(("angle_not_exact_once", lens_line, f"Block {block_no}: {angle_count} angle lines"))
        if lens_count == 0:
            issues.append(("no_lens_lines", base_line, f"Block {block_no}"))
        if lens_count == 1 and seconds > 6:
            issues.append(("single_lens_long_block", base_line, f"Block {block_no}: {seconds}s"))
        if seconds > 10 and lens_count < 3:
            issues.append(("low_lens_density", base_line, f"Block {block_no}: {seconds}s with {lens_count} lens(es)"))
        if seconds > 14 and lens_count < 4:
            issues.append(("low_lens_density", base_line, f"Block {block_no}: {seconds}s with {lens_count} lens(es), expected 4+"))
        if lens_total and abs(lens_total - seconds) > 0.6:
            issues.append(("block_lens_time_mismatch", base_line, f"Block {block_no}: block={seconds}, lenses={lens_total:.1f}"))

        for idx, line in enumerate(lines):
            ln = base_line + idx
            if line.startswith("👤 出场："):
                cast_hits = ordinary_cast_hits(line)
                if cast_hits:
                    issues.append(("ordinary_prop_in_cast_candidate", ln, "、".join(cast_hits) + "｜" + line))
                if "Q版" in line and ep not in q_allowed:
                    issues.append(("unauthorized_q_cast", ln, line))
            if line.startswith("画面描述："):
                scan = line.replace("@离婚证明", "").replace("离婚证明", "")
                hits = [term for term in BAD_VISUAL_TERMS if term in scan]
                if hits:
                    issues.append(("abstract_visual_candidate", ln, "、".join(hits) + "｜" + line))
                pronoun_scan = scan.replace("其他", "").replace("他人", "")
                generic_hits = [term for term in GENERIC_VISUAL_TERMS if term in pronoun_scan]
                if generic_hits:
                    issues.append(("generic_visual_reference_candidate", ln, "、".join(generic_hits) + "｜" + line))
                if "摄像机" in line or "镜头聚焦" in line or "聚焦" in line:
                    issues.append(("camera_word_in_visual", ln, line))
                if "Q版" in line and ep not in q_allowed:
                    issues.append(("unauthorized_q_visual", ln, line))
                q_entity_hits = [term for term in Q_ENTITY_TERMS if term in line]
                if q_entity_hits:
                    issues.append(("q_entity_or_sticker_wording", ln, "、".join(q_entity_hits) + "｜" + line))
                if "Q版" in line and ("左上角" in line or "右上角" in line or "角落" in line):
                    issues.append(("q_corner_placement_candidate", ln, line))
                if "Q版" in line and "嘴巴不动" not in line:
                    issues.append(("q_visual_missing_body_silent", ln, line))
            if line.startswith("声线/语气：") and not voice_line_ok(line):
                issues.append(("voice_format_bad", ln, line))
            if "本句语速" in line or "本句状态" in line or "本句语气" in line:
                issues.append(("old_voice_field", ln, line))
            if dialogue_line(line):
                if lens_count == 1 and dialogue_text_length(line) > 24:
                    issues.append(("long_dialogue_in_single_lens", ln, f"{dialogue_text_length(line)} chars｜{line}"))
                if "Q版小人口播" in line:
                    prev = previous_nonempty(lines, idx)
                    if not (prev.startswith("画面描述：") and "Q版" in prev and "嘴巴不动" in prev):
                        issues.append(("q_os_not_bound_to_previous_visual", ln, line))
                found = any(l.startswith("声线/语气：") for l in lines[idx + 1:idx + 4])
                if not found:
                    issues.append(("dialogue_missing_nearby_voice", ln, line))

        if "Q版" in block and ep not in q_allowed:
            issues.append(("unauthorized_q_block", base_line, f"Block {block_no}"))

    return {
        "file": str(path),
        "episode": ep,
        "blocks": len(blocks),
        "issues": [{"kind": k, "line": line, "detail": detail} for k, line, detail in issues],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, help="Storyboard folder")
    parser.add_argument("--tone", default=DEFAULT_TONE)
    parser.add_argument("--ban", default=DEFAULT_BAN)
    parser.add_argument("--allow-q-episodes", default="", help="Episode numbers/ranges where Q version is allowed, e.g. 1-10,15")
    parser.add_argument("--required-dialogue", default="", help="UTF-8 text file with one required S/A dialogue snippet per line")
    parser.add_argument("--out", default="", help="Optional JSON output path")
    args = parser.parse_args()

    root = Path(args.root)
    q_allowed = parse_range_list(args.allow_q_episodes)
    files = sorted(root.glob("*第*集*分镜*.txt"), key=lambda p: episode_number(p) or 9999)
    results = [audit_file(path, args.tone, args.ban, q_allowed) for path in files]
    summary = {}
    for result in results:
        for issue in result["issues"]:
            summary[issue["kind"]] = summary.get(issue["kind"], 0) + 1

    required_dialogue = {"checked": 0, "missing": []}
    if args.required_dialogue:
        snippets = [
            line.strip()
            for line in Path(args.required_dialogue).read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        combined = normalize_for_match("\n".join(path.read_text(encoding="utf-8") for path in files))
        required_dialogue["checked"] = len(snippets)
        for snippet in snippets:
            if normalize_for_match(snippet) not in combined:
                required_dialogue["missing"].append(snippet)
        if required_dialogue["missing"]:
            summary["required_dialogue_missing"] = len(required_dialogue["missing"])

    payload = {
        "root": str(root),
        "file_count": len(files),
        "issue_summary": dict(sorted(summary.items())),
        "results": results,
        "required_dialogue": required_dialogue,
    }
    out = Path(args.out) if args.out else root / "storyboard_audit.json"
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"file_count": len(files), "issue_summary": payload["issue_summary"], "report": str(out)}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
