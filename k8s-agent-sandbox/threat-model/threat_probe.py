#!/usr/bin/env python3
"""
Red-Team AI Sandbox Threat Probe
Tests 6 key threat surfaces:
  T1: Cloud IMDS & Host SSRF (169.254.169.254)
  T2: Kubernetes API Lateral Movement (10.96.0.1:443)
  T3: Internal Cluster Service Discovery (Prometheus / Service ClusterIPs)
  T4: Ambient In-Guest Credentials (K8s ServiceAccount tokens, Cloud keys, Env vars)
  T5: Raw External DNS Tunneling / Exfiltration (UDP 8.8.8.8:53)
  T6: Egress Filtering & Credential Broker Validation
"""

import os
import sys
import json
import time
import socket
import ssl
import urllib.request
import urllib.error
from pathlib import Path

TIMEOUT = 2.5

def check_imds_ssrf():
    url = "http://169.254.169.254/latest/meta-data/"
    start = time.time()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "threat-probe"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            elapsed = (time.time() - start) * 1000
            content = resp.read(64).decode(errors="ignore")
            return {
                "id": "T1_IMDS_SSRF",
                "name": "Cloud IMDS & SSRF Probe",
                "target": url,
                "status": "FAIL (EXPOSED)",
                "latency_ms": round(elapsed, 2),
                "detail": f"VULNERABLE: IMDS returned HTTP {resp.status}: {content[:30]}..."
            }
    except Exception as e:
        elapsed = (time.time() - start) * 1000
        return {
            "id": "T1_IMDS_SSRF",
            "name": "Cloud IMDS & SSRF Probe",
            "target": url,
            "status": "PASS (BLOCKED)",
            "latency_ms": round(elapsed, 2),
            "detail": f"Connection blocked / timed out: {type(e).__name__}"
        }

def check_k8s_api_lateral():
    k8s_host = os.environ.get("KUBERNETES_SERVICE_HOST") or "10.96.0.1"
    k8s_port = os.environ.get("KUBERNETES_SERVICE_PORT") or "443"
    target = f"https://{k8s_host}:{k8s_port}/version"
    start = time.time()
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        req = urllib.request.Request(target, headers={"User-Agent": "threat-probe"})
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=ctx) as resp:
            elapsed = (time.time() - start) * 1000
            data = resp.read(64).decode(errors="ignore")
            return {
                "id": "T2_K8S_API_LATERAL",
                "name": "K8s API Lateral Movement",
                "target": target,
                "status": "FAIL (EXPOSED)",
                "latency_ms": round(elapsed, 2),
                "detail": f"VULNERABLE: Connected to Kubernetes API: {data[:30]}..."
            }
    except Exception as e:
        elapsed = (time.time() - start) * 1000
        return {
            "id": "T2_K8S_API_LATERAL",
            "name": "K8s API Lateral Movement",
            "target": target,
            "status": "PASS (BLOCKED)",
            "latency_ms": round(elapsed, 2),
            "detail": f"Access blocked: {type(e).__name__}"
        }

