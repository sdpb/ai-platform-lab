"""Bottleneck hunt, seeded version: three planted problems. Do not copy into real services."""
import hashlib
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from psycopg_pool import AsyncConnectionPool

history = []  # Seeded leak: "kept for debugging", never trimmed.


@asynccontextmanager
async def lifespan(app):
    # Seeded: one connection for the whole process, and callers wait up to 30 s for it.
    app.state.pool = AsyncConnectionPool(conninfo="", min_size=1, max_size=1, timeout=30, open=False)
    await app.state.pool.open(wait=True)
    yield
    await app.state.pool.close()


app = FastAPI(lifespan=lifespan)


@app.get("/cpu")
def cpu():
    # About 10 ms of pure CPU per request (key stretching), in the threadpool.
    return {"digest": hashlib.pbkdf2_hmac("sha256", b"order", b"salt", 20_000).hex()[:16]}


@app.post("/remember")
async def remember():
    history.append(bytearray(64 * 1024))  # 64 KiB per request, retained forever
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
