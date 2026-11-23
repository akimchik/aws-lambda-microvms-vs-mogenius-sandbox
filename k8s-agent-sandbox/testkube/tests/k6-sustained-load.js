import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom Metrics
export const successRate = new Rate('sandbox_success_rate');
export const manifestLatency = new Trend('sandbox_manifest_duration_ms');

// Sustained High-Throughput Scenario: 70 RPS for ~10,000 Total Requests
export const options = {
  scenarios: {
    sustained_10k_traffic: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.QPS) || 70,
      timeUnit: '1s',
      duration: __ENV.BENCH_DURATION || '150s', // 150s * 70 RPS = 10,500 requests
      preAllocatedVUs: 20,
      maxVUs: 60,
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'], // 99% success rate
    http_req_duration: ['p(95)<120'], // 95% latency SLA < 120ms
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
  'User-Agent': 'k6-testkube-sustained-load',
};

export default function () {
  // Fire high-throughput requests at the sandbox workbench manifest
  const res = http.get(`${BASE_URL}/manifest.json`, { headers: HEADERS });
  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
  });
  successRate.add(ok);
  manifestLatency.add(res.timings.duration);
}
