"""
Tiny FastAPI demo service that emits OpenTelemetry traces.

Three endpoints, each illustrating a different span shape:

  GET /        — fast, single auto-instrumented span (the FastAPI request)
  GET /work    — auto span + two nested manual spans (fake DB + fake HTTP)
  GET /error   — span flagged as ERROR with an exception recorded

Traces leave the process via OTLP/gRPC to the OTEL_EXPORTER_OTLP_ENDPOINT
(set in the k8s manifest to point at the otel-collector Service).
"""

import os
import random
import time

from fastapi import FastAPI, HTTPException
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "demo-app")

# A Resource is a set of attributes that describe *the entity producing the
# telemetry* — here, this app instance. The collector will add more (host,
# k8s.*) on top of these when it processes the span.
resource = Resource.create({"service.name": SERVICE_NAME})

provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)

tracer = trace.get_tracer(__name__)
app = FastAPI()
FastAPIInstrumentor.instrument_app(app)


@app.get("/")
def root():
    return {"ok": True, "service": SERVICE_NAME}


@app.get("/work")
def work():
    """Simulate a request that does a DB lookup and an external HTTP call."""
    with tracer.start_as_current_span("fake-db-query") as span:
        span.set_attribute("db.system", "postgresql")
        span.set_attribute("db.statement", "SELECT * FROM users WHERE id = $1")
        time.sleep(random.uniform(0.01, 0.05))

    with tracer.start_as_current_span("fake-http-call") as span:
        span.set_attribute("http.method", "GET")
        span.set_attribute("http.url", "https://api.example.com/profile")
        time.sleep(random.uniform(0.02, 0.08))
        span.set_attribute("http.status_code", 200)

    return {"ok": True, "did": ["db", "http"]}


@app.get("/error")
def error():
    """Produce a span with status=error and a recorded exception."""
    with tracer.start_as_current_span("buggy-operation") as span:
        try:
            raise RuntimeError("simulated failure for demo purposes")
        except RuntimeError as exc:
            span.record_exception(exc)
            span.set_status(trace.Status(trace.StatusCode.ERROR, str(exc)))
            raise HTTPException(status_code=500, detail=str(exc))
