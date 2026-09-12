#!/usr/bin/env python3
"""外部 XCTest のデータ層検証結果を、支給された perf オラクルと照合する。"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CORPUS = ROOT / "inbox/stuffit-corpus"
EXPECTED_CYANIDE = {
    "BirdFluWAVE.sitx": 31,
    "SMSSenderPro3osx.sitx": 53,
    "warriors_screen.sitx": 2,
    "theconceptosx.sitx": 1,
    "Tickershock.sitx": 1,
}
WRAPPED = {"theconceptosx.sitx", "Tickershock.sitx"}


def oracle_rows(path):
    rows = Counter()
    for line in path.read_text().splitlines():
        fields = line.split("\t")
        if len(fields) >= 4 and fields[0] != "total":
            rows[int(fields[1]), fields[2]] += 1
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory", nargs="?", type=Path, default=ROOT / ".build/slice3-inventory.json")
    inventory = json.loads(parser.parse_args().inventory.read_text())
    archives = {Path(a["file"]).name: a for a in inventory if a["file"].startswith("perf/")}
    assert set(archives) == set(EXPECTED_CYANIDE), "perf 書庫の集合"
    totals = Counter()
    for name, count in EXPECTED_CYANIDE.items():
        archive = archives[name]
        assert "error" not in archive, (name, archive.get("error"))
        streams = {e["attributes"]["1"]: e for e in archive["elements"] if e["type"] == 1}
        results = archive["forkResults"]
        expected = oracle_rows(CORPUS / "oracle/perf" / (name + ".sha"))
        stats = Counter(cyanide=0, decoded_crc=0, sha_match=0, sha_missing=0, unsupported=0)
        if name in WRAPPED:
            # この二つの支給 SHA は展開後の fork ではなく、外側 MacBinary の data fork。
            wrapped = (CORPUS / "perf" / name).read_bytes()
            size = int.from_bytes(wrapped[83:87], "big")
            inner = wrapped[128:128 + size]
            assert inner.startswith(b"StuffIt!") and len(inner) == size, name
            signature = (size, hashlib.sha256(inner).hexdigest())
            assert expected == Counter([signature]), (name, "wrapper オラクル")
            totals["wrapper_sha_match"] += 1
        for result in results:
            stream = streams[result["stream"]]
            algorithms = stream["algorithms"]
            compression = next(v for k, v in algorithms if k == 1)
            if "error" in result:
                assert name == "SMSSenderPro3osx.sitx" and compression == 0, (name, result)
                assert result["error"] == "Unsupported archive method: StuffIt X preprocessing 0", result
                stats["unsupported"] += 1
                continue
            assert [2, 0] in algorithms, (name, "stream CRC 未指定")
            stats["decoded_crc"] += 1
            stats["cyanide"] += compression == 1
            if name in WRAPPED or result["kind"] == 1:
                # resource fork と包みの内側の展開内容には支給 SHA がない。
                stats["sha_missing"] += 1
            else:
                signature = (result["length"], result["sha256"])
                assert expected[signature] > 0, (name, "SHA mismatch", result)
                expected[signature] -= 1
                stats["sha_match"] += 1
        assert stats["cyanide"] == count, (name, stats)
        assert stats["unsupported"] == (9 if name == "SMSSenderPro3osx.sitx" else 0), (name, stats)
        assert stats["decoded_crc"] == count + (name == "SMSSenderPro3osx.sitx"), (name, stats)
        # 成功した stream は全 slot を読み切り、XCTest 側で終端 CRC まで照合済み。
        for stream_id, stream in streams.items():
            group = [r for r in results if r["stream"] == stream_id]
            if all("error" not in r for r in group):
                assert sum(r["length"] for r in group) == stream["attributes"]["5"], (name, stream_id)
        totals.update(stats)
        print(name + ": " + " ".join(f"{key}={value}" for key, value in stats.items()))
    assert totals["cyanide"] == 88 and totals["decoded_crc"] == 89, totals
    print("total: " + " ".join(f"{key}={value}" for key, value in sorted(totals.items())) + " mismatch=0")
    print("CRC は直前に成功した外部 XCTest の stream 終端照合。SHA 不在 18 fork は SHA 一致に数えない。")


if __name__ == "__main__":
    main()
