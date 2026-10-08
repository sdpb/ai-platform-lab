import asyncio
import os
import random
import re
import uuid
from contextlib import asynccontextmanager

import httpx
import psycopg
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse, Response
from opentelemetry import propagate, trace
from prometheus_client import CONTENT_TYPE_LATEST, Counter, generate_latest
from psycopg_pool import PoolTimeout

from orderlab.common import install_telemetry, log, pool_from_env, require_admin, setup_tracing
from orderlab.models import APIFaults, OrderRequest

tracer, trace_provider = setup_tracing("orders-api")
dependency_calls = Counter("orderlab_dependency_attempts_total", "Payment HTTP attempts", ["outcome"])
ORDER_COLUMNS = "id, customer_id, sku, quantity, unit_price_cents, total_cents, status, payment_id, created_at, updated_at"
INTERNAL_COLUMNS = ORDER_COLUMNS + ", request_hash"


@asynccontextmanager
async def lifespan(app):
    await asyncio.sleep(float(os.getenv("STARTUP_DELAY_SECONDS", "0")))
    app.state.pool = pool_from_env()
    await app.state.pool.open(wait=True)
    app.state.client = httpx.AsyncClient(
        base_url=os.getenv("PAYMENTS_URL", "http://payments:8000"),
        timeout=float(os.getenv("DEPENDENCY_TIMEOUT", ".4")),
    )
    app.state.faults = APIFaults(fail_every=int(os.getenv("INITIAL_FAIL_EVERY", "0")))
    app.state.order_calls = 0
    log("started", service="orders-api", version=os.getenv("APP_VERSION", "local"))
    yield
    await app.state.client.aclose()
    await app.state.pool.close()
    trace_provider.shutdown()
    log("stopped", service="orders-api")


app = FastAPI(title="OrderLab — Orders API", version="1.0.0", lifespan=lifespan)
install_telemetry(app, "orders-api", tracer)


@app.exception_handler(PoolTimeout)
@app.exception_handler(psycopg.OperationalError)
async def database_unavailable(request, exc):
    log("database_unavailable", error_type=type(exc).__name__)
    return JSONResponse({"detail": "Database unavailable or pool exhausted; retry later"}, status_code=503)


@app.get("/health/live")
async def live():
    return {"status": "alive"}


@app.get("/health/ready")
async def ready(request: Request):
    if request.app.state.faults.not_ready:
        raise HTTPException(503, "Readiness fault enabled")
    async with request.app.state.pool.connection() as conn:
        await conn.execute("SELECT 1")
    return {"status": "ready"}


@app.get("/version")
async def version():
    return {"version": os.getenv("APP_VERSION", "local"), "schema_contract": "v1"}


@app.get("/metrics", include_in_schema=False)
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/admin/faults", dependencies=[Depends(require_admin)])
async def get_faults(request: Request):
    return request.app.state.faults


@app.put("/admin/faults", dependencies=[Depends(require_admin)])
async def set_faults(faults: APIFaults, request: Request):
    request.app.state.faults = faults
    request.app.state.order_calls = 0
    log("faults_changed", service="orders-api", faults=faults.model_dump())
    return faults


@app.get("/admin/pool", dependencies=[Depends(require_admin)])
async def pool_stats(request: Request):
    return request.app.state.pool.get_stats()


async def charge(request, order):
    # Retries occur in this one layer only. The downstream uses order.id as its
    # durable idempotency key, including when a reply is lost after commit.
    attempts = max(1, min(int(os.getenv("DEPENDENCY_ATTEMPTS", "3")), 8))
    for attempt in range(attempts):
        with tracer.start_as_current_span("payments.charge", kind=trace.SpanKind.CLIENT) as span:
            span.set_attribute("retry.attempt", attempt + 1)
            headers = {}
            propagate.inject(headers)
            try:
                response = await request.app.state.client.post("/charges", headers=headers, json={
                    "order_id": str(order["id"]), "amount_cents": order["total_cents"],
                })
                dependency_calls.labels(str(response.status_code)).inc()
                if response.status_code == 402:
                    return None
                if response.status_code == 409:
                    raise HTTPException(409, "Payment idempotency conflict")
                if response.status_code < 500 and response.status_code != 429:
                    response.raise_for_status()
                    return response.json()["id"]
            except (httpx.TimeoutException, httpx.NetworkError) as exc:
                dependency_calls.labels(type(exc).__name__).inc()
                span.set_status(trace.StatusCode.ERROR)
            if attempt + 1 < attempts:
                await asyncio.sleep(random.uniform(0, min(.05 * 2**attempt, .4)))
    raise HTTPException(503, "Payment dependency unavailable; retry with the same Idempotency-Key")


