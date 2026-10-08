"""Run the supplied checks and prove telemetry and isolated recovery end to end."""
import argparse
import base64
import json
import subprocess
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from lab import ROOT, Lab, backup, request, restore


def poll(check, seconds=40):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (OSError, ValueError, KeyError, IndexError):
            pass
        time.sleep(1)
    raise RuntimeError("Live verification timed out")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path, default=ROOT / ".env")
    args = parser.parse_args()
    lab = Lab(args.env_file)
    evidence = ROOT / "evidence"
    evidence.mkdir(exist_ok=True)
    for name, command in [
        ("lint", ["run", "--rm", "--no-deps", "tests", "ruff", "check", "--no-cache", "src", "scripts", "tests"]),
        ("tests", ["run", "--rm", "tests"]),
        ("alerts", ["run", "--rm", "--no-deps", "-v", str(ROOT / "observability") + ":/rules:ro",
                    "--entrypoint", "promtool", "prometheus", "test", "rules", "/rules/alerts.test.yml"]),
    ]:
        with (evidence / (name + ".log")).open("w") as stream:
            lab.compose(*command, stdout=stream, stderr=subprocess.STDOUT)
        print(name + ": passed", flush=True)
    lab.reset_faults()
    payload = {"customer_id": "verification", "sku": "trace-widget", "quantity": 1, "unit_price_cents": 100}
    req = urllib.request.Request(lab.url + "/orders", data=json.dumps(payload).encode(), headers={
        "Content-Type": "application/json", "Idempotency-Key": "verify-" + uuid.uuid4().hex,
    })
    with urllib.request.urlopen(req) as response:
        order = json.loads(response.read())
        trace_id = response.headers["X-Trace-ID"]
    jaeger = "http://localhost:" + lab.env.get("JAEGER_PORT", "16686")

    def trace_services():
        result = request(jaeger, "/api/traces/" + trace_id)
        processes = result["data"][0]["processes"].values()
        names = {p["serviceName"] for p in processes}
        return sorted(names) if {"orders-api", "payments-stub"} <= names else None

    services = poll(trace_services)
    prom = "http://localhost:" + lab.env.get("PROMETHEUS_PORT", "9090")
    targets = poll(lambda: {t["labels"]["job"] for t in request(prom, "/api/v1/targets")["data"]["activeTargets"]
                           if t["health"] == "up"} == {"orders", "payments"})
    query = urllib.parse.urlencode({"query": 'sum(orderlab_requests_total{service="orders-api",route="/orders",method="POST"})'})
    poll(lambda: float(request(prom, "/api/v1/query?" + query)["data"]["result"][0]["value"][1]) > 0)
    auth = base64.b64encode(("admin:" + lab.env["GRAFANA_PASSWORD"]).encode()).decode()
    dashboard_req = urllib.request.Request(
        "http://localhost:" + lab.env.get("GRAFANA_PORT", "3000") + "/api/dashboards/uid/orderlab",
        headers={"Authorization": "Basic " + auth},
    )
    with urllib.request.urlopen(dashboard_req) as response:
        dashboard = json.loads(response.read())["dashboard"]
    assert len(dashboard["panels"]) == 6
    # Restart the API process and verify durable data, not an in-memory response.
    lab.compose("restart", "api", stdout=subprocess.DEVNULL)
    poll(lambda: request(lab.url, "/health/ready")["status"] == "ready")
    assert request(lab.url, "/orders/" + order["id"])["status"] == "confirmed"
    archive = backup(lab)
    # Create a known committed transaction after the snapshot, so loss reporting
    # is tested instead of treating an empty/no-change database as recovery proof.
    lab.seed(1)
    recovery = restore(lab, archive)
    assert recovery["targets_met"] and recovery["new_orders_not_in_backup"] == 1
    result = {"passed": True, "project": lab.env["COMPOSE_PROJECT_NAME"],
              "integration_tests": "passed", "alert_fixtures": "passed", "lint": "passed",
              "trace_id": trace_id, "trace_services": services, "prometheus_targets_healthy": targets,
              "grafana_panels": len(dashboard["panels"]), "data_survives_api_restart": True,
              "recovery": recovery}
    (evidence / "verification.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
