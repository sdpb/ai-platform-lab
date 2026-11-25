// Release gate: steady traffic through the Service while the api rolls out, then a bake period.
// k6 aborts (exit code 99) as soon as a threshold is crossed; the caller then rolls back.
import http from 'k6/http';

const abort = { abortOnFail: true, delayAbortEval: '15s' }; // >= 300 samples before the first verdict

export const options = {
  scenarios: {
    gate: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 20),
      timeUnit: '1s',
      duration: __ENV.DURATION || '30s',
      preAllocatedVUs: 20,
      maxVUs: 200,
    },
  },
  summaryTrendStats: ['p(50)', 'p(95)', 'p(99)', 'max'],
  thresholds: __ENV.P95_LIMIT_MS
    ? {
        http_req_failed: [{ threshold: 'rate<0.01', ...abort }],
        http_req_duration: [{ threshold: `p(95)<${__ENV.P95_LIMIT_MS}`, ...abort }],
      }
    : {}, // baseline run: measure only
};

const body = JSON.stringify({ customer_id: 'gate', sku: 'widget', quantity: 1, unit_price_cents: 100 });

export default function () {
  http.post(`${__ENV.BASE_URL}/orders`, body, {
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': `gate-${__VU}-${__ITER}-${Date.now()}` },
  });
}

export function handleSummary(data) {
  const m = data.metrics;
  return {
    stdout: JSON.stringify({
      requests: m.http_reqs.values.count,
      error_rate: m.http_req_failed.values.rate,
      p95_ms: m.http_req_duration.values['p(95)'],
      thresholds_crossed: Object.entries(m)
        .filter(([, v]) => v.thresholds && Object.values(v.thresholds).some((t) => !t.ok))
        .map(([k]) => k),
    }) + '\n',
  };
}
