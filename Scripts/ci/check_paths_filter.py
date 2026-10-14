#!/usr/bin/env python3
"""テストと script が読む文書を CI の paths filter が除外しないことを検査する。"""

import argparse
import re
import subprocess
import sys
from pathlib import Path


class FilterError(ValueError):
    pass


def parse_paths(text):
    lists = {}
    in_on = False
    event = None
    in_paths = False
    for line in text.splitlines():
        if line == "on:":
            in_on = True
            continue
        if not in_on or not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):
            break
        match = re.fullmatch(r"  ([\w_]+):", line)
        if match:
            event = match.group(1)
            in_paths = False
        elif line == "    paths:" and event in ("push", "pull_request"):
            if event in lists:
                raise FilterError("duplicate paths list for " + event)
            lists[event] = []
            in_paths = True
        elif in_paths:
            match = re.fullmatch(r"      - '([^']*)'", line)
            if match:
                lists[event].append(match.group(1))
            elif line.startswith("      "):
                raise FilterError("unsupported paths item: " + line.strip())
            else:
                in_paths = False
    if not lists.get("push") or not lists.get("pull_request"):
        raise FilterError("missing push or pull_request paths list")
    if lists["push"] != lists["pull_request"]:
        raise FilterError("push and pull_request paths lists differ")
    return lists["push"]


def glob_regex(pattern):
    # ** だけが / を越える。残りの文字は literal として扱う。
    parts = []
    index = 0
    while index < len(pattern):
        if pattern[index:index + 2] == "**":
            parts.append(".*")
            index += 2
        elif pattern[index] == "*":
            parts.append("[^/]*")
            index += 1
        elif pattern[index] == "?":
            parts.append("[^/]")
            index += 1
        else:
            parts.append(re.escape(pattern[index]))
            index += 1
    return re.compile("".join(parts))


def triggers(path, patterns):
    # 最後に一致した pattern の肯定・否定で決める。
    result = False
    for pattern in patterns:
        negative = pattern.startswith("!")
        if glob_regex(pattern[1:] if negative else pattern).fullmatch(path):
            result = not negative
    return result


def references(files, tracked):
    roots = {name for name in tracked if "/" not in name}
    found = []
    for filename, text in sorted(files.items()):
        expression = r'"([^"\n]*)"' if filename.endswith(".swift") else r"\"([^\"\n]*)\"|'([^'\n]*)'"
        for match in re.finditer(expression, text):
            literal = next(group for group in match.groups() if group is not None)
            if not (literal.startswith("Documentation" + "/") or literal in roots):
                continue
            line = text.count("\n", 0, match.start()) + 1
            # Swift の補間を tracked file に対する glob として展開する。
            literal = re.sub(r"\\\([^)]*\)", "*", literal)
            if "*" in literal:
                expanded = [path for path in tracked if glob_regex(literal).fullmatch(path)]
                if not expanded:
                    raise FilterError(f"unmatched reference: {literal} in {filename}:{line}")
            else:
                expanded = [literal]
            found.extend((path, filename, line) for path in expanded)
    return found


def check(patterns, found):
    errors = []
    for path, filename, line in found:
        if not triggers(path, patterns):
            errors.append(f"::error::{path} is read by {filename}:{line} but a change to it would not trigger CI")
    for path in (".github/workflows/ci.yml", "Tests/x.swift", "Sources/x.swift", "Scripts/x.py", "Package.swift"):
        if not triggers(path, patterns):
            errors.append(f"::error::{path} would not trigger CI")
    if errors:
        raise FilterError("\n".join(errors))


def self_test():
    doc = "Documentation" + "/"
    workflow = f"""name: CI
on:
  push:
    branches: [main]
    paths:
      - '**'
      - '!{doc}**'
      - '{doc}read-*.md'
  pull_request:
    paths:
      - '**'
      - '!{doc}**'
      - '{doc}read-*.md'
  workflow_dispatch:
  schedule:
    - cron: "17 15 * * *"
jobs:
"""
    patterns = parse_paths(workflow)
    assert triggers(doc + "read-a.md", patterns)
    assert not triggers(doc + "ignored.md", patterns)
    assert not triggers(doc + "read-a.md", patterns + ["!" + doc + "**"])
    assert glob_regex("a/**").fullmatch("a/b/c")
    assert not glob_regex("a/*").fullmatch("a/b/c")
    assert glob_regex("a/?.md").fullmatch("a/b.md")
    assert not glob_regex("a/?.md").fullmatch("a/bb.md")
    assert not glob_regex("a/[x].md").fullmatch("a/x.md")
    files = {"Tests/Mini.swift": f'let p = "{doc}read-\\(name).md"\nlet r = "README.md"'}
    found = references(files, [doc + "read-a.md", doc + "read-b.md", "README.md"])
    assert [item[0] for item in found] == [doc + "read-a.md", doc + "read-b.md", "README.md"]
    check(patterns, found)
    failures = [
        lambda: parse_paths(workflow.replace(f"      - '{doc}read-*.md'", f"      - '{doc}other.md'", 1)),
        lambda: parse_paths("on:\n  push:\n    paths:\n      - '**'\n"),
        lambda: check(patterns, [(doc + "ignored.md", "Tests/Mini.swift", 1)]),
        lambda: references(files, ["README.md"]),
        lambda: check([doc + "**"], []),
    ]
    for failure in failures:
        try:
            failure()
        except FilterError:
            continue
        raise AssertionError("self-test accepted an invalid paths filter")
    print("paths filter self-test OK")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--workflow", type=Path, default=Path(".github/workflows/ci.yml"))
    args = parser.parse_args()
    try:
        if args.self_test:
            self_test()
        else:
            tracked = subprocess.check_output(["git", "ls-files", "-z"], text=True).split("\0")
            tracked = sorted(path for path in tracked if path)
            files = {}
            for directory, extensions in (("Tests", (".swift",)), ("Scripts", (".py", ".sh"))):
                for path in sorted(Path(directory).rglob("*")):
                    if path.is_file() and path.suffix in extensions:
                        files[path.as_posix()] = path.read_text(encoding="utf-8")
            files["Package.swift"] = Path("Package.swift").read_text(encoding="utf-8")
            found = references(files, tracked)
            check(parse_paths(args.workflow.read_text(encoding="utf-8")), found)
            print(f"paths filter OK: {len(found)} references checked")
    except (OSError, ValueError, AssertionError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
