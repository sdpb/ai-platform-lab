// Constant arrival rate against one endpoint, from inside the cluster. Prints the metrics as JSON.
import http from 'k6/http';

export const options = {
  scenarios: {
    load: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE),
      timeUnit: '1s',
      duration: __ENV.DURATION,
      preAllocatedVUs: 50,
      maxVUs: 500,
    },
  },
  summaryTrendStats: ['p(50)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  http.request(__ENV.METHOD || 'GET', `http://app:8000${__ENV.ENDPOINT}`, null, { timeout: '35s' });
}

export function handleSummary(data) {
  return { stdout: JSON.stringify(data.metrics) };
}
