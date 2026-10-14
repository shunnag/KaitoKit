#!/usr/bin/env python3
"""macos-26-intel の 4 回の green run(38130584411, 38182290488, 38187939240,
38187949085)の class 別所要秒(平均 / 最大)で分けた。最後の shard は残り全部
(補集合)なので、新しい class や改名した class も必ずどこかで走る。
Intel は 2 shard にして定常時の macOS job を最大 4 個にする。
予測: 37.1–46.4 分 / shard。運ぶ bundle の一覧と実行 log から全件実行を検査する。
"""

import argparse
from collections import Counter
from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import re
import sys
import tempfile


PLAN = {
    "macos-26-intel": {
        "shards": 2,
        "explicit": [
            # shard 1: 平均約 43.0 分(4 run では 37.8 / 41.9 / 46.1 / 46.4 分)で実行する。
            ["PPMdDifferentialTests",            # 1093.6 / 1284.6 s
             "ZipLocalReadAheadTests",           #  474.5 /  517.4
             "RARPasswordCompatibilityTests",    #  289.2 /  315.0
             "ZstdDifferentialTests",            #  200.5 /  217.5
             "StuffItXJPEGTests",                #  179.9 /  206.6
             "ZipPPMdTests",                     #  124.2 /  135.9
             "ParallelBzip2DecompressorTests",   #   81.7 /  117.5
             "Deflate64DifferentialTests",       #   76.5 /   88.1
             "SevenZipPublicValueGoldenTests"],  #   61.8 /   70.0
            # shard 2 は補集合(37.1 / 41.3 / 45.6 / 46.2 分)と compat・LHA golden を実行する。
        ],
    },
    "macos-26": {"shards": 1, "explicit": []},
}
# compat は全 OS で分けず、常に 1 shard("all")で実行する。
COMPAT = {"shards": 1, "explicit": []}


class ShardError(ValueError):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ShardError(message)


def plan_for(os_name, module):
    if module == "KaitoKitTests":
        if os_name not in PLAN:
            raise ShardError("unknown OS: " + os_name)
        return PLAN[os_name]
    if module == "KaitoKitCompatTests":
        return COMPAT
    raise ShardError("unknown module: " + module)


def shard_ids(plan):
    return ["all"] if plan["shards"] == 1 else [str(index) for index in range(1, plan["shards"] + 1)]


def shard_total(plan):
    return "all" if plan["shards"] == 1 else str(plan["shards"])


def load_inventory(path):
    inventory = {}
    seen = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([^./\s]+)\.([^/\s,]+)/([^/\s]+)", line)
        if not match or line in seen:
            raise ShardError("invalid or duplicate inventory test: " + line)
        seen.add(line)
        module = match.group(1)
        class_name, method = line.split("/", 1)
        inventory.setdefault(module, {}).setdefault(class_name, set()).add(method)
    if not seen:
        raise ShardError("inventory has zero tests")
    return inventory


def inventory_from_helpers(paths, output):
    tests = set()
    for path in paths:
        data = json.loads(path.read_text(encoding="utf-8"))
        count = 0
        for bundle in data["tests"]:
            name = bundle["name"]
            if not name.endswith(".xctest"):
                raise ShardError("bundle name must end with .xctest: " + name)
            module = name[:-len(".xctest")]
            for suite in bundle["tests"]:
                class_name = suite["name"]
                if not class_name.startswith(module + "."):
                    raise ShardError("class lacks module prefix: " + class_name)
                for test in suite["tests"]:
                    tests.add(class_name + "/" + test["name"])
                    count += 1
        if not count:
            raise ShardError("helper JSON has zero tests: " + str(path))
    output.write_text("".join(test + "\n" for test in sorted(tests)), encoding="utf-8")
    inventory = load_inventory(output)
    for module, classes in sorted(inventory.items()):
        print(f"{module}: {len(classes)} classes, {test_count(inventory, module, classes)} tests")
    return inventory


def partition(inventory, os_name, module):
    plan = plan_for(os_name, module)
    classes = set(inventory.get(module, {}))
    if not classes:
        raise ShardError("inventory has no classes for " + module)
    explicit = plan["explicit"]
    if len(explicit) != plan["shards"] - 1:
        raise ShardError("explicit lists do not match shard count")
    planned = [module + "." + name for group in explicit for name in group]
    if len(planned) != len(set(planned)):
        raise ShardError("explicit class lists overlap")
    # plan の全 class を調べ、古い名前を warning にして補集合へ改名を受け入れる。
    for class_name in sorted(set(planned) - classes):
        print("::warning::planned class missing from inventory: " + class_name, file=sys.stderr)
    groups = [classes & {module + "." + name for name in group} for group in explicit]
    groups.append(classes - set(planned))
    if any(not group for group in groups):
        raise ShardError("a non-last shard or the complement is empty")
    return dict(zip(shard_ids(plan), groups))


