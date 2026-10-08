#!/usr/bin/env python3
"""Check that every relative link in the repo's Markdown files resolves.

    python3 scripts/check_links.py

Checks [text](path) and [text](path#anchor) links that point inside the repo:
the file/directory must exist, and for links into a Markdown file the
#anchor must match one of its headings (GitHub's slug rules). External
links (http/https/mailto) are not fetched.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LINK_RE = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
FENCE_RE = re.compile(r"^\s*(```|~~~)")


def slugify(heading: str) -> str:
    """GitHub-style anchor for a heading."""
    text = re.sub(r"<[^>]+>", "", heading)          # strip inline HTML
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)  # links -> text
    text = text.strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)             # drop punctuation (keeps _ and -)
    return text.replace(" ", "-")


def anchors_of(path: str, cache: dict) -> set:
    if path not in cache:
        slugs, counts, in_fence = set(), {}, False
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if FENCE_RE.match(line):
                    in_fence = not in_fence
                    continue
                m = None if in_fence else re.match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
                if m:
                    base = slugify(m.group(1))
                    n = counts.get(base, 0)
                    slugs.add(base if n == 0 else f"{base}-{n}")
                    counts[base] = n + 1
        cache[path] = slugs
    return cache[path]


def main() -> int:
    errors, cache, checked = [], {}, 0
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in (".git", ".bin", "node_modules")]
        for name in filenames:
            if not name.endswith(".md"):
                continue
            src = os.path.join(dirpath, name)
            in_fence = False
            with open(src, encoding="utf-8") as fh:
                for lineno, line in enumerate(fh, 1):
                    if FENCE_RE.match(line):
                        in_fence = not in_fence
                        continue
                    if in_fence:
                        continue
                    for target in LINK_RE.findall(line):
                        if re.match(r"^[a-z][a-z0-9+.-]*:", target):  # http:, https:, mailto:
                            continue
                        checked += 1
                        path_part, _, anchor = target.partition("#")
                        dest = src if not path_part else os.path.normpath(os.path.join(dirpath, path_part))
                        rel = os.path.relpath(src, ROOT)
                        if not os.path.exists(dest):
                            errors.append(f"{rel}:{lineno}: missing target {target}")
                        elif anchor and dest.endswith(".md") and anchor not in anchors_of(dest, cache):
                            errors.append(f"{rel}:{lineno}: missing anchor #{anchor} in {os.path.relpath(dest, ROOT)}")
    for e in errors:
        print(e)
    print(f"{checked} relative links checked, {len(errors)} broken")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
