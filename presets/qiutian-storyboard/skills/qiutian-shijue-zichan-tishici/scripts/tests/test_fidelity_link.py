# -*- coding: utf-8 -*-

from __future__ import annotations

import hashlib
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS_DIR))

from audit_fidelity_library import audit as audit_fidelity_library  # noqa: E402
from import_comic_handoff import import_handoff  # noqa: E402
from prepare_fidelity_library import (  # noqa: E402
    CONTRACT_VERSION,
    make_plan,
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(text).strip() + "\n", encoding="utf-8")


def make_project(root: Path, schema: str) -> Path:
    script = root / "scripts" / "EP-01.md"
    write(
        script,
        """
        # EP-01

        场次 01-1：内 房间 日
        出场人物：甲；路人
        △ 甲站在窗前，路人从背景经过。

        【本集正文完】
        """,
    )
    source = root / "visual-assets" / "source-facts.md"
    write(
        source,
        f"""
        # 视觉资产源事实

        schema_version: {schema}
        要求起始集：EP-01

        ## 人物与条件类型

        | 实体ID | 类型 | 剧本规范名 | 建议@资产名 | 别名 | 设定性别/年龄 | 原文稳定外观 | 特殊标志 | 服装事实 | 资产化倾向 | 证据 |
        |:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|:--|
        | CHR-001 | 角色 | 甲 | @甲 | 无 | 女｜青年 | 黑发 | 无 | 素色长袍 | 必须建卡 | EP-01 场次 01-1 |
        | GRP-001 | 群像 | 路人 | @路人 | 无 | 男女混合｜成年 | 普通路人 | 无 | 日常服装 | 逐镜内联 | EP-01 场次 01-1 |

        ## 场景

        | 实体ID | 场次头规范名 | 物理空间身份 | 建议@资产名 | 精确别名 | 世界层 | 固定结构/陈设/视觉符号 | 资产化倾向 | 证据 |
        |:--|:--|:--|:--|:--|:--|:--|:--|:--|
        | SCN-001 | 房间 | 普通室内 | @房间 | 无 | 现实层 | 窗户 | 逐镜内联 | EP-01 场次 01-1 |

        ## 道具

        | 实体ID | 剧本正式名 | 建议@资产名 | 别名 | 尺寸/材质/形状/颜色 | 文字/关键标记 | 初始持有人/状态 | 资产化倾向 | 证据 |
        |:--|:--|:--|:--|:--|:--|:--|:--|:--|

        ## 待确认

        - 无
        """,
    )
    episode = root / "visual-assets" / "episodes" / "EP-01.md"
    write(
        episode,
        f"""
        # EP-01 视觉资产交接

        schema_version: {schema}
        剧本路径：scripts/EP-01.md
        剧本SHA256：{sha256(script)}
        交接状态：READY

        ## 人物出现

        | 场次 | 源标签 | 实体ID | 资产化决策 | 状态维度 | 建议状态@ | 生效区间/切换锚 | 可见变化/证据 |
        |:--|:--|:--|:--|:--|:--|:--|:--|
        | 01-1 | 甲 | CHR-001 | 建卡 | — | @甲 | 全剧本｜EP-01 集首 | EP-01 场次 01-1｜甲站在窗前 |
        | 01-1 | 路人 | GRP-001 | 逐镜内联 | — | 无 | 全剧本｜EP-01 集首 | EP-01 场次 01-1｜路人从背景经过 |

        ## 场景出现

        | 场次 | 场次头原名 | 实体ID | 时段 | 资产化决策 | 建议状态@ | 状态/切换锚 | 可见结构证据 |
        |:--|:--|:--|:--|:--|:--|:--|:--|
        | 01-1 | 房间 | SCN-001 | 日 | 逐镜内联 | 无 | 基础｜EP-01 场次 01-1 | EP-01 场次 01-1｜窗户 |

        ## 道具出现

        | 场次 | 剧本标签 | 实体ID | 资产化决策 | 建议状态@ | 当前状态/持有人 | 状态变化/切换锚 | 近景/复用需求与证据 |
        |:--|:--|:--|:--|:--|:--|:--|:--|

        ## 未解决项

        - 无
        """,
    )
    handoff = root / "visual-assets" / "handoff.md"
    write(
        handoff,
        f"""
        # 视觉资产事实交接

        schema_version: {schema}
        交接状态：READY
        要求起始集：EP-01
        覆盖范围：EP-01
        源事实路径：visual-assets/source-facts.md
        源事实SHA256：{sha256(source)}
        生成时间：2026-01-01T00:00:00+08:00

        ## 分集交接文件

        | 集数 | 剧本路径 | 剧本SHA256 | 交接路径 | 交接SHA256 | 状态 |
        |:--|:--|:--|:--|:--|:--|
        | EP-01 | scripts/EP-01.md | {sha256(script)} | visual-assets/episodes/EP-01.md | {sha256(episode)} | READY |

        ## 全局实体索引

        | 实体ID | 类型 | 剧本规范名 | 建议@集合 | 别名 | 出现集 | 源事实路径 |
        |:--|:--|:--|:--|:--|:--|:--|
        | CHR-001 | 角色 | 甲 | @甲 | 无 | EP-01 | visual-assets/source-facts.md |
        | GRP-001 | 群像 | 路人 | 无 | 无 | EP-01 | visual-assets/source-facts.md |
        | SCN-001 | 场景 | 房间 | 无 | 无 | EP-01 | visual-assets/source-facts.md |

        ## 未解决项

        - 无
        """,
    )
    return handoff


