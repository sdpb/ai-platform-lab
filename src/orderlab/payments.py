import asyncio
import uuid
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, generate_latest
from pydantic import BaseModel, Field
from starlette.responses import Response

from orderlab.common import install_telemetry, log, pool_from_env, require_admin, setup_tracing
from orderlab.models import StubFaults

tracer, trace_provider = setup_tracing("payments-stub")
ledger_writes = Counter("orderlab_payment_commits_total", "Unique payment side effects")


@asynccontextmanager
async def lifespan(app):
    app.state.pool = pool_from_env()
    await app.state.pool.open(wait=True)
    app.state.faults = StubFaults()
    app.state.calls = 0
    yield
    await app.state.pool.close()
    trace_provider.shutdown()


app = FastAPI(title="OrderLab — Controllable Payment Stub", lifespan=lifespan)
install_telemetry(app, "payments-stub", tracer)


class Charge(BaseModel):
    order_id: uuid.UUID
    amount_cents: int = Field(ge=0, le=1_000_000_000)


@app.get("/health/ready")
async def ready(request: Request):
    async with request.app.state.pool.connection() as conn:
        await conn.execute("SELECT 1")
    return {"status": "ready"}


@app.get("/metrics", include_in_schema=False)
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/admin/faults", dependencies=[Depends(require_admin)])
async def get_faults(request: Request):
    return request.app.state.faults


@app.put("/admin/faults", dependencies=[Depends(require_admin)])
async def set_faults(faults: StubFaults, request: Request):
    request.app.state.faults = faults
    request.app.state.calls = 0
    log("faults_changed", service="payments-stub", faults=faults.model_dump())
    return faults


@app.post("/charges")
async def charge(payload: Charge, request: Request):
    state = request.app.state
    state.calls += 1
    faults = state.faults.model_copy()
    fail = bool(faults.fail_next or (faults.fail_every and state.calls % faults.fail_every == 0))
    if state.faults.fail_next:
        state.faults.fail_next -= 1
    if faults.latency_ms:
        await asyncio.sleep(faults.latency_ms / 1000)
    if fail:
        raise HTTPException(503, "Injected transient dependency failure")
    with tracer.start_as_current_span("payments.commit"):
        async with state.pool.connection() as conn:
            # Persist declines as well as successful charges. Serialize decisions
            # before any outcome so a late retry cannot reverse a terminal result.
            await conn.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))", (str(payload.order_id),))
            decision = await (await conn.execute(
                "SELECT amount_cents,rejected FROM payment_decisions WHERE order_id=%s", (payload.order_id,)
            )).fetchone()
            if decision and decision["amount_cents"] != payload.amount_cents:
                raise HTTPException(409, "Order already charged for a different amount")
            inserted = None
            if not decision:
                decision = {"amount_cents": payload.amount_cents, "rejected": faults.decline}
                await conn.execute(
                    "INSERT INTO payment_decisions(order_id,amount_cents,rejected) VALUES (%s,%s,%s)",
                    (payload.order_id, payload.amount_cents, faults.decline),
                )
                if not faults.decline:
                    inserted = await (await conn.execute(
                        "INSERT INTO payments(id,order_id,amount_cents) VALUES (%s,%s,%s) RETURNING id,order_id",
                        (uuid.uuid4(), payload.order_id, payload.amount_cents),
                    )).fetchone()
            row = inserted or await (await conn.execute(
                "SELECT id,order_id FROM payments WHERE order_id=%s", (payload.order_id,)
            )).fetchone()
    if decision["rejected"]:
        # Raise only after committing the durable rejection.
        raise HTTPException(402, "Synthetic payment declined")
    if inserted:
        ledger_writes.inc()
        if faults.timeout_after_commit_ms:
            await asyncio.sleep(faults.timeout_after_commit_ms / 1000)
    return {"id": str(row["id"]), "order_id": str(row["order_id"]), "replayed": not bool(inserted)}
