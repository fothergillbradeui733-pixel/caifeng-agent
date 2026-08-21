#!/usr/bin/env python3
"""Plan an idempotent full-season library build from a READY comic handoff."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from import_comic_handoff import import_handoff


CONTRACT_VERSION = "qiutian-shijue-zichan-tishici-fidelity-library/1.0"
LIBRARY_RE = re.compile(r"^(?P<name>.+)_视觉资产库_V(?P<version>\d+)\.md$")


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def metadata(text: str, key: str) -> str:
    match = re.search(rf"(?m)^{re.escape(key)}\s*[：:]\s*(.+?)\s*$", text)
    return match.group(1).strip() if match else ""


def safe_project_name(value: str) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*]', "_", value).strip().rstrip(".")
    return cleaned or "项目"


def library_versions(directory: Path, project_name: str) -> list[tuple[int, Path]]:
    result: list[tuple[int, Path]] = []
    if not directory.is_dir():
        return result
    for path in directory.glob(f"{project_name}_视觉资产库_V*.md"):
        match = LIBRARY_RE.fullmatch(path.name)
        if match and match.group("name") == project_name:
            result.append((int(match.group("version")), path))
    return sorted(result)


def provenance_matches(
    path: Path, payload: dict[str, object], style: str, pipeline: str
) -> bool:
    text = read_text(path)
    return all(
        (
            metadata(text, "生成契约版本") == CONTRACT_VERSION,
            metadata(text, "来源技能") == payload["source_skill"],
            metadata(text, "来源交接schema") == payload["schema_version"],
            metadata(text, "来源交接指纹") == payload["contract_fingerprint"],
            metadata(text, "建库视觉风格") == style,
            metadata(text, "建库下游管线") == pipeline,
        )
    )


def make_plan(
    handoff: Path,
    style: str,
    pipeline: str,
    output_dir: Path | None,
    upgrade: bool,
) -> dict[str, object]:
    payload = import_handoff(handoff, requested=None)
    project_root = Path(str(payload["project_root"]))
    project_name = safe_project_name(project_root.name)
    library_dir = (output_dir or project_root / "visual-assets" / "library").resolve()
    versions = library_versions(library_dir, project_name)
    status = "CREATE"
    reason = "no existing full-season library"
    version = 1

    if versions:
        version, latest = versions[-1]
        index = library_dir / f"{project_name}_资产索引_V{version}.md"
        if provenance_matches(latest, payload, style, pipeline):
            status = "REUSE" if index.is_file() else "REBUILD_INDEX"
            reason = "existing library provenance matches the current handoff, style, pipeline, and generation contract"
        elif upgrade:
            version += 1
            status = "CREATE"
            reason = "explicit upgrade requested for changed handoff, style, or generation contract"
        else:
            status = "BLOCKED"
            reason = "existing library provenance differs; rerun with explicit --upgrade to create the next version"

    library_path = library_dir / f"{project_name}_视觉资产库_V{version}.md"
    index_path = library_dir / f"{project_name}_资产索引_V{version}.md"
    cache_namespace = (
        ".comic-adapt-fidelity-cache"
        if payload["source_skill"] == "comic-adapt-fidelity"
        else ".comic-adapt-cache"
    )
    normalized_path = (
        project_root
        / cache_namespace
        / "qiutian-shijue-zichan-tishici"
        / "full-season-handoff.json"
    )
    return {
        "status": status,
        "reason": reason,
        "generation_contract": CONTRACT_VERSION,
        "source_skill": payload["source_skill"],
        "schema_version": payload["schema_version"],
        "contract_fingerprint": payload["contract_fingerprint"],
        "handoff_path": payload["handoff_path"],
        "project_root": str(project_root),
        "project_name": project_name,
        "coverage": payload["coverage"],
        "style": style,
        "pipeline": pipeline,
        "version": version,
        "library_dir": str(library_dir),
        "library_path": str(library_path),
        "index_path": str(index_path),
        "normalized_handoff_path": str(normalized_path),
        "candidate_card_count": len(payload["candidate_cards"]),
        "candidate_cards": payload["candidate_cards"],
        "normalized_handoff": payload,
    }


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def print_human(plan: dict[str, object]) -> None:
    print(f"FIDELITY-LIBRARY-PLAN {plan['status']}")
    print(f"reason={plan['reason']}")
    print(f"source_skill={plan['source_skill']}")
    print(f"schema={plan['schema_version']}")
    print(f"coverage={plan['coverage']}")
    print(f"contract_fingerprint={plan['contract_fingerprint']}")
    print(f"candidate_cards={plan['candidate_card_count']}")
    print(f"library={plan['library_path']}")
    print(f"index={plan['index_path']}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="校验 READY 交接并规划一次性正式资产库的版本、路径与幂等行为"
    )
    parser.add_argument("handoff", type=Path, help="visual-assets/handoff.md")
    parser.add_argument("--style", required=True, help="本次建库的视觉风格值")
    parser.add_argument("--pipeline", default="16:9 3D漫", help="下游管线标识")
    parser.add_argument("--output-dir", type=Path, help="覆盖默认 visual-assets/library")
    parser.add_argument("--upgrade", action="store_true", help="明确创建下一版本，不覆盖旧库")
    parser.add_argument("--output", type=Path, help="另存完整建库计划 JSON")
    parser.add_argument("--json", action="store_true", help="在标准输出打印 JSON")
    args = parser.parse_args()

    try:
        plan = make_plan(
            args.handoff.resolve(strict=True),
            args.style.strip(),
            args.pipeline.strip(),
            args.output_dir,
            args.upgrade,
        )
        normalized_path = Path(str(plan["normalized_handoff_path"]))
        write_json(normalized_path, plan["normalized_handoff"])
        if args.output:
            write_json(args.output.resolve(), plan)
    except (OSError, ValueError) as exc:
        print("FIDELITY-LIBRARY-PLAN FAIL")
        print(f"FAIL {exc}")
        return 1

    if args.json:
        print(json.dumps(plan, ensure_ascii=False, indent=2))
    else:
        print_human(plan)
    return 2 if plan["status"] == "BLOCKED" else 0


if __name__ == "__main__":
    sys.exit(main())
