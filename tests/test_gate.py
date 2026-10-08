import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("gate", Path("scripts/gate.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

BASE = {"requests": 1000, "concurrency": 8, "workload": "create-order-v1", "error_rate": 0,
        "unexpected_statuses": 0, "p95_ms": 100}


def test_healthy_comparable_release_passes():
    assert gate.evaluate(BASE, {**BASE, "p95_ms": 110})["passed"]


def test_insufficient_samples_are_not_passed():
    assert not gate.evaluate(BASE, {**BASE, "requests": 20})["passed"]


def test_incomparable_load_is_not_passed():
    assert not gate.evaluate(BASE, {**BASE, "concurrency": 2})["passed"]
    assert not gate.evaluate(BASE, {**BASE, "warmup_requests": 100})["passed"]


def test_regressions_fail():
    assert not gate.evaluate(BASE, {**BASE, "p95_ms": 121})["passed"]
    assert not gate.evaluate(BASE, {**BASE, "error_rate": .02})["passed"]
    assert not gate.evaluate(BASE, {**BASE, "unexpected_statuses": 5})["passed"]
