#!/usr/bin/env python3
"""Verify Markdown Document Links Integrity.

Validates all local Markdown links, relative file references, and internal anchors
across all documentation files to guarantee zero 404s and zero broken references.

Usage:
    python3 scripts/verify_docs_links.py
"""

import os
import re
import sys
import urllib.parse

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MD_LINK_RE = re.compile(r"!?\[([^\]]*)\]\(([^)]+)\)")
HTML_HREF_RE = re.compile(r'href=["\']([^"\']+)["\']')
HTML_SRC_RE = re.compile(r'src=["\']([^"\']+)["\']')
HEADER_RE = re.compile(r"^(#{1,6})\s+(.+)$", re.MULTILINE)
IGNORED_DIRS = (".git", "build", "deps", ".cache", "node_modules")
IGNORED_SCHEMES = ("http://", "https://", "mailto:", "javascript:", "file://")


def slugify_github(text: str) -> str:
    """Convert header text to a GitHub markdown anchor slug."""
    text = re.sub(r"<[^>]+>", "", text)  # remove inline html
    text = text.lower().strip()
    text = re.sub(r"[^\w\s-]", "", text)
    return re.sub(r"[-\s]+", "-", text)


def extract_anchors(file_path: str) -> set:
    """Extract all possible anchor IDs and headers from a markdown file."""
    anchors = set()
    try:
        with open(file_path, encoding="utf-8") as f:
            content = f.read()
    except Exception:
        return anchors

    for match in HEADER_RE.finditer(content):
        header_text = match.group(2).strip()
        anchors.add(slugify_github(header_text))

    for a in re.findall(r'<a\s+[^>]*(?:id|name)=["\']([^"\']+)["\']', content, re.IGNORECASE):
        anchors.add(a.lower())

    return anchors


def find_markdown_files() -> list[str]:
    """Collect all Markdown files in the repository, excluding build/vendor directories."""
    files_to_check = []
    for root, _, files in os.walk(PROJECT_ROOT):
        if any(ignored in root for ignored in IGNORED_DIRS):
            continue
        for file in files:
            if file.endswith(".md"):
                files_to_check.append(os.path.join(root, file))
    return files_to_check


def extract_links_from_line(line: str) -> list[str]:
    """Extract all raw markdown and HTML link targets from a line of text."""
    raw_links = []
    for m in MD_LINK_RE.finditer(line):
        raw_links.append(m.group(2).strip())
    for m in HTML_HREF_RE.finditer(line):
        raw_links.append(m.group(1).strip())
    for m in HTML_SRC_RE.finditer(line):
        raw_links.append(m.group(1).strip())
    return raw_links


def check_target_anchor(target_file: str, fragment: str, rel_md: str, line_num: int) -> str | None:
    """Check if a fragment anchor exists inside the specified markdown file."""
    if fragment and target_file.endswith(".md"):
        anchors = extract_anchors(target_file)
        if fragment not in anchors:
            target_rel = os.path.relpath(target_file, PROJECT_ROOT)
            return f"  ❌ {rel_md}:{line_num} -> Target file exists but anchor '#{fragment}' missing in '{target_rel}'"
    return None


def validate_file_links(md_file: str) -> tuple[list[str], int]:
    """Validate all links within a single Markdown document."""
    rel_md = os.path.relpath(md_file, PROJECT_ROOT)
    errors = []
    checked_count = 0

    try:
        with open(md_file, encoding="utf-8") as f:
            lines = f.readlines()
    except Exception as e:
        return [f"❌ Failed to read {rel_md}: {e}"], 0

    file_anchors = None

    for line_num, line in enumerate(lines, 1):
        for raw_link in extract_links_from_line(line):
            link_clean = raw_link.split()[0].strip()
            if not link_clean or any(link_clean.startswith(s) for s in IGNORED_SCHEMES):
                continue

            checked_count += 1
            parsed = urllib.parse.urlparse(link_clean)
            target_path = parsed.path
            fragment = parsed.fragment.lower()

            if not target_path and fragment:
                if file_anchors is None:
                    file_anchors = extract_anchors(md_file)
                if fragment not in file_anchors:
                    errors.append(f"  ❌ {rel_md}:{line_num} -> Broken internal anchor '#{fragment}'")
                continue

            md_dir = os.path.dirname(md_file)
            resolved = os.path.normpath(os.path.join(md_dir, target_path))
            root_resolved = os.path.normpath(os.path.join(PROJECT_ROOT, target_path))

            # Skip sister repository paths (e.g. suckless-ogl) or paths outside this repository tree
            if "suckless-ogl" in link_clean or "suckless-ogl" in target_path:
                continue

            try:
                rel_to_root = os.path.relpath(resolved, PROJECT_ROOT)
                if rel_to_root.startswith(".."):
                    continue
            except ValueError:
                continue

            if os.path.exists(resolved):
                err = check_target_anchor(resolved, fragment, rel_md, line_num)
                if err:
                    errors.append(err)
            elif os.path.exists(root_resolved):
                err = check_target_anchor(root_resolved, fragment, rel_md, line_num)
                if err:
                    errors.append(err)
            else:
                target_rel = os.path.relpath(resolved, PROJECT_ROOT)
                errors.append(f"  ❌ {rel_md}:{line_num} -> Missing target file: '{link_clean}' ({target_rel})")

    return errors, checked_count


def check_all_docs() -> int:
    """Run full documentation link check across all Markdown documents in the project."""
    files_to_check = find_markdown_files()
    print(f"🔍 Scanning {len(files_to_check)} Markdown documents for broken links...\n")

    all_errors = []
    total_links_checked = 0

    for md_file in files_to_check:
        errs, count = validate_file_links(md_file)
        all_errors.extend(errs)
        total_links_checked += count

    if all_errors:
        print(f"🚨 Found {len(all_errors)} broken documentation link(s):\n")
        for err in all_errors:
            print(err)
        print(f"\nChecked {total_links_checked} link(s). Validation FAILED.")
        return 1

    print(
        f"✅ Success! All {total_links_checked} documentation links and anchors "
        f"are valid across {len(files_to_check)} files."
    )
    return 0


if __name__ == "__main__":
    sys.exit(check_all_docs())
