import json
import sys
from pathlib import Path

output = Path(sys.argv[1])
size = int(sys.argv[2]) if len(sys.argv) > 2 else 2 ** 30
count = size // 4096
group_counts = {}
rare = 0

with (output / "load.json").open("wb", buffering=1024 * 1024) as array, \
     (output / "load.jsonl").open("wb", buffering=1024 * 1024) as lines:
    array.write(b"[")
    for i in range(count):
        session = "s%02d" % (i % 64)
        rec = dict(id=i, session=session, nested={"level":[3, None, True], "status":"ok"},
                   text='Тест ☃ "\\ /')
        if i % 257 == 0:
            rec["kind"] = None
        elif i % 257 == 1:
            rec["kind"] = "null"
        if i in (0, count - 1):
            rec["marker"] = "edges"
        if i >= count - 64:
            rec["late"] = "needle"
        if i % 64 == 0:
            group_counts["s00"] = group_counts.get("s00", 0) + 1
            if i >= count - 64:
                rare += 1
        target = 4094 + ({0: 53, 1024: -53}.get(i, 0))
        if count <= 1024:
            target = 4094
        rec["pad"] = ""
        raw = json.dumps(rec, ensure_ascii=False, separators=(",",":")).encode("utf-8")
        raw = raw[:-2] + b"x" * (target - len(raw)) + raw[-2:]
        assert len(raw) == target
        lines.write(raw + b" \n")
        array.write(raw + (b"]" if i == count - 1 else b",\n"))
for e in ("json","jsonl"):
    assert (output / f"load.{e}").stat().st_size == size
(output / "fixture.json").write_text(json.dumps({"records":count,"groups":64,"s00":group_counts["s00"],"late_s00":rare,"size":size}), encoding="utf-8")
print(f"{count} records, {size} bytes each, s00={group_counts['s00']}, rare subset={rare}", flush=True)
