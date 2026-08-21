# -*- coding: utf-8 -*-
"""从视觉资产库确定性生成同版本轻量资产索引。"""

from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile
from pathlib import Path


if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")


REQUIRED_SECTIONS = ("可引用 @资产清单", "角色音色表")
PRELUDE_SECTIONS = ("来源契约",)
OPTIONAL_SECTIONS = ("技能特效登记表", "状态时间线总表", "资产兼容映射表")


def read_utf8(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError as exc:
        raise ValueError(f"文件不是 UTF-8：{path}") from exc


def section_map(text: str) -> dict[str, str]:
    """返回二级章节标题到完整章节文本的映射。"""
    matches = list(re.finditer(r"(?m)^##\s+([^\r\n]+?)\s*$", text))
    result: dict[str, str] = {}
    for index, match in enumerate(matches):
        start = match.start()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        title = match.group(1).strip()
        result[title] = text[start:end].rstrip()
    return result


def find_section(sections: dict[str, str], wanted: str) -> str | None:
    if wanted in sections:
        return sections[wanted]
    for title, body in sections.items():
        if wanted in title:
            return body
    return None


def derive_names(library: Path) -> tuple[str, int, Path]:
    match = re.fullmatch(r"(.+)_视觉资产库_V(\d+)\.md", library.name)
    if not match:
        raise ValueError("资产库文件名须为 `{剧本名}_视觉资产库_V{N}.md`")
    project = match.group(1)
    version = int(match.group(2))
    output = library.with_name(f"{project}_资产索引_V{version}.md")
    return project, version, output


def build_index(library: Path) -> tuple[str, Path, list[str]]:
    text = read_utf8(library)
    project, version, default_output = derive_names(library)
    sections = section_map(text)

    style_match = re.search(r"(?m)^视觉风格\s*[:：]\s*(.+?)\s*$", text)
    if not style_match:
        raise ValueError("资产库缺少 `视觉风格：` 行")
    style_line = style_match.group(0).strip()

    selected: list[str] = []
    missing: list[str] = []
    for title in PRELUDE_SECTIONS:
        body = find_section(sections, title)
        if body is not None:
            selected.append(body)
    for title in REQUIRED_SECTIONS:
        body = find_section(sections, title)
        if body is None:
            missing.append(title)
        else:
            selected.append(body)
    if missing:
        raise ValueError("资产库缺少必需章节：" + "、".join(missing))

    for title in OPTIONAL_SECTIONS:
        body = find_section(sections, title)
        if body is not None:
            selected.append(body)

    note = (
        f"> 与 {project}_视觉资产库_V{version}.md 同版本；"
        "不含文生图提示词正文。"
    )
    chunks = [
        f"# {project}_资产索引_V{version}",
        note,
        "## 风格设置\n\n" + style_line,
        *selected,
    ]
    index_text = "\n\n".join(chunk.rstrip() for chunk in chunks) + "\n"
    copied_titles = [re.sub(r"^##\s+", "", body.splitlines()[0]).strip() for body in selected]
    return index_text, default_output, copied_titles


def atomic_write(path: Path, text: str, force: bool) -> None:
    if path.exists() and not force:
        raise FileExistsError(f"索引已存在；确认覆盖时加 --force：{path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="\n",
        delete=False,
        dir=path.parent,
        prefix=path.name + ".",
        suffix=".tmp",
    )
    temp_name = handle.name
    try:
        with handle:
            handle.write(text)
        os.replace(temp_name, path)
    except Exception:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser(
        description="从视觉资产库逐字摘录关键区块，生成同版本轻量资产索引。"
    )
    parser.add_argument("library", type=Path, help="视觉资产库 Markdown 路径")
    parser.add_argument("--output", type=Path, help="索引输出路径；默认与库同目录")
    parser.add_argument("--force", action="store_true", help="允许覆盖已有索引")
    args = parser.parse_args()

    try:
        library = args.library.resolve(strict=True)
        index_text, default_output, copied = build_index(library)
        output = (args.output or default_output).resolve()
        if output == library:
            raise ValueError("索引输出路径不得与资产库相同")
        atomic_write(output, index_text, args.force)
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print(f"INDEX: {output}")
    print("SECTIONS: 风格设置、" + "、".join(copied))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
