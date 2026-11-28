#!/usr/bin/env python3
"""Check repository-relative Markdown links and heading anchors."""
from collections import Counter
from pathlib import Path, PurePosixPath
import posixpath
import re
import subprocess
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[2]
FENCE = re.compile(r'^\s{0,3}(`{3,}|~{3,})(.*)$')
HEADING = re.compile(r'^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$')
LINK = re.compile(r'\]\(\s*(?:<([^>]+)>|([^\s)]+))')
ANCHOR = re.compile(r"""<(?:a|span)\b[^>]*\b(?:id|name)=["']([^"']+)["']""")


def content_lines(document):
    fence = None
    for number, line in enumerate(document.splitlines(), 1):
        match = FENCE.match(line)
        if fence:
            if match and match[1][0] == fence[0] and len(match[1]) >= len(fence) and not match[2].strip():
                fence = None
        elif match:
            fence = match[1]
        else:
            yield number, line


def anchors(lines):
    headings = Counter()
    result = set()
    for _, line in lines:
        result.update(ANCHOR.findall(line))
        heading = HEADING.match(line)
        if heading:
            title = re.sub(r'[^\w\- ]', '', heading[1].lower()).replace(' ', '-')
            occurrence = headings[title]
            result.add(f'{title}-{occurrence}' if occurrence else title)
            headings[title] += 1
    return result


def main():
    entries = subprocess.check_output(
        ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT
    ).decode('utf-8').split('\0')
    files = {name for name in entries if name and (ROOT / name).is_file()}
    directories = {parent.as_posix() for name in files for parent in PurePosixPath(name).parents}
    documents = {
        name: list(content_lines((ROOT / name).read_text(encoding='utf-8-sig')))
        for name in sorted(files) if name.endswith('.md')
    }
    document_anchors = {name: anchors(lines) for name, lines in documents.items()}
    failures = []
    for name, lines in documents.items():
        for number, line in lines:
            for angle_target, bare_target in LINK.findall(line):
                target = angle_target or bare_target
                url = urlsplit(target)
                if url.scheme or url.netloc or not (url.path or url.fragment):
                    continue
                path = unquote(url.path)
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), path)) if path else name
                if resolved not in files and resolved not in directories:
                    failures.append(f'{name}:{number}: missing link target {target}')
                elif resolved in document_anchors and url.fragment:
                    if unquote(url.fragment) not in document_anchors[resolved]:
                        failures.append(f'{name}:{number}: missing heading {target}')
    if failures:
        print('\n'.join(failures))
        return 1
    print(f'Checked local links and heading anchors in {len(documents)} Markdown files.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
