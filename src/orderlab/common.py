import hmac
import json
import logging
import os
import re
import time
import uuid

from fastapi import Header, HTTPException, Request
from opentelemetry import propagate, trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import Counter, Histogram
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger("orderlab")


def log(event, **fields):
    logger.info(json.dumps({"event": event, **fields}, default=str))


def setup_tracing(service):
    provider = TracerProvider(resource=Resource.create({"service.name": service}))
    endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    if endpoint:
        provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(
            endpoint=endpoint.rstrip("/") + "/v1/traces", timeout=3
        )))
    trace.set_tracer_provider(provider)
    return trace.get_tracer(service), provider


def pool_from_env():
    return AsyncConnectionPool(
        os.environ["DATABASE_URL"], min_size=1,
        max_size=int(os.getenv("DB_POOL_SIZE", "8")), open=False,
        timeout=float(os.getenv("DB_POOL_TIMEOUT", "1")),
        kwargs={"row_factory": dict_row, "options": "-c statement_timeout=5000 -c lock_timeout=3000"},
    )


def require_admin(x_lab_token: str = Header(default="")):
    expected = os.getenv("LAB_ADMIN_TOKEN", "")
    if not expected or not hmac.compare_digest(x_lab_token, expected):
        raise HTTPException(403, "Lab admin token required")


def install_telemetry(app, service, tracer):
    requests = Counter("orderlab_requests_total", "Completed HTTP requests", ["service", "route", "method", "status"])
    latency = Histogram("orderlab_request_duration_seconds", "HTTP response latency", ["service", "route"],
                        buckets=(.005, .01, .025, .05, .1, .2, .4, .8, 1.6, 3.2, 6.4))

    @app.middleware("http")
    async def observe(request: Request, call_next):
        request_id = request.headers.get("x-request-id", "")
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", request_id):
            request_id = uuid.uuid4().hex
        start = time.perf_counter()
        status = 500
        with tracer.start_as_current_span("http.request", context=propagate.extract(request.headers),
                                          kind=trace.SpanKind.SERVER) as span:
            trace_id = format(span.get_span_context().trace_id, "032x")
            request.state.request_id = request_id
            try:
                response = await call_next(request)
                status = response.status_code
                response.headers["X-Request-ID"] = request_id
                response.headers["X-Trace-ID"] = trace_id
                response.headers["X-App-Version"] = os.getenv("APP_VERSION", "local")
                return response
            finally:
                route = getattr(request.scope.get("route"), "path", "unmatched")
                elapsed = time.perf_counter() - start
                requests.labels(service, route, request.method, str(status)).inc()
                latency.labels(service, route).observe(elapsed)
                span.update_name(f"{request.method} {route}")
                span.set_attribute("http.response.status_code", status)
                span.set_attribute("http.route", route)
                if status >= 500:
                    span.set_status(trace.StatusCode.ERROR)
                if route not in ("/metrics", "/health/live", "/health/ready"):
                    log("http_request", service=service, method=request.method, route=route,
                        status=status, duration_ms=round(elapsed * 1000, 2),
                        request_id=request_id, trace_id=trace_id)