def library_text(
    schema: str,
    fingerprint: str,
    style: str,
    pipeline: str = "16:9 3D漫",
    extra: bool = False,
) -> str:
    extra_card = ""
    if extra:
        extra_card = """

### @乙

类型：角色
使用状态：有效
替代资产：无
别名：无
出现集：EP-01
说明：无
文生图提示词：

```text
乙的完整提示词。
```
"""
    return f"""
# 测试_视觉资产库_V1

## 风格设置

视觉风格：{style}（下游：16:9 3D漫）

## 来源契约

生成契约版本：{CONTRACT_VERSION}
来源技能：comic-adapt-fidelity
来源交接schema：{schema}
来源交接指纹：{fingerprint}
来源交接路径：handoff.md
建库视觉风格：{style}
建库下游管线：{pipeline}
建库范围：EP-01
上游建卡数：1

## 角色资产

### @甲

类型：角色
使用状态：有效
替代资产：无
别名：无
出现集：EP-01
说明：无
文生图提示词：

```text
甲的完整提示词。
```
{extra_card}
"""


class FidelityLinkTests(unittest.TestCase):
    def test_importer_supports_both_schemas_and_filters_to_build_cards(self) -> None:
        cases = {
            "comic-adapt-fidelity-visual-handoff/1.0": "comic-adapt-fidelity",
            "comic-adapt-visual-handoff/1.0": "comic-adapt",
        }
        for schema, source_skill in cases.items():
            with self.subTest(schema=schema), tempfile.TemporaryDirectory() as temp_dir:
                handoff = make_project(Path(temp_dir), schema)
                payload = import_handoff(handoff, requested=None)
                self.assertEqual(source_skill, payload["source_skill"])
                self.assertEqual(["@甲"], [item["asset_name"] for item in payload["candidate_cards"]])
                self.assertEqual(["EP-01"], payload["candidate_cards"][0]["episodes"])

    def test_contract_fingerprint_ignores_generated_timestamp(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            handoff = make_project(
                Path(temp_dir), "comic-adapt-fidelity-visual-handoff/1.0"
            )
            first = import_handoff(handoff, requested=None)["contract_fingerprint"]
            handoff.write_text(
                handoff.read_text(encoding="utf-8").replace(
                    "2026-01-01T00:00:00+08:00", "2026-02-02T00:00:00+08:00"
                ),
                encoding="utf-8",
            )
            second = import_handoff(handoff, requested=None)["contract_fingerprint"]
            self.assertEqual(first, second)

    def test_plan_is_idempotent_and_requires_explicit_upgrade(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            handoff = make_project(root, "comic-adapt-fidelity-visual-handoff/1.0")
            payload = import_handoff(handoff, requested=None)
            plan = make_plan(handoff, "3DCG 国漫渲染", "16:9 3D漫", None, False)
            self.assertEqual("CREATE", plan["status"])
            library = Path(str(plan["library_path"]))
            write(
                library,
                library_text(
                    str(payload["schema_version"]),
                    str(payload["contract_fingerprint"]),
                    "3DCG 国漫渲染",
                ),
            )
            same = make_plan(handoff, "3DCG 国漫渲染", "16:9 3D漫", None, False)
            self.assertEqual("REBUILD_INDEX", same["status"])
            write(Path(str(same["index_path"])), "# index")
            reused = make_plan(handoff, "3DCG 国漫渲染", "16:9 3D漫", None, False)
            self.assertEqual("REUSE", reused["status"])
            pipeline_blocked = make_plan(
                handoff, "3DCG 国漫渲染", "真人短剧", None, False
            )
            self.assertEqual("BLOCKED", pipeline_blocked["status"])
            blocked = make_plan(handoff, "真人写实", "真人短剧", None, False)
            self.assertEqual("BLOCKED", blocked["status"])
            upgraded = make_plan(handoff, "真人写实", "真人短剧", None, True)
            self.assertEqual("CREATE", upgraded["status"])
            self.assertTrue(str(upgraded["library_path"]).endswith("_V2.md"))

    def test_exact_library_audit_rejects_extra_active_cards(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            handoff = make_project(root, "comic-adapt-fidelity-visual-handoff/1.0")
            payload = import_handoff(handoff, requested=None)
            library = root / "测试_视觉资产库_V1.md"
            write(
                library,
                library_text(
                    str(payload["schema_version"]),
                    str(payload["contract_fingerprint"]),
                    "3DCG 国漫渲染",
                ),
            )
            passed = audit_fidelity_library(handoff, library, "3DCG 国漫渲染")
            self.assertEqual("PASS", passed["status"])
            write(
                library,
                library_text(
                    str(payload["schema_version"]),
                    str(payload["contract_fingerprint"]),
                    "3DCG 国漫渲染",
                    extra=True,
                ),
            )
            failed = audit_fidelity_library(handoff, library, "3DCG 国漫渲染")
            self.assertEqual("FAIL", failed["status"])
            self.assertEqual(["乙"], failed["extra_active_cards"])


if __name__ == "__main__":
    unittest.main()
