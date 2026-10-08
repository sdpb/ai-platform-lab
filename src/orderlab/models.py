import hashlib
import json

from pydantic import BaseModel, Field


class OrderRequest(BaseModel):
    customer_id: str = Field(min_length=1, max_length=80, pattern=r"^[\w-]+$")
    sku: str = Field(min_length=1, max_length=80, pattern=r"^[\w-]+$")
    quantity: int = Field(ge=1, le=1000)
    unit_price_cents: int = Field(ge=0, le=1_000_000)

    def fingerprint(self):
        return hashlib.sha256(json.dumps(self.model_dump(), sort_keys=True).encode()).hexdigest()


class APIFaults(BaseModel):
    latency_ms: int = Field(default=0, ge=0, le=5000)
    fail_every: int = Field(default=0, ge=0, le=1000)
    db_hold_ms: int = Field(default=0, ge=0, le=4000)
    response_delay_after_commit_ms: int = Field(default=0, ge=0, le=5000)
    not_ready: bool = False


class StubFaults(BaseModel):
    latency_ms: int = Field(default=0, ge=0, le=5000)
    fail_next: int = Field(default=0, ge=0, le=10000)
    fail_every: int = Field(default=0, ge=0, le=1000)
    timeout_after_commit_ms: int = Field(default=0, ge=0, le=5000)
    decline: bool = False
