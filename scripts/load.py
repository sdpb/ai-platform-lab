"""Repeatable HTTP workload; standard library only, usable on the host."""
import argparse
import concurrent.futures
import json
import math
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path


def request_order(url, key, timeout=8):
    body = {"customer_id": "load-customer", "sku": "training-widget", "quantity": 1,
            "unit_price_cents": 2500}
    req = urllib.request.Request(url.rstrip("/") + "/orders", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "Idempotency-Key": key})
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            response.read()
            status = response.status
    except urllib.error.HTTPError as exc:
        status = exc.code
    except (OSError, TimeoutError):
        status = 0
    return status, time.perf_counter() - start


def run_load(url, requests=1000, concurrency=8, warmup=100):
    run_id = uuid.uuid4().hex
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        # Excluded from reported statistics; use the same warm-up on every run.
        list(executor.map(lambda i: request_order(url, f"warmup-{run_id}-{i}"), range(warmup)))
        start = time.perf_counter()
        results = list(executor.map(lambda i: request_order(url, f"load-{run_id}-{i}"), range(requests)))
    elapsed = time.perf_counter() - start
    latencies = sorted(t for _, t in results)
    statuses = {}
    for status, _ in results:
        statuses[str(status)] = statuses.get(str(status), 0) + 1
    return {
        "workload": "create-order-v1", "requests": requests, "concurrency": concurrency,
        "warmup_requests": warmup,
        "url": url, "run_id": run_id, "elapsed_seconds": round(elapsed, 4),
        "throughput_rps": round(requests / elapsed, 3), "statuses": statuses,
        "error_rate": sum(s == 0 or s >= 500 for s, _ in results) / requests,
        "unexpected_statuses": sum(s not in (200, 201) and 0 < s < 500 for s, _ in results),
        "p50_ms": round(latencies[math.ceil(.5 * requests) - 1] * 1000, 3),
        "p95_ms": round(latencies[math.ceil(.95 * requests) - 1] * 1000, 3),
        "max_ms": round(latencies[-1] * 1000, 3),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://localhost:8000")
    parser.add_argument("--requests", type=int, default=1000)
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.requests < 1 or args.concurrency < 1:
        parser.error("requests and concurrency must be positive")
    report = run_load(args.url, args.requests, args.concurrency)
    text = json.dumps(report, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + "\n")
    print(text)
