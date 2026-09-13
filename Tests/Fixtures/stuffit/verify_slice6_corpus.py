#!/usr/bin/env python3
"""slice 6 の同じ writer の書庫を全 fork で照合する。支給オラクルは変更しない。"""
import collections
import json
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[3]
ROOT = REPO / "inbox/stuffit-corpus"
KAITO = sys.argv[1]
OUTPUT = REPO / ".build/slice6/corpus.json"
EMPTY = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
CACHE = {}


def rows(text):
    result = []
    for line in text.splitlines():
        fields = line.split("\t")
        if len(fields) >= 4 and fields[0].isdigit():
            result.append((int(fields[1]), fields[2], fields[3]))
    return result


def normalized(values):
    return collections.Counter((size, sha) for size, sha, _ in values if size or sha != EMPTY)


def read(name):
    if name not in CACHE:
        proc = subprocess.run([KAITO, "sha", str(ROOT / "cc0" / name), "--forks", "-p", "password"],
                              capture_output=True, text=True, timeout=300)
        CACHE[name] = {"exit": proc.returncode, "rows": rows(proc.stdout), "stdout": proc.stdout, "stderr": proc.stderr}
    return CACHE[name]


def counterpart(name):
    if ".password." in name and ".sitx" in name:
        base = name.split(".password.")[0]
        return base + (".backcompat.sitx" if "stuffit_deluxe_" in name else ".sitx")
    if "stuffit_deluxe_" in name:
        return name.removesuffix(".exe").removesuffix(".install").removesuffix(".backcompat") + ".backcompat.sitx"
    return name.removesuffix(".exe") + ".sit"


results = []
for pattern, category, expected_count in [("*.password.*sitx*", "password", 16), ("*.exe", "exe", 21)]:
    files = sorted((ROOT / "cc0").glob(pattern))
    assert len(files) == expected_count
    for path in files:
        name = path.name
        reference = counterpart(name)
        actual, expected = read(name), read(reference)
        assert expected["exit"] == 0, (reference, expected["stderr"])
        actual_set, expected_set = normalized(actual["rows"]), normalized(expected["rows"])
        status = "match" if actual["exit"] == 0 and actual_set == expected_set else "mismatch"
        missing = expected_set - actual_set
        failures = [line for line in actual["stderr"].splitlines() if line.startswith("error: failed entry")]
        if (actual["exit"] != 0 and len(failures) == 1
                and re.search(r"\(sources/testfile\.jpg\): Unsupported archive method: StuffIt X compression 7$", failures[0])
                and not actual_set - expected_set and sum(missing.values()) == 1
                and list(missing)[0][0] == 220):
            status = "partial_jpeg"

        # Mac SITX のオラクルが書庫自体の SHA のときは、同じ writer の平文 SIT の data fork を使う。
        oracle_name = reference.replace(".password", "")
        if "stuffit7_dlx" in oracle_name and oracle_name.endswith(".sitx"):
            oracle_name = oracle_name.removesuffix(".sitx") + ".sit"
        oracle = ROOT / "oracle/cc0" / (oracle_name + ".sha")
        anchor = "missing"
        if oracle.exists():
            reference_data = [row for row in expected["rows"] if "/..namedfork/rsrc" not in row[2]]
            anchor = "match" if normalized(reference_data) == normalized(rows(oracle.read_text())) else "mismatch"
        if anchor != "match": status = "mismatch"
        item = {"file": name, "category": category, "counterpart": reference, "oracle": str(oracle.relative_to(ROOT)),
                "oracle_status": anchor, "status": status, "matched_forks": sum(actual_set.values()),
                "missing": [[size, sha, count] for (size, sha), count in missing.items()],
                "exit": actual["exit"], "stderr": actual["stderr"]}
        results.append(item)
        print(f"{category}\t{status}\t{item['matched_forks']}\t{name}\t{reference}")

summary = {category: dict(collections.Counter(row["status"] for row in results if row["category"] == category))
           for category in ["password", "exe"]}
print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
OUTPUT.parent.mkdir(parents=True, exist_ok=True)
OUTPUT.write_text(json.dumps({"summary": summary, "results": results, "runs": CACHE}, ensure_ascii=False, indent=2) + "\n")
sys.exit(1 if any(row["status"] == "mismatch" for row in results) else 0)
