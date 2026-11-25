"""Bottleneck hunt: deploy one variant, drive each endpoint with k6, and report USE signals.

    python3 missions/week-03/hunt.py seeded|fixed [--out evidence/week3-mission/seeded.json]
"""
import argparse
import json
import secrets
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).parent
NS = "bottleneck"
# endpoint, method, rate/s, duration: each load sits just above what the seeded version can handle.
TESTS = {
    "cpu-throttling": ("/cpu", "GET", 20, "60s"),
    "memory-leak": ("/remember", "POST", 20, "90s"),
    "db-pool": ("/db", "GET", 80, "60s"),
}


def kc(*args, **kwargs):
    return subprocess.run(["kubectl", "--context", "kind-orderlab", "-n", NS, *args],
                          check=True, text=True, capture_output=True, **kwargs).stdout


def use():
    script = "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/use').read().decode())"
    return json.loads(kc("exec", "deploy/app", "--", "python", "-c", script))


def restarts():
    pods = json.loads(kc("get", "pods", "-l", "app=hunt", "-o", "json"))["items"]
    pod = next(p for p in pods if "deletionTimestamp" not in p["metadata"])
    status = pod["status"]["containerStatuses"][0]
    return status["restartCount"], status.get("lastState", {}).get("terminated", {}).get("reason")


def deploy(variant):
    subprocess.run(["kubectl", "--context", "kind-orderlab", "create", "namespace", NS],
                   capture_output=True)  # already exists is fine
    if not kc("get", "secret", "hunt-db", "--ignore-not-found"):
        kc("create", "secret", "generic", "hunt-db", "--from-env-file=/dev/stdin",
           input=f"password={secrets.token_hex(16)}\n")
    kc("apply", "-k", str(HERE / "overlays" / variant))
    kc("rollout", "status", "deployment/postgres", "--timeout=180s")
    kc("rollout", "status", "deployment/app", "--timeout=180s")


def fresh_app():
    kc("rollout", "restart", "deployment/app")
    kc("rollout", "status", "deployment/app", "--timeout=180s")
    time.sleep(3)


def k6(endpoint, method, rate, duration):
    kc("delete", "pod", "k6", "--ignore-not-found")
    try:
        out = kc("run", "k6", "-i", "--restart=Never", "--image=grafana/k6:2.3.0", f"--env=ENDPOINT={endpoint}",
                 f"--env=METHOD={method}", f"--env=RATE={rate}", f"--env=DURATION={duration}",
                 "--", "run", "--quiet", "-", input=(HERE / "load.js").read_text())
    finally:
        kc("delete", "pod", "k6", "--ignore-not-found")
    return json.loads(out[out.index("{"):])


def run(name, endpoint, method, rate, duration):
    fresh_app()
    before, start = use(), time.monotonic()
    metrics = k6(endpoint, method, rate, duration)
    elapsed = time.monotonic() - start
    kc("wait", "--for=condition=Ready", "pod", "-l", "app=hunt", "--timeout=120s")
    count, reason = restarts()
    after = use()  # after an OOM kill these counters belong to the new container
    periods = after["cpu_periods"] - before["cpu_periods"]
    pool = after["pool"]
    return {
        "test": name, "rate": rate, "duration": duration,
        "requests": metrics["http_reqs"]["values"]["count"],
        "p95_ms": round(metrics["http_req_duration"]["values"]["p(95)"]),
        "error_rate": round(metrics["http_req_failed"]["values"]["rate"], 4),
        "dropped_iterations": metrics.get("dropped_iterations", {}).get("values", {}).get("count", 0),
        "cpu_cores_used": round((after["cpu_usage_usec"] - before["cpu_usage_usec"]) / 1e6 / elapsed, 3),
        "cpu_throttled_ratio": round((after["cpu_throttled_periods"] - before["cpu_throttled_periods"]) / periods, 3)
        if periods > 0 else 0,
        "memory_mib_end": round(after["memory_bytes"] / 2**20, 1),
        "memory_limit": after["memory_limit"],
        "restarts": count, "last_termination": reason,
        "pool_max": pool.get("pool_max"),
        "pool_avg_wait_ms": round(pool.get("requests_wait_ms", 0) / max(pool.get("requests_queued", 0), 1)),
        "pool_errors": pool.get("requests_errors", 0),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("variant", choices=["seeded", "fixed"])
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    deploy(args.variant)
    results = []
    for name, spec in TESTS.items():
        results.append(run(name, *spec))
        print(json.dumps(results[-1]), flush=True)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(results, indent=2) + "\n")
