import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom Metrics
export const successRate = new Rate('sandbox_success_rate');
export const manifestLatency = new Trend('sandbox_manifest_duration_ms');
export const healthLatency = new Trend('sandbox_health_duration_ms');

// Strict Rate Limiting: Exactly 60 QPS (15s duration)
export const options = {
  scenarios: {
    sandbox_rate_limited: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.QPS) || 60,
      timeUnit: '1s',
      duration: __ENV.BENCH_DURATION || '15s',
      preAllocatedVUs: 20,
      maxVUs: 60,
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.25'], // Up to 20% deliberate 404 negative tests
    http_req_duration: ['p(95)<150'], // 95% latency SLA < 150ms
  },
};

const BASE_URL = __ENV.TARGET_URL;
if (!BASE_URL) {
  throw new Error('FATAL: TARGET_URL environment variable is required. Example: TARGET_URL=http://$(minikube ip):80 k6 run ...');
}
const SANDBOX_ID = __ENV.SANDBOX_ID;
const SANDBOX_NAMESPACE = 'agent-sandbox';
const SANDBOX_PORT = '8080';

const HEADERS = {
  'Host': 'sandbox.127.0.0.1.nip.io',
  'X-Sandbox-ID': SANDBOX_ID,
  'X-Sandbox-Namespace': SANDBOX_NAMESPACE,
  'X-Sandbox-Port': SANDBOX_PORT,
  'User-Agent': 'k6-testkube-benchmark',
};

export default function () {
  const rand = Math.random();
  if (rand < 0.55) {
    // 55% Static Manifest
    const res = http.get(`${BASE_URL}/manifest.json`, { headers: HEADERS });
    const ok = check(res, { 'manifest is 200': (r) => r.status === 200 });
    successRate.add(ok);
    manifestLatency.add(res.timings.duration);
  } else if (rand < 0.85) {
    // 30% API Health
    const res = http.get(`${BASE_URL}/healthz`, { headers: HEADERS });
    const ok = check(res, { 'health is 200': (r) => r.status === 200 });
    successRate.add(ok);
    healthLatency.add(res.timings.duration);
  } else {
    // 15% Deliberate 404 Negative Test
    const res = http.get(`${BASE_URL}/nonexistent-probe`, { headers: HEADERS });
    check(res, { 'nonexistent is 404': (r) => r.status === 404 });
  }
}
