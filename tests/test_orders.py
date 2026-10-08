import asyncio
import os
import uuid
from pathlib import Path

import httpx
import psycopg
import pytest

API = os.getenv("API_URL", "http://localhost:8000")
STUB = os.getenv("STUB_URL", "http://localhost:8001")
TOKEN = os.environ["LAB_ADMIN_TOKEN"]
BODY = {"customer_id": "test-customer", "sku": "widget", "quantity": 2, "unit_price_cents": 1250}


@pytest.fixture(autouse=True)
async def client():
    async with httpx.AsyncClient(timeout=8) as client:
        for base in (API, STUB):
            (await client.put(base + "/admin/faults", json={}, headers={"X-Lab-Token": TOKEN})).raise_for_status()
        yield client
        for base in (API, STUB):
            (await client.put(base + "/admin/faults", json={}, headers={"X-Lab-Token": TOKEN})).raise_for_status()


async def submit(client, key=None, body=None):
    return await client.post(API + "/orders", json=body or BODY,
                             headers={"Idempotency-Key": key or uuid.uuid4().hex})


async def faults(client, base, **kwargs):
    response = await client.put(base + "/admin/faults", json=kwargs, headers={"X-Lab-Token": TOKEN})
    response.raise_for_status()


def counts(order_id):
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        return conn.execute("SELECT count(*) FROM payments WHERE order_id=%s", (order_id,)).fetchone()[0]


async def test_order_persists_and_has_correlated_trace(client):
    result = await submit(client)
    assert result.status_code == 201, result.text
    order = result.json()
    assert order["total_cents"] == 2500
    assert order["status"] == "confirmed"
    assert int(result.headers["x-trace-id"], 16) != 0
    fetched = await client.get(API + "/orders/" + order["id"])
    assert fetched.json() == order
    assert counts(order["id"]) == 1


async def test_concurrent_duplicate_requests_are_one_business_effect(client):
    key = uuid.uuid4().hex
    responses = await asyncio.gather(*(submit(client, key) for _ in range(12)))
    assert all(r.status_code in (200, 201) for r in responses), [r.text for r in responses]
    assert len({r.json()["id"] for r in responses}) == 1
    assert sum(r.status_code == 201 for r in responses) == 1
    assert counts(responses[0].json()["id"]) == 1


async def test_same_key_different_payload_is_conflict(client):
    key = uuid.uuid4().hex
    first = await submit(client, key)
    conflict = await submit(client, key, {**BODY, "quantity": 3})
    assert first.status_code == 201
    assert conflict.status_code == 409
    assert counts(first.json()["id"]) == 1


async def test_timeout_after_payment_commit_is_retried_without_duplicate_charge(client):
    await faults(client, STUB, timeout_after_commit_ms=900)
    response = await submit(client)
    assert response.status_code == 201, response.text
    assert response.json()["status"] == "confirmed"
    assert counts(response.json()["id"]) == 1


async def test_client_loses_response_after_order_commit(client):
    key = uuid.uuid4().hex
    await faults(client, API, response_delay_after_commit_ms=600)
    with pytest.raises(httpx.ReadTimeout):
        await client.post(API + "/orders", json=BODY, headers={"Idempotency-Key": key}, timeout=.2)
    await faults(client, API)
    replay = await submit(client, key)
    assert replay.status_code == 200
    assert replay.headers["idempotent-replayed"] == "true"
    assert counts(replay.json()["id"]) == 1


async def test_exhausted_dependency_recovers_same_pending_order(client):
    key = uuid.uuid4().hex
    await faults(client, STUB, fail_next=100)
    failed = await submit(client, key)
    assert failed.status_code == 503
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        row = conn.execute("SELECT id,status FROM orders WHERE idempotency_key=%s", (key,)).fetchone()
    assert row[1] == "pending"
    assert counts(row[0]) == 0
    state = (await client.get(STUB + "/admin/faults", headers={"X-Lab-Token": TOKEN})).json()
    assert state["fail_next"] == 97  # retry budget is three attempts
    await faults(client, STUB)
    recovered = await submit(client, key)
    assert recovered.status_code == 201
    assert recovered.json()["id"] == str(row[0])
    assert counts(row[0]) == 1


