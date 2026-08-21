#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_storyboard.py 的单元测试（认用户拍板的新交付格式）。"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest

SCRIPT = Path(__file__).with_name("check_storyboard.py")


def load_checker():
    if not SCRIPT.exists():
        raise AssertionError(f"missing implementation: {SCRIPT.name}")
    spec = importlib.util.spec_from_file_location("check_storyboard", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


checker = load_checker()

VALID = """── Block 1 | 12s ──

📍 场景：@秦家堂屋（日）
👤 出场：@秦川_分家装，@何秀梅_强势期
视频整体基调：写实电影感、年代剧质感、暖黄色调、明亮日景室内自然光、胶片颗粒、9:16竖屏、无字幕、无水印。
🧭 起始空间状态：@秦川_分家装（站在供桌另一侧）｜@何秀梅_强势期（站在供桌旁，手里捏着@分家契）

具体故事情节描述：
🎬 镜头 1【秦家堂屋 全景 缓推】
明亮的堂屋里，@何秀梅_强势期 立在供桌旁，@秦川_分家装 站在桌另一侧。
🎬 镜头 2【何秀梅 近景 固定】
@何秀梅_强势期 扬起下巴：借二百办婚事？先把家分了！

【音频规范】
角色音色：@秦川_分家装音色=（【男青年】嗓音演绎，音色朴实清朗，音调偏中，带轻微华中乡音。）｜@何秀梅_强势期音色=（【女青年】嗓音演绎，音色明快偏硬，音调偏高，带轻微华中乡音。）
全局音轨：堂屋环境音、契纸拍桌声、对白；无内心OS；无BGM。
最后一镜结束站位：@何秀梅_强势期（站在供桌旁）｜@秦川_分家装（站在供桌另一侧）。
🚫 无BGM，无字幕，无水印，人物外观沿用参考图与真实肤质。
"""


def codes(issues):
    return [i.code for i in issues]


class CheckStoryboardTest(unittest.TestCase):
    def test_valid_block_passes(self):
        self.assertEqual(checker.check_text(VALID), [])

    def test_no_blocks(self):
        self.assertIn("no_blocks", codes(checker.check_text("随便一段文字")))

    def test_block_over_15s(self):
        text = VALID.replace("── Block 1 | 12s ──", "── Block 1 | 16s ──")
        self.assertIn("block_too_long", codes(checker.check_text(text)))

    def test_legacy_shot_duration_line_forbidden(self):
        text = VALID + "\n镜头 3 持续时间: 2s【特写 + 固定镜头】\n"
        self.assertIn("legacy_format", codes(checker.check_text(text)))

    def test_angle_line_forbidden(self):
        text = VALID.replace("🎬 镜头 2【何秀梅 近景 固定】",
                             "🎬 镜头 2【何秀梅 近景 固定】\n镜头角度：平视")
        self.assertIn("legacy_format", codes(checker.check_text(text)))

    def test_picture_description_label_forbidden(self):
        text = VALID.replace("🎬 镜头 2【何秀梅 近景 固定】",
                             "🎬 镜头 2【何秀梅 近景 固定】\n画面描述：她扬下巴。")
        self.assertIn("legacy_format", codes(checker.check_text(text)))

    def test_dialogue_line_forbidden(self):
        text = VALID.replace("🎬 镜头 2【何秀梅 近景 固定】",
                             "🎬 镜头 2【何秀梅 近景 固定】\n台词：@何秀梅_强势期：“先分家。”")
        self.assertIn("legacy_format", codes(checker.check_text(text)))

    def test_risk_field_forbidden(self):
        text = VALID + "\n抽卡风险：中\n"
        self.assertIn("legacy_format", codes(checker.check_text(text)))

    def test_shot_numbering_must_be_sequential(self):
        text = VALID.replace("🎬 镜头 2【何秀梅 近景 固定】", "🎬 镜头 3【何秀梅 近景 固定】")
        self.assertIn("shot_number", codes(checker.check_text(text)))

    def test_shot_header_needs_subject_size_move(self):
        text = VALID.replace("🎬 镜头 1【秦家堂屋 全景 缓推】", "🎬 镜头 1【全景】")
        self.assertIn("shot_header_fields", codes(checker.check_text(text)))

    def test_bare_shot_size_rejected(self):
        text = VALID.replace("🎬 镜头 2【何秀梅 近景 固定】", "🎬 镜头 2【近景 固定】")
        self.assertIn("shot_header_fields", codes(checker.check_text(text)))

    def test_size_with_location_prefix_ok(self):
        # 取景主体+景别合并写法（如 街对面全景）允许，以标准景别结尾即可
        text = VALID.replace("🎬 镜头 1【秦家堂屋 全景 缓推】", "🎬 镜头 1【街对面全景 固定】")
        self.assertNotIn("shot_size", codes(checker.check_text(text)))

    def test_missing_start_state(self):
        text = VALID.replace("🧭 起始空间状态：@秦川_分家装（站在供桌另一侧）｜@何秀梅_强势期（站在供桌旁，手里捏着@分家契）\n", "")
        self.assertIn("start_state_count", codes(checker.check_text(text)))

    def test_missing_audio_block(self):
        text = VALID.replace("【音频规范】", "")
        self.assertIn("audio_block_missing", codes(checker.check_text(text)))

    def test_missing_voice_line(self):
        text = VALID.replace("角色音色：@秦川_分家装音色=（【男青年】嗓音演绎，音色朴实清朗，音调偏中，带轻微华中乡音。）｜@何秀梅_强势期音色=（【女青年】嗓音演绎，音色明快偏硬，音调偏高，带轻微华中乡音。）\n", "")
        self.assertIn("voice_missing", codes(checker.check_text(text)))

    def test_voice_without_mandarin_ok_when_authority_locked(self):
        # 权威音色锁定以方言收尾（带轻微华中乡音），不硬查"标准普通话"字面
        text = VALID  # VALID 内即方言收尾音色，应 PASS
        self.assertEqual(checker.check_text(text), [])

    def test_missing_end_state(self):
        text = VALID.replace("最后一镜结束站位：@何秀梅_强势期（站在供桌旁）｜@秦川_分家装（站在供桌另一侧）。\n", "")
        self.assertIn("end_state_missing", codes(checker.check_text(text)))

    def test_clothing_word_rejected(self):
        text = VALID.replace("明亮的堂屋里，", "明亮的堂屋里，他身穿白衬衫，")
        self.assertIn("clothing_description", codes(checker.check_text(text)))

    def test_clothing_word_inside_asset_name_ok(self):
        # @黑西装保镖群 是资产名/群像名，不算服装描述
        text = VALID.replace("👤 出场：@秦川_分家装，@何秀梅_强势期",
                             "👤 出场：@秦川_分家装，@黑西装保镖群")
        self.assertNotIn("clothing_description", codes(checker.check_text(text)))

    def test_block_numbering_sequential(self):
        second = VALID.replace("── Block 1 | 12s ──", "── Block 2 | 12s ──")
        text = VALID + "\n" + second
        self.assertEqual(codes(checker.check_text(text)), [])

    def test_block_number_gap(self):
        third = VALID.replace("── Block 1 | 12s ──", "── Block 3 | 12s ──")
        text = VALID + "\n" + third
        self.assertIn("block_number", codes(checker.check_text(text)))

    def test_field_order_violation(self):
        text = VALID.replace("📍 场景：@秦家堂屋（日）\n👤 出场：@秦川_分家装，@何秀梅_强势期",
                             "👤 出场：@秦川_分家装，@何秀梅_强势期\n📍 场景：@秦家堂屋（日）")
        self.assertIn("cast_order", codes(checker.check_text(text)))

    def test_missing_ban_line(self):
        text = VALID.replace("🚫 无BGM，无字幕，无水印，人物外观沿用参考图与真实肤质。\n", "")
        self.assertIn("ban_count", codes(checker.check_text(text)))

    def test_missing_story_label(self):
        text = VALID.replace("具体故事情节描述：\n", "")
        self.assertIn("story_label_count", codes(checker.check_text(text)))

    def test_clothing_noun_bare_exempt(self):
        # 裸服装名词（群像制服标识/道具提及）不判违规
        text = VALID.replace("明亮的堂屋里，", "两名黑西装守在门口，明亮的堂屋里，")
        self.assertNotIn("clothing_description", codes(checker.check_text(text)))

    def test_clothing_noun_with_wear_context_rejected(self):
        text = VALID.replace("明亮的堂屋里，", "他穿一件灰衬衫，明亮的堂屋里，")
        self.assertIn("clothing_description", codes(checker.check_text(text)))


if __name__ == "__main__":
    unittest.main()
