"""Bottleneck hunt, fixed version. `diff base/seeded.py base/fixed.py` shows the code fixes."""
import hashlib
from collections import deque
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from psycopg_pool import AsyncConnectionPool, PoolTimeout

history = deque(maxlen=100)  # Fix: bounded; the last 100 items are enough for debugging.


@asynccontextmanager
async def lifespan(app):
    # Fix: size the pool to in-flight queries (rate x query time x headroom), well under the
    # database's max_connections; fail fast after 1 s so overload becomes a visible 503, not a 30 s queue.
    app.state.pool = AsyncConnectionPool(conninfo="", min_size=2, max_size=10, timeout=1, open=False)
    await app.state.pool.open(wait=True)
    yield
    await app.state.pool.close()


app = FastAPI(lifespan=lifespan)


@app.exception_handler(PoolTimeout)
async def overloaded(request, exc):
    # Fix: a distinct, retryable "overloaded" answer instead of a generic 500.
    return JSONResponse({"detail": "database pool saturated; retry later"}, status_code=503)


@app.get("/cpu")
def cpu():
    # About 10 ms of pure CPU per request (key stretching), in the threadpool.
    return {"digest": hashlib.pbkdf2_hmac("sha256", b"order", b"salt", 20_000).hex()[:16]}


@app.post("/remember")
async def remember():
    history.append(bytearray(64 * 1024))  # still 64 KiB per request, but only 100 are kept
    return {"kept": len(history)}


@app.get("/db")
async def db():
    async with app.state.pool.connection() as conn:
        await conn.execute("SELECT pg_sleep(0.02)")  # a 20 ms query
    return {"ok": True}


def cgroup(name):
    return Path("/sys/fs/cgroup", name).read_text()


@app.get("/use")
def use():
    """USE signals from inside the container: utilization, saturation, errors."""
    cpu_stat = dict(line.split() for line in cgroup("cpu.stat").splitlines())
    events = dict(line.split() for line in cgroup("memory.events").splitlines())
    return {
        "cpu_usage_usec": int(cpu_stat["usage_usec"]),
        "cpu_periods": int(cpu_stat.get("nr_periods", 0)),
        "cpu_throttled_periods": int(cpu_stat.get("nr_throttled", 0)),
        "cpu_throttled_usec": int(cpu_stat.get("throttled_usec", 0)),
        "memory_bytes": int(cgroup("memory.current")),
        "memory_limit": cgroup("memory.max").strip(),
        "memory_oom_kills": int(events.get("oom_kill", 0)),
        "pool": app.state.pool.get_stats(),
        "retained_items": len(history),
    }
