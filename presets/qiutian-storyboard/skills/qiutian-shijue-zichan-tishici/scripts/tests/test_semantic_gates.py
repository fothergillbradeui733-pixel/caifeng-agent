# -*- coding: utf-8 -*-

from __future__ import annotations

import sys
import tempfile
import unittest
import json
import subprocess
from pathlib import Path


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS_DIR))

from audit_source_coverage import audit, parse_project  # noqa: E402
from audit_handoff_suggestions import (  # noqa: E402
    audit as audit_handoff_suggestions,
    parse_handoff_suggestions,
)
from validate_assets import (  # noqa: E402
    APPEARANCES,
    GROUP_COUNT_RE,
    INDIVIDUAL_ALIAS_RE,
    validate,
)


LIBRARY = """# 回归_视觉资产库_V3

## 角色资产

### @主角_常态

类型：角色
使用状态：有效
替代资产：无
别名：无
出现集：全剧本
说明：无
文生图提示词：
```text
占位
```

## 群像资产

### @茶客群像

类型：群像
使用状态：有效
替代资产：无
别名：茶客甲
出现集：EP-001–EP-002
说明：无
文生图提示词：
```text
4 名 generic 群像，每个人都有完整、清晰、自然差异化的人脸
```

## 场景资产

### @茶馆

类型：场景
使用状态：有效
替代资产：无
别名：无
出现集：EP-001–EP-002
说明：无
文生图提示词：
```text
占位
```
"""


EP1 = """场次 01-1：内  茶馆  日
出场人物：茶客甲；幼年主角；小馆掌柜

茶客甲
（低声）
第一句。

幼年主角
（认真）
第一句。

小馆掌柜
（热情）
第一句。

小馆掌柜
（热情）
第二句。

小馆掌柜
（热情）
第三句。

小馆掌柜
（热情）
第四句。
"""


VISIBLE_LIBRARY = """# 人脸规则_视觉资产库_V1

## 风格设置

视觉风格：3DCG 国漫渲染（下游：qiutian-3dman-shipin-tishici 16:9 3D漫）

## 角色资产

### @谜客

类型：角色
使用状态：有效
替代资产：无
设定性别：剧情刻意未明示
外观呈现：中性
呈现性质：本貌
颜值定位：高辨识度耐看
特殊标志：无
别名：无
出现集：全剧本
说明：剧情明确保留性别悬念
文生图提示词：
```text
比例 16:9，3DCG 国漫渲染，角色设定图，纯白无缝背景，剧情保留性别悬念的中性人物，属于本貌，高辨识度耐看；清冷耐看的中性形象，面部轮廓舒展，眼尾平直；服装设计方向：符合旅人身份与日常场合，从沉静克制的性格出发，采用利落轮廓、低饱和色彩与垂顺材质；头部特写与三视图保持同一套服装和相同饰品。
```
谜客音色=（【青年】嗓音演绎，音色清润，音调偏中，标准普通话。）

## 群像资产

### @旅人群像

类型：群像
使用状态：有效
替代资产：无
别名：无
出现集：全剧本
说明：generic 背景群体
文生图提示词：
```text
比例 16:9，3DCG 国漫渲染，群像设定图，纯白无缝背景，4 名旅人 generic 男女混合群像组合站位，每个人都有完整、清晰、自然差异化的人脸，面孔保持 generic 身份，体型年龄自然变化。
```

## 角色音色表

```text
谜客音色=（【青年】嗓音演绎，音色清润，音调偏中，标准普通话。）
```

## 可引用 @资产清单

```text
@谜客（角色）
@旅人群像（群像）
```

## 图片文件名对照表

| @资产 | 建议图片文件名 |
|:--|:--|
| @谜客 | 谜客.png |
| @旅人群像 | 旅人群像.png |
"""

EP2 = """场次 02-1：内  茶馆  日
出场人物：茶客甲

茶客甲
（低声）
又一句。
"""