@app.post("/orders", status_code=201)
async def create_order(payload: OrderRequest, request: Request,
                       idempotency_key: str = Header(alias="Idempotency-Key")):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", idempotency_key):
        raise HTTPException(422, "Idempotency-Key must be 1–100 letters, digits, underscores or hyphens")
    faults = request.app.state.faults.model_copy()
    request.app.state.order_calls += 1
    if faults.latency_ms:
        await asyncio.sleep(faults.latency_ms / 1000)
    if faults.fail_every and request.app.state.order_calls % faults.fail_every == 0:
        raise HTTPException(503, "Injected release regression")
    pool = request.app.state.pool
    # Commit the intent before performing an external side effect. Even if the
    # second transaction rolls back, a subsequent retry uses the same order ID.
    async with pool.connection() as conn:
        await conn.execute(
            """INSERT INTO orders(id, idempotency_key, request_hash, customer_id, sku,
                quantity, unit_price_cents, total_cents, status)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,'pending')
               ON CONFLICT (idempotency_key) DO NOTHING""",
            (uuid.uuid4(), idempotency_key, payload.fingerprint(), payload.customer_id,
             payload.sku, payload.quantity, payload.unit_price_cents,
             payload.quantity * payload.unit_price_cents),
        )
    replayed = False
    with tracer.start_as_current_span("orders.confirm"):
        # Per-order row lock serializes concurrent retries. Deliberately bounded
        # synchronous orchestration: pool contention is a lab exercise.
        async with pool.connection() as conn:
            row = await (await conn.execute(
                f"SELECT {INTERNAL_COLUMNS} FROM orders WHERE idempotency_key=%s FOR UPDATE", (idempotency_key,)
            )).fetchone()
            if row["request_hash"] != payload.fingerprint():
                raise HTTPException(409, "Idempotency-Key already used with a different payload")
            if faults.db_hold_ms:
                await asyncio.sleep(faults.db_hold_ms / 1000)
            if row["status"] == "pending":
                payment_id = await charge(request, row)
                row = await (await conn.execute(
                    f"""UPDATE orders SET status=%s, payment_id=%s, updated_at=clock_timestamp()
                       WHERE id=%s RETURNING {INTERNAL_COLUMNS}""",
                    ("confirmed" if payment_id else "rejected", payment_id, row["id"]),
                )).fetchone()
            else:
                replayed = True
    # The write is committed before delaying the response. Retrying the same
    # key after a client timeout cannot create a second order/payment.
    if faults.response_delay_after_commit_ms:
        await asyncio.sleep(faults.response_delay_after_commit_ms / 1000)
    return JSONResponse(jsonable_encoder(public_order(row)), status_code=200 if replayed else 201,
                        headers={"Idempotent-Replayed": str(replayed).lower()})


def public_order(row):
    return {k: v for k, v in row.items() if k not in ("request_hash", "idempotency_key", "currency")}


@app.get("/orders")
async def list_orders(request: Request, limit: int = 20):
    if not 1 <= limit <= 100:
        raise HTTPException(422, "limit must be between 1 and 100")
    async with request.app.state.pool.connection() as conn:
        rows = await (await conn.execute(
            f"SELECT {ORDER_COLUMNS} FROM orders ORDER BY created_at DESC, id DESC LIMIT %s", (limit,)
        )).fetchall()
    return {"orders": [public_order(row) for row in rows]}


@app.get("/orders/{order_id}")
async def get_order(order_id: uuid.UUID, request: Request):
    async with request.app.state.pool.connection() as conn:
        row = await (await conn.execute(f"SELECT {ORDER_COLUMNS} FROM orders WHERE id=%s", (order_id,))).fetchone()
    if not row:
        raise HTTPException(404, "Order not found")
    return public_order(row)
