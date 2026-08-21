#!/usr/bin/env python3
"""Initialize a Chinese short-drama production project from bundled templates."""

from __future__ import annotations

import argparse
import json
from datetime import datetime
from pathlib import Path


SCHEMA_VERSION = "cn-shortdrama-project/1.0"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a non-destructive short-drama project scaffold."
    )
    parser.add_argument("--path", required=True, help="New or empty project directory")
    parser.add_argument("--title", required=True, help="Drama title without book-title marks")
    parser.add_argument("--episodes", type=int, default=60)
    parser.add_argument("--mode", default="竖屏真人短剧")
    parser.add_argument("--duration-seconds", type=int, default=120)
    parser.add_argument("--scene-min", type=int, default=2)
    parser.add_argument("--scene-max", type=int, default=4)
    parser.add_argument("--content-chars-min", type=int, default=800)
    parser.add_argument("--content-chars-max", type=int, default=1200)
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if not 1 <= args.episodes <= 999:
        raise SystemExit("--episodes must be between 1 and 999")
    if not 30 <= args.duration_seconds <= 600:
        raise SystemExit("--duration-seconds must be between 30 and 600")
    if args.scene_min < 1 or args.scene_max < args.scene_min:
        raise SystemExit("scene range is invalid")
    if args.content_chars_min < 1 or args.content_chars_max < args.content_chars_min:
        raise SystemExit("content character range is invalid")
    if not args.title.strip():
        raise SystemExit("--title cannot be empty")


def ensure_empty_target(target: Path) -> None:
    if target.exists() and not target.is_dir():
        raise SystemExit(f"Target exists and is not a directory: {target}")
    if target.exists() and any(target.iterdir()):
        raise SystemExit(f"Refusing to overwrite non-empty directory: {target}")
    target.mkdir(parents=True, exist_ok=True)


def render_templates(template_root: Path, target: Path, replacements: dict[str, str]) -> int:
    if not template_root.is_dir():
        raise SystemExit(f"Template directory is missing: {template_root}")

    written = 0
    for source in sorted(template_root.rglob("*")):
        relative = source.relative_to(template_root)
        destination = target / relative
        if source.is_dir():
            destination.mkdir(parents=True, exist_ok=True)
            continue

        text = source.read_text(encoding="utf-8")
        for placeholder, value in replacements.items():
            text = text.replace("{{" + placeholder + "}}", value)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(text, encoding="utf-8", newline="\n")
        written += 1
    return written


def main() -> int:
    args = parse_args()
    validate_args(args)

    target = Path(args.path).expanduser().resolve()
    ensure_empty_target(target)

    skill_root = Path(__file__).resolve().parents[1]
    template_root = skill_root / "assets" / "project-template"
    created_at = datetime.now().astimezone().isoformat(timespec="seconds")
    replacements = {
        "TITLE": args.title.strip(),
        "EPISODES": str(args.episodes),
        "MODE": args.mode.strip(),
        "DURATION_SECONDS": str(args.duration_seconds),
        "SCENE_MIN": str(args.scene_min),
        "SCENE_MAX": str(args.scene_max),
        "CONTENT_CHARS_MIN": str(args.content_chars_min),
        "CONTENT_CHARS_MAX": str(args.content_chars_max),
        "CREATED_AT": created_at,
    }
    template_files = render_templates(template_root, target, replacements)

    for relative in ("scripts", "visual-assets/episodes", "qa", "asset-package"):
        (target / relative).mkdir(parents=True, exist_ok=True)

    config = {
        "schema_version": SCHEMA_VERSION,
        "title": args.title.strip(),
        "episodes": args.episodes,
        "mode": args.mode.strip(),
        "duration_seconds": args.duration_seconds,
        "scene_min": args.scene_min,
        "scene_max": args.scene_max,
        "content_chars_min": args.content_chars_min,
        "content_chars_max": args.content_chars_max,
        "dialogue_chars_max": 35,
        "require_ledger": True,
        "require_visual_ready": False,
        "require_body_assets_in_header": False,
        "created_at": created_at,
    }
    (target / "project.json").write_text(
        json.dumps(config, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )

    print(f"INIT-PASS project={target}")
    print(f"title={config['title']}; episodes={config['episodes']}; templates={template_files}")
    print("next=Complete the Socratic interview, validate PROJECT-BRIEF.md, then lock STORY-BIBLE.md and plot-map.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