def select(inventory, os_name, module, shard, shards):
    plan = plan_for(os_name, module)
    if shards != shard_total(plan) or shard not in shard_ids(plan):
        raise ShardError(f"wrong shard count or shard: {os_name}/{module} {shard}/{shards}; expected {shard_ids(plan)}/{shard_total(plan)}")
    return partition(inventory, os_name, module)[shard]


def test_count(inventory, module, classes):
    return sum(len(inventory[module][name]) for name in classes)


def verify(inventory, os_name, module, shard, shards, log, output):
    classes = select(inventory, os_name, module, shard, shards)
    expected_names = {name[len(module) + 1:] for name in classes}
    suites = Counter()
    executed = []
    lines = log.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        match = re.match(r"^Test Suite '([^']+)' started at", line)
        if match and match.group(1) not in ("All tests", "Selected tests") and not match.group(1).endswith(".xctest"):
            suites[match.group(1)] += 1
        if re.match(r"^Test Suite '(All tests|Selected tests)' (passed|failed) at", line):
            count = re.match(r"\s*Executed (\d+) tests?\b", lines[index + 1]) if index + 1 < len(lines) else None
            if count:
                executed.append(int(count.group(1)))
    expected = test_count(inventory, module, classes)
    missing = sorted(expected_names - suites.keys())
    extra = sorted(suites.keys() - expected_names)
    duplicates = sorted(name for name, count in suites.items() if count != 1)
    if missing or extra or duplicates or executed != [expected]:
        raise ShardError(f"log mismatch: missing={missing}, extra={extra}, repeated={duplicates}, executed={executed}, expected={expected}")
    summary = {"os": os_name, "module": module, "shard": shard, "shards": shards,
               "classes": sorted(classes), "executed": executed[0], "expected": expected}
    output.write_text(json.dumps(summary, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
    return summary


def coverage(inventory, directory):
    pairs = {(os_name, module): [] for os_name in PLAN for module in ("KaitoKitTests", "KaitoKitCompatTests")}
    for path in sorted(directory.rglob("*.json")):
        summary = json.loads(path.read_text(encoding="utf-8"))
        pair = (summary["os"], summary["module"])
        if pair not in pairs:
            raise ShardError("unexpected summary: " + str(path))
        pairs[pair].append(summary)
    rows = []
    for (os_name, module), summaries in sorted(pairs.items()):
        plan = plan_for(os_name, module)
        ids = [summary["shard"] for summary in summaries]
        if Counter(ids) != Counter(shard_ids(plan)):
            raise ShardError(f"missing or duplicate summaries for {os_name}/{module}: {ids}")
        union = set()
        executed = 0
        for summary in sorted(summaries, key=lambda item: item["shard"]):
            classes = set(summary["classes"])
            if len(classes) != len(summary["classes"]) or union & classes:
                raise ShardError(f"duplicate class across shards: {os_name}/{module}")
            selected = select(inventory, os_name, module, summary["shard"], summary["shards"])
            if classes != selected:
                raise ShardError(f"summary class mismatch: missing={sorted(selected - classes)}, extra={sorted(classes - selected)}")
            count = test_count(inventory, module, classes)
            if type(summary["executed"]) is not int or type(summary["expected"]) is not int or summary["executed"] != count or summary["expected"] != count:
                raise ShardError(f"summary executed-count mismatch: {os_name}/{module} {summary['shard']}")
            union.update(classes)
            executed += summary["executed"]
            rows.append((os_name, module, summary["shard"], len(classes), summary["executed"]))
        all_classes = set(inventory.get(module, {}))
        if union != all_classes or executed != test_count(inventory, module, all_classes):
            raise ShardError(f"incomplete coverage: {os_name}/{module}")
    print("os               module               shard classes executed")
    for row in rows:
        print(f"{row[0]:16} {row[1]:20} {row[2]:5} {row[3]:7} {row[4]:8}")
    print("coverage OK")


def plan_check(inventory):
    for os_name in PLAN:
        for module in ("KaitoKitTests", "KaitoKitCompatTests"):
            plan = plan_for(os_name, module)
            union = set()
            for shard in shard_ids(plan):
                classes = select(inventory, os_name, module, shard, shard_total(plan))
                if union & classes:
                    raise ShardError("shards overlap")
                union.update(classes)
                print(f"{os_name} {module} {shard}/{shard_total(plan)}: {len(classes)} classes, {test_count(inventory, module, classes)} tests")
            if union != set(inventory[module]):
                raise ShardError("shards do not cover inventory")
    print("plan OK")


def sample_log(module, classes, count, outer):
    lines = [f"Test Suite '{outer}' started at 2026-10-12 01:59:57.123.",
             f"Test Suite '{module}.xctest' started at 2026-10-12 01:59:57.123."]
    for class_name in sorted(classes):
        short = class_name[len(module) + 1:]
        lines.extend([f"Test Suite '{short}' started at 2026-10-12 01:59:57.123.",
                      f"Test Suite '{short}' passed at 2026-10-12 01:59:58.123.",
                      "\t Executed 1 test, with 1 test skipped and 0 failures (0 unexpected) in 1.000 (1.000) seconds"])
    noun = "test" if count == 1 else "tests"
    lines.extend([f"Test Suite '{outer}' passed at 2026-10-12 01:59:58.123.",
                  f"\t Executed {count} {noun}, with 0 failures (0 unexpected) in 1.000 (1.000) seconds"])
    return "\n".join(lines) + "\n"


def self_test():
    def must_fail(action):
        try:
            action()
        except ShardError:
            return
        raise AssertionError("self-test accepted invalid shard data")

    with tempfile.TemporaryDirectory() as temporary, redirect_stderr(io.StringIO()) as warnings, redirect_stdout(io.StringIO()):
        root = Path(temporary)
        helper = root / "helper.json"
        modules = {
            "KaitoKitTests": ["PPMdDifferentialTests", "XZNativeDecompressorTests", "TarSpliceDifferentialFuzzTests", "ZipLocalReadAheadTests", "NewTests"],
            "KaitoKitCompatTests": ["CompatTests"],
        }
        data = {"name": "All Tests", "tests": [
            {"name": module + ".xctest", "tests": [
                {"name": module + "." + name, "tests": [{"name": "testOne"}] if module == "KaitoKitCompatTests" else [{"name": "testOne"}, {"name": "testTwo"}]}
                for name in names]} for module, names in modules.items()]}
        helper.write_text(json.dumps(data), encoding="utf-8")
        inventory = inventory_from_helpers([helper], root / "inventory.txt")
        assert shard_ids(PLAN["macos-26-intel"]) == ["1", "2"]
        first = select(inventory, "macos-26-intel", "KaitoKitTests", "1", "2")
        last = select(inventory, "macos-26-intel", "KaitoKitTests", "2", "2")
        assert first == {"KaitoKitTests.PPMdDifferentialTests", "KaitoKitTests.ZipLocalReadAheadTests"}
        assert last == {"KaitoKitTests.XZNativeDecompressorTests", "KaitoKitTests.TarSpliceDifferentialFuzzTests", "KaitoKitTests.NewTests"}
        assert "::warning::planned class missing from inventory: KaitoKitTests.StuffItXJPEGTests" in warnings.getvalue()
        plan_check(inventory)
        directory = root / "summaries"
        directory.mkdir()
        log = root / "run.log"
        outputs = []
        for os_name in PLAN:
            for module in modules:
                plan = plan_for(os_name, module)
                for shard in shard_ids(plan):
                    classes = select(inventory, os_name, module, shard, shard_total(plan))
                    count = test_count(inventory, module, classes)
                    log.write_text(sample_log(module, classes, count, "All tests" if shard == "all" else "Selected tests"), encoding="utf-8")
                    output = directory / f"{os_name}-{module}-{shard}.json"
                    verify(inventory, os_name, module, shard, shard_total(plan), log, output)
                    outputs.append(output)
        assert len(outputs) == 5
        coverage(inventory, directory)
        selected = first
        count = test_count(inventory, "KaitoKitTests", selected)
        valid_log = sample_log("KaitoKitTests", selected, count, "Selected tests")
        def bad_log(text):
            log.write_text(text, encoding="utf-8")
            verify(inventory, "macos-26-intel", "KaitoKitTests", "1", "2", log, root / "bad.json")
        must_fail(lambda: bad_log(sample_log("KaitoKitTests", set(), count, "Selected tests")))
        must_fail(lambda: bad_log(sample_log("KaitoKitTests", selected | last, count, "Selected tests")))
        must_fail(lambda: bad_log(valid_log + "Test Suite 'PPMdDifferentialTests' started at 2026-10-12 01:59:57.123.\n"))
        must_fail(lambda: bad_log(sample_log("KaitoKitTests", selected, count + 1, "Selected tests")))
        must_fail(lambda: select(inventory, "macos-26-intel", "KaitoKitTests", "1", "3"))
        must_fail(lambda: select(inventory, "macos-26-intel", "KaitoKitTests", "3", "2"))
        must_fail(lambda: select(inventory, "macos-26-intel", "KaitoKitCompatTests", "1", "2"))
        must_fail(lambda: select(inventory, "macos-26", "KaitoKitTests", "1", "1"))
        explicit = PLAN["macos-26-intel"]["explicit"]
        try:
            PLAN["macos-26-intel"]["explicit"] = [explicit[0] + [explicit[0][0]]]
            must_fail(lambda: select(inventory, "macos-26-intel", "KaitoKitTests", "1", "2"))
        finally:
            PLAN["macos-26-intel"]["explicit"] = explicit
        target = next(path for path in outputs if path.name == "macos-26-intel-KaitoKitTests-2.json")
        original = target.read_text(encoding="utf-8")
        summary = json.loads(original)
        summary["shards"] = "3"
        target.write_text(json.dumps(summary), encoding="utf-8")
        must_fail(lambda: coverage(inventory, directory))
        target.write_text(original, encoding="utf-8")
        summary = json.loads(original)
        summary["classes"].append("KaitoKitTests.PPMdDifferentialTests")
        target.write_text(json.dumps(summary), encoding="utf-8")
        must_fail(lambda: coverage(inventory, directory))
        target.write_text(original, encoding="utf-8")
        summary = json.loads(original)
        summary["classes"].pop()
        target.write_text(json.dumps(summary), encoding="utf-8")
        must_fail(lambda: coverage(inventory, directory))
        target.write_text(original, encoding="utf-8")
        summary = json.loads(original)
        summary["executed"] += 1
        target.write_text(json.dumps(summary), encoding="utf-8")
        must_fail(lambda: coverage(inventory, directory))
        target.write_text(original, encoding="utf-8")
        duplicate = directory / "duplicate.json"
        duplicate.write_text(original, encoding="utf-8")
        must_fail(lambda: coverage(inventory, directory))
        duplicate.unlink()
        target.unlink()
        must_fail(lambda: coverage(inventory, directory))
        for invalid in ({"tests": []}, {"tests": [{"name": "Bad", "tests": []}]},
                        {"tests": [{"name": "KaitoKitTests.xctest", "tests": [{"name": "Bad", "tests": []}]}]}):
            helper.write_text(json.dumps(invalid), encoding="utf-8")
            must_fail(lambda: inventory_from_helpers([helper], root / "bad-inventory.txt"))
    print("test shards self-test OK")


def main():
    parser = Parser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    subparsers = parser.add_subparsers(dest="command", parser_class=Parser)
    inventory_parser = subparsers.add_parser("inventory")
    inventory_parser.add_argument("--output", type=Path, required=True)
    inventory_parser.add_argument("helpers", type=Path, nargs="+")
    for command in ("select", "verify", "coverage", "plan-check"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--inventory", type=Path, required=True)
        if command in ("select", "verify"):
            for argument in ("os", "module", "shard", "shards"):
                subparser.add_argument("--" + argument, required=True)
        if command == "verify":
            subparser.add_argument("--log", type=Path, required=True)
            subparser.add_argument("--output", type=Path, required=True)
        elif command == "coverage":
            subparser.add_argument("--summaries", type=Path, required=True)
    try:
        args = parser.parse_args()
        if args.self_test:
            self_test()
        elif args.command == "inventory":
            inventory_from_helpers(args.helpers, args.output)
        elif args.command:
            inventory = load_inventory(args.inventory)
            if args.command == "select":
                classes = select(inventory, args.os, args.module, args.shard, args.shards)
                print("" if args.shard == "all" else ",".join(sorted(classes)))
            elif args.command == "verify":
                verify(inventory, args.os, args.module, args.shard, args.shards, args.log, args.output)
            elif args.command == "coverage":
                coverage(inventory, args.summaries)
            else:
                plan_check(inventory)
        else:
            raise ShardError("a subcommand or --self-test is required")
    except (OSError, ValueError, KeyError, TypeError, AttributeError, AssertionError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
