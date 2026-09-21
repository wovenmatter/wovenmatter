"""Mark a native interaction window and summarize fixture run-loop delays."""
import csv
import json
import pathlib
import sys

mode, trace_path, label = sys.argv[1:]
trace = pathlib.Path(trace_path)
marker = trace.with_suffix(".window.json")
with trace.open() as source:
    rows = list(csv.DictReader(source))
if mode == "begin":
    marker.write_text(json.dumps({"label": label, "offset": len(rows)}))
elif mode == "end":
    start = json.loads(marker.read_text())
    assert start["label"] == label
    samples = rows[start["offset"]:]
    delays = sorted(float(row["delay_ms"]) for row in samples)
    if not delays:
        raise SystemExit("No timer samples; app may be unresponsive")
    result = {
        "label": label, "trace": str(trace), "samples": len(delays),
        "start": samples[0]["uptime"], "end": samples[-1]["uptime"],
        "max_delay_ms": round(max(delays), 2),
        "over_16ms": sum(delay > 16 for delay in delays),
        "over_50ms": sum(delay > 50 for delay in delays),
        "over_100ms": sum(delay > 100 for delay in delays),
    }
    with trace.with_suffix(".windows.jsonl").open("a") as output:
        output.write(json.dumps(result) + "\n")
    print(json.dumps(result))
else:
    raise SystemExit("mode must be begin or end")
