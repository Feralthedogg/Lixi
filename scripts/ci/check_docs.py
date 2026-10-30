"""Validate tracked Markdown and examples without executing example commands."""

from __future__ import annotations

import html
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[2]
FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})(.*)$")
LINK = re.compile(r"!?\[[^\]\n]*\]\((<[^>]+>|[^\s)]+)(?:\s+\"[^\"]*\")?\)")
IMAGE = re.compile(r"<img\b[^>]*\bsrc=[\"']([^\"']+)[\"']", re.IGNORECASE)
HEADING = re.compile(r"^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$")


def split_blocks(text: str) -> tuple[str, list[tuple[str, str, int]]]:
    prose: list[str] = []
    blocks: list[tuple[str, str, int]] = []
    opening: tuple[str, str, int] | None = None
    body: list[str] = []
    for number, line in enumerate(text.splitlines(), 1):
        match = FENCE.match(line)
        if opening is None:
            if match:
                opening = (match[1], match[2].strip(), number)
                body = []
            else:
                prose.append(line)
        elif match and match[1][0] == opening[0][0] and len(match[1]) >= len(opening[0]) and not match[2].strip():
            blocks.append((opening[1], "\n".join(body) + "\n", opening[2]))
            opening = None
        else:
            body.append(line)
    if opening:
        raise ValueError(f"line {opening[2]}: unclosed code fence")
    return "\n".join(prose), blocks


def heading_ids(text: str) -> set[str]:
    prose, _ = split_blocks(text)
    result: set[str] = set()
    counts: dict[str, int] = {}
    for line in prose.splitlines():
        match = HEADING.match(line)
        if not match:
            continue
        title = html.unescape(re.sub(r"<[^>]+>", "", match[1]))
        title = LINK.sub(lambda item: item[0].split("]", 1)[0].lstrip("!["), title)
        slug = re.sub(r"[^\w -]", "", title.lower()).replace(" ", "-")
        count = counts.get(slug, 0)
        result.add(slug if count == 0 else f"{slug}-{count}")
        counts[slug] = count + 1
    result.update(re.findall(r"<(?:a|h[1-6])\b[^>]*(?:id|name)=[\"']([^\"']+)[\"']", prose))
    return result


def check_link(path: Path, link: str, cache: dict[Path, set[str]]) -> bool:
    url = urlsplit(html.unescape(link.strip("<>")))
    if url.scheme or url.netloc:
        return False
    target = (path.parent / unquote(url.path)).resolve() if url.path else path
    if not target.is_relative_to(ROOT) or not target.is_file():
        raise ValueError(f"missing repository file: {link}")
    if url.fragment and target.suffix == ".md":
        if target not in cache:
            cache[target] = heading_ids(target.read_text(encoding="utf-8"))
        if unquote(url.fragment) not in cache[target]:
            raise ValueError(f"missing heading: {link}")
    return True


def main() -> int:
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT)
    paths = [ROOT / name.decode() for name in tracked.split(b"\0") if name.endswith(b".md")]
    if not paths:
        raise ValueError("no tracked Markdown files")
    errors: list[str] = []
    cache: dict[Path, set[str]] = {}
    links = shells = json_blocks = 0
    for path in paths:
        try:
            prose, blocks = split_blocks(path.read_text(encoding="utf-8"))
            for link in [match[1] for match in LINK.finditer(prose)] + IMAGE.findall(prose):
                links += check_link(path, link, cache)
            for language, source, number in blocks:
                if language == "json":
                    json.loads(source)
                    json_blocks += 1
                elif language in {"sh", "bash"}:
                    result = subprocess.run(["bash", "-n"], input=source, text=True, capture_output=True, check=False)
                    if result.returncode:
                        raise ValueError(f"line {number}: invalid shell example: {result.stderr.strip()}")
                    shells += 1
        except (OSError, ValueError) as error:
            errors.append(f"{path.relative_to(ROOT)}: {error}")
    for path in (ROOT / "image").glob("*.svg"):
        try:
            ElementTree.parse(path)
        except (OSError, ElementTree.ParseError) as error:
            errors.append(f"{path.relative_to(ROOT)}: {error}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Documentation OK: {len(paths)} files, {links} local links, {shells} shell examples, {json_blocks} JSON examples")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
