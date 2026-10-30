"""Bounded public-playlist/media acquisition for the external validation client."""
import argparse
import json
import re
import subprocess
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

MAX_TRACK_BYTES = 32 * 1024 * 1024


def youtube_id(url):
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname not in {"www.youtube.com", "youtube.com"}:
        raise ValueError("Expected an HTTPS YouTube URL")
    identifier = parse_qs(parsed.query).get("v", [""])[0]
    if parsed.path != "/watch" or not re.fullmatch(r"[A-Za-z0-9_-]{11}", identifier):
        raise ValueError("Expected a YouTube watch URL")
    return identifier


def execute(extractor, arguments, timeout):
    command = [str(extractor), "--ignore-config", "--no-cache-dir", "--no-warnings",
               "--socket-timeout", "10", "--retries", "1", "--extractor-retries", "1"]
    result = subprocess.run(command + arguments, capture_output=True, timeout=timeout, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"Media extraction failed (exit {result.returncode})")
    if len(result.stdout) > 4 * 1024 * 1024:
        raise RuntimeError("Extractor metadata exceeds 4 MiB")
    return result.stdout


def playlist(extractor, url):
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or parsed.hostname not in {"www.youtube.com", "youtube.com"}
            or parsed.path != "/playlist" or not parse_qs(parsed.query).get("list")):
        raise ValueError("Expected an HTTPS YouTube playlist URL")
    data = json.loads(execute(extractor, ["--flat-playlist", "--dump-single-json", "--skip-download",
                                         "--playlist-end", "1001", url], 90))
    entries = data.get("entries", [])
    if not 1 <= len(entries) <= 1000:
        raise ValueError("Playlist must contain 1..1000 entries")
    tracks = []
    for entry in entries:
        identifier = entry.get("id", "")
        if re.fullmatch(r"[A-Za-z0-9_-]{11}", identifier):
            tracks.append(f"https://www.youtube.com/watch?v={identifier}")
    if not tracks:
        raise ValueError("No playable identifiers found")
    return {"title": data.get("title"), "tracks": tracks}


def download(extractor, url, directory):
    identifier = youtube_id(url)
    directory = directory.resolve(strict=True)
    target = directory / (identifier + ".webm")
    if target.exists():
        raise ValueError("Output already exists; use an empty client-owned media slot")
    try:
        execute(extractor, ["--no-playlist", "--no-progress", "--no-part", "--no-overwrites",
                            "--max-filesize", str(MAX_TRACK_BYTES), "--js-runtimes", "node",
                            "--format", "bestaudio[ext=webm][acodec=opus]",
                            "--output", str(target), url], 120)
        if not target.is_file() or not 0 < target.stat().st_size <= MAX_TRACK_BYTES:
            raise ValueError("Media unavailable or larger than 32 MiB")
    except BaseException:
        target.unlink(missing_ok=True)
        raise
    return {"path": str(target), "bytes": target.stat().st_size}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["playlist", "download"])
    parser.add_argument("url")
    parser.add_argument("--extractor", required=True, type=Path)
    parser.add_argument("--directory", type=Path)
    args = parser.parse_args()
    if args.action == "playlist":
        result = playlist(args.extractor, args.url)
    else:
        if args.directory is None:
            parser.error("download requires --directory")
        result = download(args.extractor, args.url, args.directory)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