async def test_decline_is_terminal_and_not_retried(client):
    await faults(client, STUB, decline=True)
    key = uuid.uuid4().hex
    declined = await submit(client, key)
    assert declined.status_code == 201
    assert declined.json()["status"] == "rejected"
    await faults(client, STUB)
    assert (await submit(client, key)).json()["status"] == "rejected"
    assert counts(declined.json()["id"]) == 0


async def test_payment_decision_survives_fault_change(client):
    order_id = uuid.uuid4().hex
    body = {"order_id": order_id, "amount_cents": 100}
    original = await client.post(STUB + "/charges", json=body)
    assert original.status_code == 200
    await faults(client, STUB, decline=True)
    replay = await client.post(STUB + "/charges", json=body)
    assert replay.json()["id"] == original.json()["id"]
    rejected_body = {**body, "order_id": uuid.uuid4().hex}
    assert (await client.post(STUB + "/charges", json=rejected_body)).status_code == 402
    await faults(client, STUB)
    assert (await client.post(STUB + "/charges", json=rejected_body)).status_code == 402


async def test_late_inflight_charge_cannot_reverse_a_decline(client):
    body = {"order_id": uuid.uuid4().hex, "amount_cents": 100}
    await faults(client, STUB, latency_ms=500)
    late = asyncio.create_task(client.post(STUB + "/charges", json=body))
    await asyncio.sleep(.1)
    await faults(client, STUB, decline=True)
    assert (await client.post(STUB + "/charges", json=body)).status_code == 402
    assert (await late).status_code == 402
    assert counts(body["order_id"]) == 0


async def test_liveness_independent_of_readiness_and_dependency(client):
    await faults(client, API, not_ready=True)
    await faults(client, STUB, fail_next=100)
    assert (await client.get(API + "/health/live")).status_code == 200
    assert (await client.get(API + "/health/ready")).status_code == 503
    await faults(client, API)
    assert (await client.get(API + "/health/ready")).status_code == 200


async def test_fault_controls_require_token_and_validate_bounds(client):
    assert (await client.put(API + "/admin/faults", json={"fail_every": 1})).status_code == 403
    assert (await client.put(STUB + "/admin/faults", json={"latency_ms": -1},
                             headers={"X-Lab-Token": TOKEN})).status_code == 422
    assert (await client.post(API + "/orders", json=BODY)).status_code == 422
    assert (await submit(client, body={**BODY, "quantity": -1})).status_code == 422


async def test_expanded_schema_backfill_keeps_v1_compatible(client):
    response = await submit(client)
    order_id = response.json()["id"]
    # Warm prepared statements before changing the table shape. SELECT * breaks
    # this contract even when the added column is nullable.
    for _ in range(50):
        assert (await client.get(API + "/orders/" + order_id)).status_code == 200
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        conn.execute(Path("db/migrations/002_expand.sql").read_text())
        conn.execute(Path("db/migrations/003_backfill.sql").read_text())
        conn.execute(Path("db/migrations/003_backfill.sql").read_text())
        # Emulate a new writer's added field; old API must still read the row.
        conn.execute("UPDATE orders SET currency='EUR' WHERE id=%s", (order_id,))
    assert (await client.get(API + "/orders/" + order_id)).status_code == 200
    assert (await submit(client)).status_code == 201
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        assert conn.execute("SELECT currency FROM orders WHERE id=%s", (order_id,)).fetchone()[0] == "EUR"


async def test_metrics_use_route_templates_not_order_ids(client):
    order = (await submit(client)).json()
    await client.get(API + "/orders/" + order["id"])
    metrics = (await client.get(API + "/metrics")).text
    assert 'route="/orders/{order_id}"' in metrics
    assert order["id"] not in metrics