class SemanticGateTests(unittest.TestCase):
    def build_project(self, library_text: str = LIBRARY) -> tuple[tempfile.TemporaryDirectory, Path, Path]:
        temp = tempfile.TemporaryDirectory()
        root = Path(temp.name)
        scripts = root / "scripts"
        scripts.mkdir()
        (scripts / "EP-01.md").write_text(EP1, encoding="utf-8")
        (scripts / "EP-02.md").write_text(EP2, encoding="utf-8")
        library = root / "回归_视觉资产库_V3.md"
        library.write_text(library_text, encoding="utf-8")
        return temp, root, library

    def test_group_count_and_individual_alias_patterns(self) -> None:
        self.assertIsNotNone(GROUP_COUNT_RE.search("4 名弟子 generic 群像"))
        self.assertIsNone(GROUP_COUNT_RE.search("2 名掌柜 generic 群像"))
        self.assertIsNotNone(INDIVIDUAL_ALIAS_RE.search("茶客甲"))
        self.assertIsNotNone(INDIVIDUAL_ALIAS_RE.search("鸣泉宗三长老"))
        self.assertIsNone(INDIVIDUAL_ALIAS_RE.search("鸣泉宗六位长老"))

    def test_source_semantic_gates(self) -> None:
        temp, root, library = self.build_project()
        self.addCleanup(temp.cleanup)
        report = audit(library, root)
        joined = "\n".join(report.fails)
        self.assertIn("[COV6]", joined)
        self.assertIn("茶客甲", joined)
        self.assertIn("[COV7]", joined)
        self.assertIn("小馆掌柜", joined)
        self.assertIn("[COV8]", joined)
        self.assertIn("幼年主角", joined)

    def test_decision_ledger_resolves_single_episode_review(self) -> None:
        ledger = """

## 资产化决策台账

| 源标签 | 处理结果 | 目标/下游口径 | 依据 |
|:--|:--|:--|:--|
| 小馆掌柜 | 逐镜内联 | 逐镜描述 | 单场信息角色，无跨场定妆复用 |
"""
        temp, root, library = self.build_project(LIBRARY + ledger)
        self.addCleanup(temp.cleanup)
        report = audit(library, root)
        self.assertFalse(any("[COV7]" in item and "小馆掌柜" in item for item in report.fails))
        mapping = next(item for item in report.mappings if item["source_label"] == "小馆掌柜")
        self.assertEqual(mapping["card_type"], "逐镜内联")
        self.assertEqual(mapping["target"], "逐镜描述")

    def test_missing_activity_fields_are_failures(self) -> None:
        temp, _, library = self.build_project(
            LIBRARY.replace("使用状态：有效\n替代资产：无\n", "", 1)
        )
        self.addCleanup(temp.cleanup)
        report = validate(str(library))
        self.assertTrue(any("[V20]" in item and "使用状态" in item for item in report.fails))
        self.assertTrue(any("[V20]" in item and "替代资产" in item for item in report.fails))

    def test_generic_high_intensity_still_requires_decision(self) -> None:
        temp, root, library = self.build_project()
        self.addCleanup(temp.cleanup)
        ep1 = (root / "scripts" / "EP-01.md").read_text(encoding="utf-8")
        (root / "scripts" / "EP-01.md").write_text(
            ep1.replace("小馆掌柜", "北燕官员"),
            encoding="utf-8",
        )
        report = audit(library, root)
        self.assertTrue(any("[COV7]" in item and "北燕官员" in item for item in report.fails))

    def test_composite_speaker_is_split_and_scripts_path_is_accepted(self) -> None:
        temp, root, library = self.build_project()
        self.addCleanup(temp.cleanup)
        composite = """场次 03-1：内  茶馆  日
出场人物：主角；茶客甲

主角、茶客甲
（同声）
明白。
"""
        (root / "scripts" / "EP-03.md").write_text(composite, encoding="utf-8")
        _, speakers, _, _, labels, _, _ = parse_project(root / "scripts")
        self.assertIn("主角", speakers)
        self.assertIn("茶客甲", speakers)
        self.assertNotIn("主角、茶客甲", labels)
        report = audit(library, root / "scripts")
        self.assertFalse(any("[COV0]" in item for item in report.fails))

    def test_validate_json_is_machine_parseable(self) -> None:
        temp, _, library = self.build_project()
        self.addCleanup(temp.cleanup)
        process = subprocess.run(
            [
                sys.executable,
                str(SCRIPTS_DIR / "validate_assets.py"),
                str(library),
                "--json",
            ],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        payload = json.loads(process.stdout)
        self.assertIsInstance(payload, list)
        self.assertEqual(payload[0]["file"], str(library))

    def test_age_variant_mapping_reports_resolved_state(self) -> None:
        child_card = """

### @主角_幼年

类型：角色
使用状态：有效
替代资产：无
别名：无
出现集：仅 EP-001
说明：年龄状态
文生图提示词：
```text
占位
```
"""
        library_text = LIBRARY.replace("\n## 群像资产", child_card + "\n## 群像资产")
        temp, root, library = self.build_project(library_text)
        self.addCleanup(temp.cleanup)
        report = audit(library, root)
        mapping = next(item for item in report.mappings if item["source_label"] == "幼年主角")
        self.assertEqual(mapping["card_type"], "角色年龄状态")
        self.assertEqual(mapping["mapped_cards"], ["@主角_幼年"])
        self.assertFalse(any("[COV8]" in item for item in report.fails))

    def test_appearance_options_remove_intentional_blur(self) -> None:
        self.assertEqual(APPEARANCES, ("男性", "女性", "中性"))

    def test_concealed_gender_uses_neutral_visible_appearance(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            library = Path(temp_dir) / "人脸规则_视觉资产库_V1.md"
            library.write_text(VISIBLE_LIBRARY, encoding="utf-8")
            report = validate(str(library))
        identity_fails = [item for item in report.fails if "[V15]" in item]
        self.assertEqual(identity_fails, [])

    def test_legacy_blurred_appearance_reports_migration(self) -> None:
        legacy = VISIBLE_LIBRARY.replace("外观呈现：中性", "外观呈现：刻意模糊", 1)
        with tempfile.TemporaryDirectory() as temp_dir:
            library = Path(temp_dir) / "旧值_视觉资产库_V1.md"
            library.write_text(legacy, encoding="utf-8")
            report = validate(str(library))
        self.assertTrue(
            any("[V15]" in item and "迁移为「中性」" in item for item in report.fails)
        )

    def test_legacy_library_is_accepted_as_prev_after_migration(self) -> None:
        previous_text = VISIBLE_LIBRARY.replace(
            "外观呈现：中性", "外观呈现：刻意模糊", 1
        ).replace(
            "剧情保留性别悬念的中性人物",
            "性别刻意模糊的中性人物",
            1,
        )
        current_text = VISIBLE_LIBRARY.replace(
            "# 人脸规则_视觉资产库_V1",
            "# 人脸规则_视觉资产库_V2",
            1,
        ).replace(
            "## 角色资产",
            "## 变更记录\n\n- 补充：@谜客 外观呈现迁移（剧情证据）。\n\n## 角色资产",
            1,
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            previous = root / "人脸规则_视觉资产库_V1.md"
            current = root / "人脸规则_视觉资产库_V2.md"
            previous.write_text(previous_text, encoding="utf-8")
            current.write_text(current_text, encoding="utf-8")
            report = validate(str(current), prev_path=str(previous))
        self.assertFalse(any("[V7]" in item for item in report.fails))
        self.assertFalse(any("[V15]" in item for item in report.fails))
    def test_group_face_description_is_warning_only(self) -> None:
        missing_faces = VISIBLE_LIBRARY.replace(
            "每个人都有完整、清晰、自然差异化的人脸，面孔保持 generic 身份，",
            "成员以统一队列呈现，",
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            library = Path(temp_dir) / "群像提示_视觉资产库_V1.md"
            library.write_text(missing_faces, encoding="utf-8")
            report = validate(str(library))
        self.assertTrue(any("[V22]" in item for item in report.warns))
        self.assertFalse(any("[V22]" in item for item in report.fails))

    def test_group_clear_faces_and_source_exception_avoid_warning(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            clear_library = root / "清晰群像_视觉资产库_V1.md"
            clear_library.write_text(VISIBLE_LIBRARY, encoding="utf-8")
            clear_report = validate(str(clear_library))

            masked = VISIBLE_LIBRARY.replace(
                "说明：generic 背景群体",
                "说明：generic 背景群体；原著明确蒙面",
            ).replace(
                "每个人都有完整、清晰、自然差异化的人脸，面孔保持 generic 身份，",
                "原著明确蒙面，面具覆盖人脸，",
            )
            masked_library = root / "蒙面群像_视觉资产库_V1.md"
            masked_library.write_text(masked, encoding="utf-8")
            masked_report = validate(str(masked_library))

        self.assertFalse(any("[V22]" in item for item in clear_report.warns))
        self.assertFalse(any("[V22]" in item for item in masked_report.warns))

    def test_character_source_face_exception_preserves_original(self) -> None:
        masked = VISIBLE_LIBRARY.replace(
            "说明：剧情明确保留性别悬念",
            "说明：剧情明确保留性别悬念；原著明确蒙面",
        ).replace(
            "清冷耐看的中性形象，面部轮廓舒展，眼尾平直",
            "原著明确蒙面，面具覆盖面部",
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            library = Path(temp_dir) / "蒙面角色_视觉资产库_V1.md"
            library.write_text(masked, encoding="utf-8")
            report = validate(str(library))
        self.assertFalse(
            any("[V16]" in item and "脸部识别锚点" in item for item in report.fails)
        )
        self.assertFalse(
            any("[V16]" in item and "脸部审美簇" in item for item in report.warns)
        )
    def test_skill_md_uses_positive_instruction_style(self) -> None:
        skill_text = (SCRIPTS_DIR.parent / "SKILL.md").read_text(encoding="utf-8")
        banned = (
            "不得", "不要", "禁止", "不能", "不应", "不允许", "不以", "不用于",
            "不生成", "不重复", "不设", "不与", "不覆盖", "不猜", "不保留",
            "不写", "不污染", "不混入", "不列入", "不运行", "不把", "不留",
            "不手算", "避免",
        )
        found = [token for token in banned if token in skill_text]
        self.assertEqual(found, [])

    def test_handoff_suggestion_states_require_independent_complete_cards(self) -> None:
        handoff_text = """# 视觉事实交接

READY: INVALID
script_sha256: stale

## 全局实体索引

| 实体ID | 类型 | 剧本规范名 | 建议@集合 | 别名 | 出现集 | 源事实路径 |
|:--|:--|:--|:--|:--|:--|:--|
| CHR-001 | 角色 | 阿青 | @阿青_常服、@阿青_战损、@阿青_雨夜 | 青儿 | EP-01 | visual-assets/source-facts.md |

## 未解决项

- 哈希失配
"""
        card = """### @{name}

类型：角色
使用状态：有效
替代资产：无
别名：阿青
出现集：EP-01
说明：状态卡
文生图提示词：
```text
独立完整提示词
```
"""
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            handoff = root / "handoff.md"
            library = root / "测试_视觉资产库_V1.md"
            handoff.write_text(handoff_text, encoding="utf-8")
            suggestions = parse_handoff_suggestions(handoff)
            self.assertEqual(
                [item.suggested_name for item in suggestions],
                ["阿青_常服", "阿青_战损", "阿青_雨夜"],
            )

            library.write_text(
                "# 测试库\n\n" + card.format(name="阿青_常服") + card.format(name="阿青_战损"),
                encoding="utf-8",
            )
            missing_report = audit_handoff_suggestions(handoff, library)
            self.assertEqual(missing_report.missing_names, ["阿青_雨夜"])
            self.assertTrue(any("@阿青_雨夜" in item for item in missing_report.fails))

            library.write_text(
                "# 测试库\n\n"
                + card.format(name="阿青")
                + card.format(name="阿青_常服")
                + card.format(name="阿青_战损")
                + card.format(name="阿青_雨夜"),
                encoding="utf-8",
            )
            complete_report = audit_handoff_suggestions(handoff, library)
            self.assertEqual(complete_report.missing_names, [])
            self.assertEqual(complete_report.fails, [])

    def test_handoff_card_heading_alone_is_not_complete(self) -> None:
        handoff_text = """## 全局实体索引
| 实体ID | 类型 | 剧本规范名 | 建议@资产名 |
|:--|:--|:--|:--|
| PRP-001 | 道具 | 玉符 | @玉符_亮起态 |
"""
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            handoff = root / "handoff.md"
            library = root / "测试_视觉资产库_V1.md"
            handoff.write_text(handoff_text, encoding="utf-8")
            library.write_text("### @玉符_亮起态\n\n类型：道具\n", encoding="utf-8")
            report = audit_handoff_suggestions(handoff, library)
            self.assertEqual(report.missing_names, ["玉符_亮起态"])
            self.assertIn("玉符_亮起态", report.incomplete_cards)

    def test_handoff_state_episode_sets_must_match_per_episode_records(self) -> None:
        handoff_text = """## 全局实体索引
| 实体ID | 类型 | 剧本规范名 | 建议@集合 |
|:--|:--|:--|:--|
| CHR-001 | 角色 | 阿青 | @阿青_常服、@阿青_战损 |
"""
        episode_template = """## 人物出现
| 场次 | 源标签 | 实体ID | 资产化决策 | 状态维度 | 建议状态@ | 生效区间/切换锚 | 可见变化/证据 |
|:--|:--|:--|:--|:--|:--|:--|:--|
| {scene} | 阿青 | CHR-001 | 建卡 | {dimension} | @{name} | {anchor} | 当前剧本证据 |
"""
        card_template = """### @{name}

类型：角色
使用状态：有效
替代资产：无
别名：阿青
出现集：{episodes}
说明：状态卡
文生图提示词：
```text
独立完整提示词
```
"""
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            episodes_dir = root / "episodes"
            episodes_dir.mkdir()
            handoff = root / "handoff.md"
            library = root / "测试_视觉资产库_V1.md"
            handoff.write_text(handoff_text, encoding="utf-8")
            (episodes_dir / "EP-01.md").write_text(
                episode_template.format(
                    scene="01-1", dimension="服装", name="阿青_常服", anchor="仅 EP-01｜EP-01 场次 01-1"
                ),
                encoding="utf-8",
            )
            (episodes_dir / "EP-02.md").write_text(
                episode_template.format(
                    scene="02-1", dimension="伤势", name="阿青_战损", anchor="仅 EP-02｜EP-02 场次 02-1"
                ),
                encoding="utf-8",
            )
            (episodes_dir / "EP-03.md").write_text(
                episode_template.format(
                    scene="03-1", dimension="服装", name="阿青_常服", anchor="仅 EP-03｜EP-03 场次 03-1"
                ),
                encoding="utf-8",
            )

            wrong_library = (
                "# 测试库\n\n"
                + card_template.format(name="阿青_常服", episodes="EP-01–EP-03")
                + card_template.format(name="阿青_战损", episodes="EP-02")
                + "\n## 状态时间线总表\n\n"
                + "| 资产状态 | 维度 | 生效区间 | 切换锚（切换点/剧情依据） |\n"
                + "|:--|:--|:--|:--|\n"
                + "| @阿青_常服 | 服装 | EP-01–EP-03 | 场合切换 |\n"
                + "| @阿青_战损 | 伤势 | EP-02 | 受伤 |\n"
            )
            library.write_text(wrong_library, encoding="utf-8")
            wrong_report = audit_handoff_suggestions(handoff, library)
            self.assertIn("阿青_常服", wrong_report.state_episode_mismatches)
            self.assertIn("阿青_常服", wrong_report.timeline_episode_mismatches)
            self.assertTrue(any("[HSG4]" in item for item in wrong_report.fails))
            self.assertTrue(any("[HSG5]" in item for item in wrong_report.fails))

            library.write_text(
                wrong_library.replace("EP-01–EP-03", "EP-01、EP-03"),
                encoding="utf-8",
            )
            correct_report = audit_handoff_suggestions(handoff, library)
            self.assertEqual(correct_report.state_episode_mismatches, {})
            self.assertEqual(correct_report.timeline_episode_mismatches, {})
            self.assertEqual(correct_report.fails, [])

    def test_imported_composite_state_name_keeps_second_underscore(self) -> None:
        nested = VISIBLE_LIBRARY.replace("@谜客", "@谜客_面纱_左手符伤")
        with tempfile.TemporaryDirectory() as temp_dir:
            library = Path(temp_dir) / "复合状态_视觉资产库_V1.md"
            library.write_text(nested, encoding="utf-8")
            report = validate(str(library))
        self.assertFalse(any("[V5]" in item and "状态词" in item for item in report.fails))

if __name__ == "__main__":
    unittest.main()
