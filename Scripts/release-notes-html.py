#!/usr/bin/env python3
"""Converts Releases/release-notes/<version>.md into the HTML fragment Sparkle shows in its update dialog.

generate_appcast embeds a release-notes file that sits beside the archive with the same base name
(Trackglass-for-Mac-<version>.html next to Trackglass-for-Mac-<version>.dmg) as the item's <description>, as long as
the file is a fragment without <html>/<body> tags. Only the small Markdown subset the notes use is supported:
headings (#, ##, ###), "- " bullet lists, paragraphs, **bold**, `code` and [text](url) links.

Usage: Scripts/release-notes-html.py <input.md> <output.html>
"""
import html
import re
import sys


def inline(text: str) -> str:
    """Escapes the text, then applies code spans, links and bold (code first so its contents stay literal)."""
    parts = re.split(r"(`[^`]+`)", text)
    out = []
    for part in parts:
        if part.startswith("`") and part.endswith("`") and len(part) > 1:
            out.append("<code>" + html.escape(part[1:-1]) + "</code>")
            continue
        escaped = html.escape(part)
        escaped = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)",
                         lambda m: '<a href="' + m.group(2) + '">' + m.group(1) + "</a>", escaped)
        escaped = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
        out.append(escaped)
    return "".join(out)


def convert(markdown: str) -> str:
    blocks = []
    paragraph = []
    items = []

    def flush_paragraph():
        if paragraph:
            blocks.append("<p>" + inline(" ".join(paragraph)) + "</p>")
            paragraph.clear()

    def flush_items():
        if items:
            blocks.append("<ul>\n" + "\n".join("  <li>" + inline(i) + "</li>" for i in items) + "\n</ul>")
            items.clear()

    for raw in markdown.splitlines():
        line = raw.rstrip()
        heading = re.match(r"^(#{1,3})\s+(.*)$", line)
        if heading:
            flush_paragraph(); flush_items()
            level = len(heading.group(1)) + 1   # the dialog already shows the app name as its title
            blocks.append(f"<h{level}>" + inline(heading.group(2)) + f"</h{level}>")
        elif line.startswith("- ") or line.startswith("* "):
            flush_paragraph()
            items.append(line[2:].strip())
        elif line.startswith("  ") and items and line.strip():
            items[-1] += " " + line.strip()   # continuation of a wrapped bullet
        elif not line.strip():
            flush_paragraph(); flush_items()
        else:
            flush_items()
            paragraph.append(line.strip())
    flush_paragraph(); flush_items()
    return "\n".join(blocks) + "\n"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as source:
        fragment = convert(source.read())
    with open(sys.argv[2], "w", encoding="utf-8") as target:
        target.write(fragment)
    return 0


if __name__ == "__main__":
    sys.exit(main())
