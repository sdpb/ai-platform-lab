// Steady order traffic through the in-cluster Service while pods are disrupted.
// Runs inside the cluster: a port-forward pins one pod and would break when that pod dies.
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    orders: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 20),
      timeUnit: '1s',
      duration: __ENV.DURATION || '60s',
      preAllocatedVUs: 20,
      maxVUs: 400, // enough to keep the arrival rate when latency climbs; dropped_iterations shows when it is not
    },
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
  // The Week 3 metric: zero failed requests while a replica is terminated.
  thresholds: { http_req_failed: ['rate==0'] },
};

const body = JSON.stringify({ customer_id: 'k6', sku: 'widget', quantity: 1, unit_price_cents: 100 });

export default function () {
  const res = http.post(`${__ENV.BASE_URL}/orders`, body, {
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': `k6-${__VU}-${__ITER}-${Date.now()}` },
  });
  check(res, { 'order created': (r) => r.status === 201 });
}


