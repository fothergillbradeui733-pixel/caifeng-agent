#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT = Path(__file__).with_name("check_spatial_continuity.py")


def load_checker():
    if not SCRIPT.exists():
        raise AssertionError(f"missing implementation: {SCRIPT.name}")
    spec = importlib.util.spec_from_file_location("check_spatial_continuity", SCRIPT)
    if spec is None or spec.loader is None:
        raise AssertionError("cannot load checker")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


VALID = """── Block 1 | 6s ──

📍 场景：@病房（日）
👤 出场：@林晚，@秦墨
🧭 起始空间状态：@林晚(坐在病床边，攥着病历)｜@秦墨(站在病房门口)

镜头 1 持续时间: 6s【@甲中景 + 缓慢推近】
画面描述：@秦墨从病房门口走到窗前，@林晚仍坐在病床边。

── Block 2 | 5s ──

📍 场景：@病房（日）
👤 出场：@林晚，@秦墨
🧭 起始空间状态：@林晚(坐在病床边，攥着病历)｜@秦墨(站在窗前)

镜头 1 持续时间: 5s【@甲近景 + 固定镜头】
画面描述：@秦墨背对窗户停住。
"""


class SpatialContinuityCheckerTest(unittest.TestCase):
    def test_valid_blocks_pass(self):
        checker = load_checker()
        self.assertEqual(checker.check_text(VALID), [])

    def test_legacy_spatial_state_label_still_passes(self):
        checker = load_checker()
        legacy = VALID.replace("起始空间状态", "空间状态")
        self.assertEqual(checker.check_text(legacy), [])

    def test_missing_spatial_state_fails(self):
        checker = load_checker()
        issues = checker.check_text("── Block 1 | 3s ──\n\n📍 场景：@走廊\n👤 出场：@秦墨")
        self.assertIn("spatial_state_missing", [issue.code for issue in issues])

    def test_invalid_posture_duplicate_state_and_nested_group_fail(self):
        checker = load_checker()
        bad = """### G1

── Block 1 | 6s ──

📍 场景：@病房（日）
👤 出场：@林晚，@秦墨
空间状态：@林晚(病床边，攥着病历)
🧭 起始空间状态：@秦墨(站在病房门口)
"""
        codes = [issue.code for issue in checker.check_text(bad)]
        self.assertIn("spatial_nested_group", codes)
        self.assertIn("spatial_state_duplicate", codes)
        self.assertIn("spatial_posture_missing", codes)

    def test_text_without_blocks_fails(self):
        checker = load_checker()
        issues = checker.check_text("只有普通说明，没有 Block。")
        self.assertEqual([issue.code for issue in issues], ["spatial_no_blocks"])


if __name__ == "__main__":
    unittest.main()
