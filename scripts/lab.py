"""Host-side Docker Compose operations. Requires Python >=3.9, no host pip installs."""
import argparse
import json
import secrets
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_env(path):
    return dict(line.split("=", 1) for line in path.read_text().splitlines()
                if line and not line.startswith("#") and "=" in line)


def request(url, path, body=None, token=None, method=None, key=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["X-Lab-Token"] = token
    if key:
        headers["Idempotency-Key"] = key
    req = urllib.request.Request(url + path, headers=headers, method=method,
                                 data=None if body is None else json.dumps(body).encode())
    with urllib.request.urlopen(req, timeout=10) as response:
        return json.loads(response.read())


class Lab:
    def __init__(self, envfile):
        self.envfile = envfile.resolve()
        self.env = read_env(self.envfile)
        self.base = ["docker", "compose", "--env-file", str(self.envfile), "-p",
                     self.env["COMPOSE_PROJECT_NAME"], "-f", str(ROOT / "compose.yaml")]
        self.url = "http://localhost:" + self.env.get("API_PORT", "8000")
        self.stub = "http://localhost:" + self.env.get("STUB_PORT", "8001")

    def compose(self, *args, **kwargs):
        return subprocess.run(self.base + list(args), cwd=ROOT, check=True, **kwargs)

    def sql(self, query, service="db"):
        return self.compose("exec", "-T", service, "psql", "-U", "lab", "-d", "orders", "-At",
                            "-v", "ON_ERROR_STOP=1", "-c", query, capture_output=True, text=True).stdout.strip()

    def reset_faults(self):
        for url in (self.url, self.stub):
            request(url, "/admin/faults", {}, self.env["LAB_ADMIN_TOKEN"], "PUT")

    def seed(self, count=5, url=None):
        rows = []
        for i in range(count):
            rows.append(request(url or self.url, "/orders", {
                "customer_id": "seed-customer", "sku": f"widget-{i}",
                "quantity": i + 1, "unit_price_cents": 1250,
            }, key="seed-" + uuid.uuid4().hex))
        return rows


SUMMARY_SQL = """SELECT json_build_object(
 'orders', (SELECT count(*) FROM orders),
 'payments', (SELECT count(*) FROM payments),
 'payment_decisions', (SELECT count(*) FROM payment_decisions),
 'orders_hash', (SELECT md5(coalesce(string_agg(row_to_json(o)::text, '' ORDER BY id),'')) FROM orders o),
 'payments_hash', (SELECT md5(coalesce(string_agg(row_to_json(p)::text, '' ORDER BY id),'')) FROM payments p),
 'decisions_hash', (SELECT md5(coalesce(string_agg(row_to_json(d)::text, '' ORDER BY order_id),'')) FROM payment_decisions d),
 'newest_transaction', (SELECT max(updated_at) FROM orders),
 'order_ids', (SELECT coalesce(json_agg(id ORDER BY id),'[]') FROM orders));"""


def backup(lab):
    directory = ROOT / "backups"
    directory.mkdir(exist_ok=True)
    path = directory / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:6] + ".dump")
    # Keep this transaction alive while pg_dump imports its snapshot; fingerprints
    # and archive then describe exactly the same committed data under active writes.
    process = subprocess.Popen(lab.base + ["exec", "-T", "db", "psql", "-U", "lab", "-d", "orders",
                               "-Atq", "-v", "ON_ERROR_STOP=1"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, text=True, cwd=ROOT)
    try:
        process.stdin.write("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\nSELECT pg_export_snapshot();\n")
        process.stdin.flush()
        snapshot = process.stdout.readline().strip()
        if not snapshot or "-" not in snapshot:
            raise RuntimeError("Could not obtain backup snapshot")
        snapshot_time = datetime.now(timezone.utc).isoformat()
        process.stdin.write(SUMMARY_SQL + "\n")
        process.stdin.flush()
        summary = json.loads(process.stdout.readline())
        with path.open("wb") as out:
            lab.compose("exec", "-T", "db", "pg_dump", "-U", "lab", "-d", "orders", "-Fc",
                        "--snapshot=" + snapshot, stdout=out)
        process.stdin.write("COMMIT;\n")
        process.stdin.close()
        if process.wait(timeout=10):
            raise RuntimeError("Backup transaction failed")
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
    import hashlib
    manifest = {"project": lab.env["COMPOSE_PROJECT_NAME"], "snapshot_time": snapshot_time,
                "archive_sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "data": summary}
    path.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n")
    return path


def restore(lab, path):
    import hashlib
    manifest = json.loads(path.with_suffix(".json").read_text())
    if hashlib.sha256(path.read_bytes()).hexdigest() != manifest["archive_sha256"]:
        raise RuntimeError("Archive checksum mismatch")
    if manifest["project"] != lab.env["COMPOSE_PROJECT_NAME"]:
        raise RuntimeError("Backup belongs to a different environment")
    incident = datetime.now(timezone.utc)
    start = time.perf_counter()
    source = json.loads(lab.sql(SUMMARY_SQL))
    lab.compose("--profile", "recovery", "stop", "restore-api", "restore-payments")
    lab.compose("--profile", "recovery", "up", "-d", "--wait", "restore-db")
    # Only the disposable restore-db is ever a restore destination.
    with path.open("rb") as stream:
        lab.compose("exec", "-T", "restore-db", "pg_restore", "-U", "lab", "-d", "orders",
                    "--clean", "--if-exists", "--no-owner", "--exit-on-error", stdin=stream)
    recovered = json.loads(lab.sql(SUMMARY_SQL, "restore-db"))
    if recovered != manifest["data"]:
        raise RuntimeError("Restored rows differ from the consistent backup manifest")
    lab.compose("--profile", "recovery", "up", "-d", "--wait", "restore-api")
    restore_url = "http://localhost:" + lab.env.get("RESTORE_API_PORT", "8100")
    if recovered["order_ids"]:
        request(restore_url, "/orders/" + recovered["order_ids"][0])
    written = lab.seed(1, restore_url)[0]
    assert request(restore_url, "/orders/" + written["id"])["status"] == "confirmed"
    duration = time.perf_counter() - start
    recovery_point_age = (incident - datetime.fromisoformat(manifest["snapshot_time"])).total_seconds()
    report = {
        "incident_start": incident.isoformat(), "backup": str(path),
        "row_hashes_match": True, "restored_orders": recovered["orders"],
        "restored_payments": recovered["payments"], "read_write_verified": True,
        "recovery_seconds": round(duration, 3), "recovery_point_age_seconds": round(recovery_point_age, 3),
        "newest_recovered_transaction": recovered["newest_transaction"],
        "new_orders_not_in_backup": len(set(source["order_ids"]) - set(recovered["order_ids"])),
        "rto_target_seconds": 900, "rpo_target_seconds": 300,
        "targets_met": duration <= 900 and recovery_point_age <= 300,
        "scope": "Local isolated restore; RPO uses consistent snapshot age, not last-write age",
    }
    (ROOT / "evidence").mkdir(exist_ok=True)
    (ROOT / "evidence/restore.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, default=ROOT / ".env")
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init")
    init.add_argument("--offset", type=int, default=0)
    init.add_argument("--name", default="orderlab")
    up = commands.add_parser("up")
    up.add_argument("--no-build", action="store_true")
    commands.add_parser("down")
    commands.add_parser("test")
    commands.add_parser("seed")
    commands.add_parser("smoke")
    commands.add_parser("reset-faults")
    fault = commands.add_parser("fault")
    fault.add_argument("service", choices=["api", "payments"])
    fault.add_argument("settings", help='JSON, e.g. {"latency_ms":800}')
    commands.add_parser("backup")
    rec = commands.add_parser("restore")
    rec.add_argument("archive", type=Path)
    commands.add_parser("status")
    args = parser.parse_args()
    if args.command == "init":
        if args.env_file.exists():
            parser.error("Environment file already exists; it was not overwritten")
        env = read_env(ROOT / ".env.example")
        env["COMPOSE_PROJECT_NAME"] = args.name
        for key in ("API_PORT", "STUB_PORT", "PROMETHEUS_PORT", "GRAFANA_PORT", "JAEGER_PORT"):
            env[key] = str(int(env[key]) + args.offset)
        env["RESTORE_API_PORT"] = str(8100 + args.offset)
        for key in ("POSTGRES_PASSWORD", "LAB_ADMIN_TOKEN", "GRAFANA_PASSWORD"):
            env[key] = secrets.token_hex(24)
        args.env_file.write_text("".join(f"{k}={v}\n" for k, v in env.items()))
        args.env_file.chmod(0o600)
        print(f"Created {args.env_file}; local credentials are kept there.")
        return
    if not args.env_file.exists():
        parser.error("Run init first")
    lab = Lab(args.env_file)
    if args.command == "up":
        if not args.no_build:
            lab.compose("build", "api")
        lab.compose("up", "-d", "--no-build", "--wait", "--wait-timeout", "180")
    elif args.command == "down":
        lab.compose("--profile", "recovery", "down")
    elif args.command == "test":
        lab.compose("run", "--rm", "tests")
    elif args.command == "status":
        lab.compose("ps")
    elif args.command == "seed":
        print(json.dumps(lab.seed(), indent=2))
    elif args.command == "smoke":
        assert request(lab.url, "/health/ready")["status"] == "ready"
        row = lab.seed(1)[0]
        assert request(lab.url, "/orders/" + row["id"])["status"] == "confirmed"
        print(json.dumps({"passed": True, "order_id": row["id"]}))
    elif args.command == "reset-faults":
        lab.reset_faults()
    elif args.command == "fault":
        print(request(lab.url if args.service == "api" else lab.stub, "/admin/faults",
                      json.loads(args.settings), lab.env["LAB_ADMIN_TOKEN"], "PUT"))
    elif args.command == "backup":
        print(backup(lab))
    elif args.command == "restore":
        result = restore(lab, args.archive.resolve())
        print(json.dumps(result, indent=2))
        if not result["targets_met"]:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