def check_internal_service_lateral():
    target = "http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090/-/healthy"
    start = time.time()
    try:
        req = urllib.request.Request(target, headers={"User-Agent": "threat-probe"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            elapsed = (time.time() - start) * 1000
            return {
                "id": "T3_INTERNAL_SVC_LATERAL",
                "name": "Internal Service Discovery",
                "target": target,
                "status": "FAIL (EXPOSED)",
                "latency_ms": round(elapsed, 2),
                "detail": f"VULNERABLE: Connected to internal Prometheus HTTP {resp.status}"
            }
    except Exception as e:
        elapsed = (time.time() - start) * 1000
        return {
            "id": "T3_INTERNAL_SVC_LATERAL",
            "name": "Internal Service Discovery",
            "target": target,
            "status": "PASS (BLOCKED)",
            "latency_ms": round(elapsed, 2),
            "detail": f"Service blocked: {type(e).__name__}"
        }

def check_ambient_credentials():
    start = time.time()
    findings = []
    
    # 1. K8s ServiceAccount token
    sa_token_path = Path("/var/run/secrets/kubernetes.io/serviceaccount/token")
    if sa_token_path.exists():
        findings.append("K8s ServiceAccount token mounted in /var/run/secrets")
        
    # 2. Local SSH / AWS keys
    home = Path.home()
    if (home / ".ssh").exists() and any((home / ".ssh").iterdir()):
        findings.append("~/.ssh directory contains keys")
    if (home / ".aws").exists() and any((home / ".aws").iterdir()):
        findings.append("~/.aws directory contains credentials")
        
    # 3. Sensitive Env Vars
    sensitive_keys = []
    for k in os.environ:
        upper = k.upper()
        if any(term in upper for term in ["AWS_SECRET", "AWS_ACCESS", "GITHUB_TOKEN", "ANTHROPIC_API_KEY", "SSH_KEY"]):
            sensitive_keys.append(k)
            
    if sensitive_keys:
        findings.append(f"Sensitive env vars present: {', '.join(sensitive_keys)}")
        
    elapsed = (time.time() - start) * 1000
    if findings:
        return {
            "id": "T4_AMBIENT_CREDENTIALS",
            "name": "Ambient Credential Harvesting",
            "target": "Filesystem & Environment",
            "status": "FAIL (EXPOSED)",
            "latency_ms": round(elapsed, 2),
            "detail": " | ".join(findings)
        }
    return {
        "id": "T4_AMBIENT_CREDENTIALS",
        "name": "Ambient Credential Harvesting",
        "target": "Filesystem & Environment",
        "status": "PASS (ZERO_IN_GUEST_CREDENTIALS)",
        "latency_ms": round(elapsed, 2),
        "detail": "Zero service account tokens, zero cloud keys, zero ambient secrets found in container"
    }

def check_raw_dns_exfiltration():
    # Build standard DNS query packet for 'exfil-test.example.com' (A record)
    target_ip = "8.8.8.8"
    port = 53
    start = time.time()
    query = (
        b"\xaa\xbb"  # ID
        b"\x01\x00"  # Flags: Standard query
        b"\x00\x01"  # Questions: 1
        b"\x00\x00"  # Answer RRs: 0
        b"\x00\x00"  # Authority RRs: 0
        b"\x00\x00"  # Additional RRs: 0
        b"\x0aexfil-test\x07example\x03com\x00" # Name
        b"\x00\x01"  # Type: A
        b"\x00\x01"  # Class: IN
    )
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(TIMEOUT)
    try:
        sock.sendto(query, (target_ip, port))
        data, _ = sock.recvfrom(512)
        elapsed = (time.time() - start) * 1000
        sock.close()
        return {
            "id": "T5_RAW_DNS_EXFILTRATION",
            "name": "Direct UDP/53 DNS Tunneling",
            "target": f"{target_ip}:{port}",
            "status": "FAIL (EXPOSED)",
            "latency_ms": round(elapsed, 2),
            "detail": f"VULNERABLE: Direct UDP socket reached public DNS server {target_ip} ({len(data)} bytes received)"
        }
    except Exception as e:
        elapsed = (time.time() - start) * 1000
        sock.close()
        return {
            "id": "T5_RAW_DNS_EXFILTRATION",
            "name": "Direct UDP/53 DNS Tunneling",
            "target": f"{target_ip}:{port}",
            "status": "PASS (BLOCKED)",
            "latency_ms": round(elapsed, 2),
            "detail": f"Raw UDP DNS to external resolver blocked: {type(e).__name__}"
        }

def check_unrestricted_http_egress():
    c2_target = "http://example.com"
    start = time.time()
    try:
        req = urllib.request.Request(c2_target, headers={"User-Agent": "threat-probe"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            elapsed = (time.time() - start) * 1000
            return {
                "id": "T6A_DIRECT_C2_EGRESS",
                "name": "Direct Arbitrary C2 Egress",
                "target": c2_target,
                "status": "FAIL (EXPOSED)",
                "latency_ms": round(elapsed, 2),
                "detail": f"VULNERABLE: Unrestricted outbound connection to arbitrary external host HTTP {resp.status}"
            }
    except Exception as e:
        elapsed = (time.time() - start) * 1000
        return {
            "id": "T6A_DIRECT_C2_EGRESS",
            "name": "Direct Arbitrary C2 Egress",
            "target": c2_target,
            "status": "PASS (BLOCKED)",
            "latency_ms": round(elapsed, 2),
            "detail": f"Direct external egress blocked: {type(e).__name__}"
        }

def check_broker_egress(broker_url):
    results = []
    
    # 1. Blocked via broker
    c2_url = f"{broker_url}/proxy?url=http://example.com"
    start = time.time()
    try:
        req = urllib.request.Request(c2_url, headers={"User-Agent": "threat-probe"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            elapsed = (time.time() - start) * 1000
            results.append({
                "id": "T6B_BROKER_POLICY_ENFORCEMENT",
                "name": "Broker L7 Domain Filtering",
                "target": c2_url,
                "status": "FAIL (EXPOSED)",
                "latency_ms": round(elapsed, 2),
                "detail": f"Broker allowed unauthorized domain: HTTP {resp.status}"
            })
    except urllib.error.HTTPError as e:
        elapsed = (time.time() - start) * 1000
        if e.code == 403:
            results.append({
                "id": "T6B_BROKER_POLICY_ENFORCEMENT",
                "name": "Broker L7 Domain Filtering",
                "target": c2_url,
                "status": "PASS (BLOCKED_BY_BROKER)",
                "latency_ms": round(elapsed, 2),
                "detail": "Broker successfully rejected unwhitelisted FQDN with HTTP 403 Forbidden"
            })
        else:
            results.append({
                "id": "T6B_BROKER_POLICY_ENFORCEMENT",
                "name": "Broker L7 Domain Filtering",
                "target": c2_url,
                "status": "FAIL (EXPOSED)",
                "latency_ms": round(elapsed, 2),
                "detail": f"Broker did not reject with HTTP 403 (returned HTTP {e.code})"
            })
    except Exception as e:
        elapsed = (time.time() - start) * 1000
        results.append({
            "id": "T6B_BROKER_POLICY_ENFORCEMENT",
            "name": "Broker L7 Domain Filtering",
            "target": c2_url,
            "status": "FAIL (ERROR)",
            "latency_ms": round(elapsed, 2),
            "detail": f"Broker unreachable: {type(e).__name__}"
        })

    # 2. Credential Injection via broker
    auth_url = f"{broker_url}/github-api/repo-metadata"
    start = time.time()
    try:
        req = urllib.request.Request(auth_url, headers={"User-Agent": "threat-probe"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            elapsed = (time.time() - start) * 1000
            body = json.loads(resp.read().decode())
            injected = body.get("token_injected", False)
            auth_header_present = body.get("auth_header_present", False)
            token_ttl_seconds = body.get("token_ttl_seconds", 0)
            if injected and auth_header_present:
                results.append({
                    "id": "T6C_OUT_OF_SANDBOX_AUTH",
                    "name": "Zero-In-Guest Credential Broker",
                    "target": auth_url,
                    "status": "PASS (BROKER_INJECTED)",
                    "latency_ms": round(elapsed, 2),
                    "detail": f"SUCCESS: Short-lived token (TTL {token_ttl_seconds}s) injected on-the-wire outside guest. Agent holds 0 secrets."
                })
            else:
                results.append({
                    "id": "T6C_OUT_OF_SANDBOX_AUTH",
                    "name": "Zero-In-Guest Credential Broker",
                    "target": auth_url,
                    "status": "FAIL (TOKEN_MISSING)",
                    "latency_ms": round(elapsed, 2),
                    "detail": f"Broker response missing auth verification: {body}"
                })
    except Exception as e:
        elapsed = (time.time() - start) * 1000
        results.append({
            "id": "T6C_OUT_OF_SANDBOX_AUTH",
            "name": "Zero-In-Guest Credential Broker",
            "target": auth_url,
            "status": "FAIL (ERROR)",
            "latency_ms": round(elapsed, 2),
            "detail": f"Credential broker call failed: {type(e).__name__}"
        })

    return results

def main():
    print("=" * 80)
    print("AI SANDBOX THREAT MODEL RED-TEAM PROBE")
    print("Host / Pod Context: " + socket.gethostname())
    print("Timestamp: " + time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    print("=" * 80)

    results = []
    results.append(check_imds_ssrf())
    results.append(check_k8s_api_lateral())
    results.append(check_internal_service_lateral())
    results.append(check_ambient_credentials())
    results.append(check_raw_dns_exfiltration())
    results.append(check_unrestricted_http_egress())

    broker_url = os.environ.get("EGRESS_BROKER_URL")
    if broker_url:
        results.extend(check_broker_egress(broker_url))

    # Format Markdown Table
    print("\n### 🛡️ Threat Assessment Scorecard\n")
    print("| Vector ID | Threat Surface | Target | Status | Latency | Details |")
    print("| :--- | :--- | :--- | :--- | :--- | :--- |")
    for r in results:
        status_icon = "🟢" if "PASS" in r["status"] else "🔴"
        print(f"| `{r['id']}` | **{r['name']}** | `{r['target']}` | {status_icon} **{r['status']}** | {r['latency_ms']}ms | {r['detail']} |")

    # JSON export
    print("\n--- JSON OUTPUT ---")
    print(json.dumps(results, indent=2))

if __name__ == "__main__":
    main()
