"""Local single-instance replacement + measured rollback (not a rolling deployment)."""
import argparse
import json
import os
import subprocess
import time
from pathlib import Path

from gate import evaluate
from lab import ROOT, Lab, request
from load import run_load


def wait_ready(url):
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        try:
            if request(url, "/health/ready")["status"] == "ready":
                return
        except (OSError, ValueError):
            time.sleep(.5)
    raise RuntimeError("API did not become ready")


def image_id(name):
    return subprocess.check_output(["docker", "image", "inspect", name, "--format", "{{.Id}}"],
                                   text=True).strip()


def deploy(lab, image):
    env = {**os.environ, **lab.env, "APP_IMAGE": image, "APP_VERSION": image[:24]}
    lab.compose("up", "-d", "--no-deps", "--force-recreate", "--pull", "never", "api", env=env)
    wait_ready(lab.url)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, default=ROOT / ".env")
    parser.add_argument("--candidate", required=True, help="Existing local image tag or immutable image ID")
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "evidence/release.json")
    parser.add_argument("--inject-failure", action="store_true", help="Negative gate drill: inject 20% errors")
    args = parser.parse_args()
    lab = Lab(args.env_file)
    baseline = json.loads(args.baseline.read_text())
    if baseline["requests"] < 1000 or baseline["error_rate"] > .01:
        parser.error("A healthy baseline with at least 1000 requests is required")
    candidate = image_id(args.candidate)
    report = {"candidate_image_id": candidate,
              "kind": "local replacement; no zero-downtime guarantee", "rolled_back": False}
    # Exclusive local release lock; independent per Compose project.
    lock = ROOT / "evidence" / (lab.env["COMPOSE_PROJECT_NAME"] + ".release.lock")
    lock.parent.mkdir(exist_ok=True)
    import fcntl
    with lock.open("w") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("Another release is running for this environment")
        container = lab.compose("ps", "-q", "api", capture_output=True, text=True).stdout.strip()
        previous = subprocess.check_output(["docker", "inspect", container, "--format", "{{.Image}}"], text=True).strip()
        report["previous_image_id"] = previous
        try:
            deploy(lab, candidate)
            if args.inject_failure:
                request(lab.url, "/admin/faults", {"fail_every": 5}, lab.env["LAB_ADMIN_TOKEN"], "PUT")
            sample = run_load(lab.url, baseline["requests"], baseline["concurrency"])
            result = evaluate(baseline, sample)
            report.update({"candidate_load": sample, "gate": result})
            if not result["passed"]:
                raise RuntimeError("Candidate failed release gate")
            report["promoted"] = True
        except Exception as exc:
            report["promoted"] = False
            report["error"] = str(exc)
            deploy(lab, previous)
            order = lab.seed(1)[0]
            report["rolled_back"] = request(lab.url, "/orders/" + order["id"])["status"] == "confirmed"
        args.output.parent.mkdir(exist_ok=True, parents=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["promoted"] else 1)


if __name__ == "__main__":
    main()
