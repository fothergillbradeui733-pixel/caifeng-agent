#!/usr/bin/env python3
"""Inventory script sources and safely extract readable text from ZIP/DOCX inputs."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import zipfile
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath
from xml.etree import ElementTree


TEXT_EXTENSIONS = {
    ".txt",
    ".md",
    ".markdown",
    ".json",
    ".csv",
    ".tsv",
    ".srt",
    ".ass",
    ".xml",
    ".html",
    ".htm",
}
ENCODINGS = ("utf-8-sig", "gb18030", "utf-16", "big5")


@dataclass
class Record:
    source: str
    member: str
    extension: str
    bytes: int
    sha256: str
    kind: str
    readable: bool
    characters: int
    extracted_path: str
    note: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Inventory short-drama source files")
    parser.add_argument("inputs", nargs="+", help="ZIP, DOCX, text file, or directory paths")
    parser.add_argument("--output", required=True, help="New or empty report directory")
    parser.add_argument("--max-bytes", type=int, default=20 * 1024 * 1024)
    return parser.parse_args()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def decode_text(data: bytes) -> tuple[str | None, str]:
    for encoding in ENCODINGS:
        try:
            return data.decode(encoding), encoding
        except UnicodeDecodeError:
            continue
    return None, ""


def docx_text(data: bytes) -> str:
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        xml = archive.read("word/document.xml")
    root = ElementTree.fromstring(xml)
    namespace = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
    paragraphs: list[str] = []
    for paragraph in root.iter(namespace + "p"):
        runs = [node.text or "" for node in paragraph.iter(namespace + "t")]
        if runs:
            paragraphs.append("".join(runs))
    return "\n".join(paragraphs)


def safe_parts(member: str) -> list[str]:
    path = PurePosixPath(member.replace("\\", "/"))
    parts: list[str] = []
    for part in path.parts:
        if part in ("", ".", "..", "/"):
            continue
        cleaned = re.sub(r"[<>:\"/\\|?*\x00-\x1f]", "_", part).rstrip(". ")
        parts.append(cleaned or "unnamed")
    return parts or ["unnamed"]


def unique_destination(base: Path, parts: list[str], extension: str, digest: str) -> Path:
    destination = base.joinpath(*parts)
    if extension == ".docx":
        destination = destination.with_suffix(".txt")
    if not destination.exists():
        return destination
    return destination.with_name(f"{destination.stem}_{digest[:8]}{destination.suffix}")


def inspect_blob(
    source: Path,
    member: str,
    data: bytes,
    output_base: Path,
    max_bytes: int,
) -> Record:
    extension = Path(member).suffix.lower()
    digest = sha256_bytes(data)
    kind = "binary"
    note = "unsupported binary; use the matching document/PDF/video skill"
    text: str | None = None

    if len(data) > max_bytes:
        note = f"skipped readable extraction: exceeds max bytes {max_bytes}"
    elif extension in TEXT_EXTENSIONS:
        text, encoding = decode_text(data)
        kind = "text"
        note = f"decoded as {encoding}" if text is not None else "text encoding not recognized"
    elif extension == ".docx":
        kind = "docx"
        try:
            text = docx_text(data)
            note = "extracted from word/document.xml"
        except (KeyError, zipfile.BadZipFile, ElementTree.ParseError) as exc:
            note = f"DOCX extraction failed: {exc}"

    extracted = ""
    if text is not None:
        root = output_base / "extracted-text" / safe_parts(source.stem)[0]
        destination = unique_destination(root, safe_parts(member), extension, digest)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(text, encoding="utf-8", newline="\n")
        extracted = str(destination.resolve())

    return Record(
        source=str(source.resolve()),
        member=member,
        extension=extension or "(none)",
        bytes=len(data),
        sha256=digest,
        kind=kind,
        readable=text is not None,
        characters=len(text) if text is not None else 0,
        extracted_path=extracted,
        note=note,
    )


def inspect_zip(source: Path, output: Path, max_bytes: int) -> list[Record]:
    records: list[Record] = []
    with zipfile.ZipFile(source) as archive:
        for info in sorted(archive.infolist(), key=lambda item: item.filename):
            if info.is_dir():
                continue
            if info.file_size > max_bytes:
                records.append(
                    Record(
                        source=str(source.resolve()),
                        member=info.filename,
                        extension=Path(info.filename).suffix.lower() or "(none)",
                        bytes=info.file_size,
                        sha256="",
                        kind="skipped",
                        readable=False,
                        characters=0,
                        extracted_path="",
                        note=f"member exceeds max bytes {max_bytes}",
                    )
                )
                continue
            records.append(inspect_blob(source, info.filename, archive.read(info), output, max_bytes))
    return records


def inspect_file(source: Path, output: Path, max_bytes: int, member: str | None = None) -> list[Record]:
    if source.suffix.lower() == ".zip":
        return inspect_zip(source, output, max_bytes)
    data = source.read_bytes()
    return [inspect_blob(source, member or source.name, data, output, max_bytes)]


def iter_inputs(paths: list[str]) -> list[Path]:
    files: list[Path] = []
    for raw in paths:
        path = Path(raw).expanduser().resolve()
        if not path.exists():
            raise SystemExit(f"Input does not exist: {path}")
        if path.is_dir():
            files.extend(sorted(item for item in path.rglob("*") if item.is_file()))
        else:
            files.append(path)
    return files


def write_reports(output: Path, records: list[Record]) -> None:
    payload = {
        "schema_version": "cn-shortdrama-source-inventory/1.0",
        "files": len(records),
        "readable": sum(1 for record in records if record.readable),
        "records": [asdict(record) for record in records],
    }
    (output / "source-inventory.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )

    lines = [
        "# 参考素材盘点",
        "",
        f"- 文件/成员：{payload['files']}",
        f"- 已提取可读文本：{payload['readable']}",
        "",
        "| 来源 | 成员 | 类型 | 字节 | 字符 | SHA256 | 提取结果/说明 |",
        "|:--|:--|:--|--:|--:|:--|:--|",
    ]
    for record in records:
        source = Path(record.source).name.replace("|", "\\|")
        member = record.member.replace("|", "\\|")
        note = (record.extracted_path or record.note).replace("|", "\\|")
        lines.append(
            f"| {source} | {member} | {record.kind} | {record.bytes} | {record.characters} | "
            f"`{record.sha256 or '未计算'}` | {note} |"
        )
    (output / "source-inventory.md").write_text(
        "\n".join(lines) + "\n", encoding="utf-8", newline="\n"
    )


def main() -> int:
    args = parse_args()
    if args.max_bytes < 1:
        raise SystemExit("--max-bytes must be positive")
    output = Path(args.output).expanduser().resolve()
    if output.exists() and not output.is_dir():
        raise SystemExit(f"Output exists and is not a directory: {output}")
    if output.exists() and any(output.iterdir()):
        raise SystemExit(f"Refusing to overwrite non-empty output directory: {output}")
    output.mkdir(parents=True, exist_ok=True)

    records: list[Record] = []
    for source in iter_inputs(args.inputs):
        try:
            records.extend(inspect_file(source, output, args.max_bytes))
        except (OSError, zipfile.BadZipFile) as exc:
            records.append(
                Record(
                    source=str(source),
                    member=source.name,
                    extension=source.suffix.lower() or "(none)",
                    bytes=source.stat().st_size if source.exists() else 0,
                    sha256="",
                    kind="error",
                    readable=False,
                    characters=0,
                    extracted_path="",
                    note=str(exc),
                )
            )
    write_reports(output, records)
    readable = sum(1 for record in records if record.readable)
    print(f"INVENTORY-PASS records={len(records)}; readable={readable}; output={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
