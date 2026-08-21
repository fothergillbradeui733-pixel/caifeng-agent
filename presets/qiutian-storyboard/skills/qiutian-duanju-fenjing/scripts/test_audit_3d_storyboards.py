from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

import audit_3d_storyboards as audit


def episode_text() -> str:
    return f"""《测试》第1集
剧情摘要：测试。
导演/编剧处理：测试。
节奏走向：测试。
本集调用模块：V10。
本集新增资产：无。
抽卡/资产参考基调：测试。
本集使用人物/资产索引：@甲。

── Block 1 | 4s ──

📍 场景：@庭院（晨）
👤 出场：@甲
🧭 起始空间状态：@甲(站在门口)
视频整体基调：横屏3D漫剧，无字幕、无水印。

镜头 1 持续时间: 4s【@甲中景 + 固定镜头】
镜头角度：平视
画面描述：@甲站在门口，双手垂在身侧。

{audit.DEFAULT_BAN}

本集总时长：约4秒
遗留信息：
最后一帧画面：@甲站在门口。
未解决悬念：无。
人物状态：@甲站立。
模块延续：V10。
OS表现设定：未启用。
继续？
"""


class ManjuAuditContractTests(unittest.TestCase):
    def audit_issues(self, text: str) -> set[str]:
        with tempfile.TemporaryDirectory() as temp_dir:
            target = Path(temp_dir) / "测试-第1集-分镜.txt"
            target.write_text(text, encoding="utf-8")
            result = audit.audit_file(target, "", audit.DEFAULT_BAN, set())
        return {issue["kind"] for issue in result["issues"]}

    def test_new_start_state_and_angle_pass(self):
        self.assertEqual(set(), self.audit_issues(episode_text()))

    def test_legacy_state_and_missing_angle_fail(self):
        text = episode_text().replace("🧭 起始空间状态：", "🧭 空间状态：")
        text = text.replace("镜头角度：平视\n", "")
        issues = self.audit_issues(text)
        self.assertIn("start_state_not_exact_once", issues)
        self.assertIn("angle_not_exact_once", issues)

    def test_subjectless_lens_size_fails(self):
        text = episode_text().replace("【@甲中景 + 固定镜头】", "【中景 + 固定镜头】")
        self.assertIn("lens_subject_missing", self.audit_issues(text))

    def test_public_risk_line_fails(self):
        text = episode_text().replace(
            audit.DEFAULT_BAN,
            audit.DEFAULT_BAN + "\n🎲 抽卡风险：🟢 低风险。",
        )
        self.assertIn("unexpected_public_risk", self.audit_issues(text))


if __name__ == "__main__":
    unittest.main()
