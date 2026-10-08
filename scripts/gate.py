"""Health gate: insufficient or non-comparable samples never count as a pass."""
import argparse
import json
from pathlib import Path


def evaluate(baseline, candidate, minimum=1000):
    reasons = []
    for name, result in (("baseline", baseline), ("candidate", candidate)):
        if result["requests"] < minimum:
            reasons.append(f"{name}: insufficient samples")
        if result.get("unexpected_statuses", 0):
            reasons.append(f"{name}: unexpected client errors")
        if result["error_rate"] > .01:
            reasons.append(f"{name}: server/transport error rate exceeds 1%")
    if any(baseline[k] != candidate[k] for k in ("workload", "concurrency")):
        reasons.append("workloads are not comparable")
    if baseline.get("warmup_requests", 0) != candidate.get("warmup_requests", 0):
        reasons.append("warm-up policies are not comparable")
    if baseline["p95_ms"] <= 0 or candidate["p95_ms"] > baseline["p95_ms"] * 1.2:
        reasons.append("candidate p95 exceeds baseline by more than 20%")
    return {"passed": not reasons, "reasons": reasons}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    result = evaluate(json.loads(args.baseline.read_text()), json.loads(args.candidate.read_text()))
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result["passed"] else 1)
