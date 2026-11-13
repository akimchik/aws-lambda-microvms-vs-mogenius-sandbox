# Demo Runbook: Kubernetes Agent Sandbox (mogenius) vs. AWS MicroVMs

This runbook contains step-by-step instructions to run a live demo comparing **AWS Lambda MicroVMs** and **Kubernetes Agent Sandbox (mogenius)** on your local Minikube cluster.

> [!IMPORTANT]
> **Host OS & Architecture Prerequisites (macOS, Linux & Windows WSL 2):**
> - **Cross-Platform Guide:** For comprehensive setup on **Linux (Ubuntu/Debian/RHEL)**, **Windows (WSL 2)**, or **macOS**, along with **`aarch64` (Apple Silicon)** vs. **`x86_64` (AMD64/Intel)** architecture specifics, refer to the [Multi-OS & Multi-Architecture Setup Guide](MULTI_OS_SETUP_GUIDE.md).
> - **Memory:** Allocate **10 GB – 12 GB RAM** in Docker settings / WSL config. My bootstrap script creates `minikube` with an 8,192 MB limit and adds `minikube-m02` with Minikube's default (~4 GB limit). The converged, idle stack uses ~5 GiB and ran in an 8.8 GB Docker VM, so 10–12 GB is headroom for cold image pulls and sustained load; on Docker's default 4 GB, expect `OOMKilled` (Exit Code 137) restarts on Grafana, MongoDB, or gVisor sandbox pods.
> - **CPUs:** Allocate **4+ vCPUs** to prevent CPU throttling during concurrent 70 RPS load generation.
> - **Disk:** Ensure **40 GB+ free disk space**. The containerd image stores on the two nodes measured **~8.2 GB** (5.1 GB + 3.1 GB); see the breakdown in the [README](../README.md#-container-image-footprint-82-gb-on-disk).

---

## 📋 Zero-to-Hero Provisioning & Self-Healing Bootstrapper

Whether starting from a completely wiped environment (`minikube delete`) or waking the cluster after a laptop reboot or partial component drift, run my 8-stage idempotent reconciler:

```bash
# Reconcile all 8 architecture layers (or pass --upgrade-helm to force Helm chart upgrades)
./k8s-agent-sandbox/scripts/bootstrap_cluster.sh
```

What `bootstrap_cluster.sh` automatically checks and converges against the codebase:
1. **Multi-Node Topology (`minikube` + `minikube-m02`):** Starts the control-plane node, adds the dedicated worker node `minikube-m02` if missing, and applies the `dedicated=testkube:NoSchedule` taint and labels.
2. **Host Resolution & Addon Cleanup:** Maps `control-plane.minikube.internal` in `/etc/hosts` and disables the legacy `gvisor` addon.
3. **Native gVisor (`runsc`) Runtime:** Installs the official Google `runsc` binary inside the node if missing, deduplicates `/etc/containerd/config.toml`, restarts `containerd`, and registers `RuntimeClass: gvisor`.
4. **NGINX Ingress Controller:** Enables and waits for `ingress-nginx-controller` readiness.
5. **Observability Stack (`monitoring`):** Deploys `kube-prometheus-stack` via Helm and reconciles `monitoring-ingress.yaml` plus all 3 Grafana dashboards.
6. **Agent Sandbox & Dynamic Router (`agent-sandbox-system` / `agent-sandbox`):** Deploys `mogenius-agent-sandbox` (`v1.2.1`), `sandbox-router`, `sandbox-ingress`, `ServiceMonitor`, and `sandbox-latency-exporter`.
7. **Out-of-Sandbox Egress & Credential Broker (`sandbox-egress-system`):** Reconciles `egress-broker.yaml` and cross-namespace zero-trust `NetworkPolicy` rules.
8. **Testkube OSS & Automated Workflows (`testkube` on `minikube-m02`):** Deploys Testkube OSS (`v2.14.2`) pinned strictly to `minikube-m02`, applies RBAC (`rbac.yaml`), and registers both `agent-sandbox-benchmark` and `agent-sandbox-security-audit`.

---

## 🧪 Automated 60 QPS Load & Red-Team Security Workflows (Testkube OSS)

All load generation and security fuzzing workloads execute exclusively on the isolated worker node `minikube-m02` so they never contend with the gVisor sandboxes on `minikube`:

```bash
# 1. Run the 60 QPS Ingress Performance & Warm Pool Claim Latency Benchmark (with scale-to-zero)
testkube run tw agent-sandbox-benchmark -f

# 2. Run the Continuous Red-Team Security Audit (In-Guest T1-T6 Probe + k6 Egress Broker Fuzzing)
testkube run tw agent-sandbox-security-audit -f

# 3. Run the High-Throughput Sustained Load Benchmark (70 RPS / 10,500 requests targeting active sandbox without restarts)
testkube run tw agent-sandbox-sustained-load -f

# 4. Inspect past executions
testkube get twe
```

* **Dedicated Testkube & Security Grafana Dashboard:**
  * `http://grafana.127.0.0.1.nip.io/d/testkube-agent-benchmarks/testkube-agent-sandbox-benchmark-dashboard`
* **Sandbox HTTP Responses & Latency Comparison Dashboard:**
  * `http://grafana.127.0.0.1.nip.io/d/sandbox-http-responses/sandbox-ingress-and-http-responses-comparison-dashboard`

---

## 🌐 Ingress & Observability Access

### Accessing Prometheus & Grafana via Ingress
Both Prometheus and Grafana are routed via the NGINX Ingress controller:

* **Grafana Dashboard:**
  * Host URL: `http://grafana.127.0.0.1.nip.io` (or `http://grafana.local`)
  * Username: `admin` | Password: `admin`
  * Pre-loaded Dashboard: **Kubernetes Agent Sandbox (mogenius) Observability**
* **Prometheus Targets & Query UI:**
  * Host URL: `http://prometheus.127.0.0.1.nip.io` (or `http://prometheus.local`)

*(Note: On macOS Docker driver, you can access Ingress via `minikube tunnel` or by port-forwarding the Ingress controller: `kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80`)*

---

## 🔀 Demo Step 0: Sandbox Ingress & Dynamic Routing POC

In AWS, API Gateway routes traffic to Lambda MicroVMs using custom headers (`X-aws-proxy-port` or `X-Tenant`). In Kubernetes, `sandbox-router` and Ingress handle dynamic routing to isolated gVisor pods without exposing container ports:

```bash
# Run the automated Ingress & Routing POC script:
./k8s-agent-sandbox/ingress/test_ingress_poc.sh
```

Or manually:
```bash
# 1. Claim a Sandbox from the warm pool
kubectl -n agent-sandbox apply -f - <<EOF
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata: { name: demo-ingress-claim }
spec:
  warmPoolRef: { name: default }
  lifecycle: { shutdownPolicy: Delete }
EOF

# 2. Get the assigned Sandbox ID
kubectl wait --for=condition=Ready sandboxclaim/demo-ingress-claim -n agent-sandbox --timeout=15s
SANDBOX_ID=$(kubectl -n agent-sandbox get sandboxclaim demo-ingress-claim -o jsonpath='{.status.sandbox.name}')

# 3. Route HTTP traffic through sandbox-router to the sandbox
kubectl run test-curl --image=curlimages/curl --restart=Never --rm -i --command -- \
  curl -s -i -H "X-Sandbox-ID: ${SANDBOX_ID}" \
             -H "X-Sandbox-Namespace: agent-sandbox" \
             -H "X-Sandbox-Port: 8080" \
             http://sandbox-router.agent-sandbox-system.svc.cluster.local:8080/healthz

# 4. Clean up
kubectl -n agent-sandbox delete sandboxclaim demo-ingress-claim
```

---

## 🚀 Demo Step 1: Basic Execution & Kernel Isolation (Module 1 Parity)

In AWS, I launched a MicroVM with `aws lambda-microvms run-microvm` and hit `/execute`. In Kubernetes, I claim an isolated gVisor sandbox from the warm pool.

### 1.1 Claim a Sandbox from the Warm Pool
```bash
cat <<EOF | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: demo-module1-claim
  namespace: agent-sandbox
spec:
  warmPoolRef:
    name: default
  lifecycle:
    shutdownPolicy: Delete
EOF
```

### 1.2 Wait for Instant Binding (<1s) & Get Pod Name
```bash
kubectl wait --for=condition=Ready sandboxclaim/demo-module1-claim -n agent-sandbox --timeout=10s
POD_NAME=$(kubectl -n agent-sandbox get sandboxclaim demo-module1-claim -o jsonpath='{.status.sandbox.name}')
echo "Allocated Sandbox Pod: $POD_NAME"
```

### 1.3 Verify Kernel-Level Isolation (gVisor Proof)
Show the audience that this pod does **not** share the host Linux kernel:
```bash
kubectl -n agent-sandbox exec $POD_NAME -- dmesg | head -n 5
```
*Expected output:*
```text
[    0.000000] Starting gVisor...
[    0.248910] Generating random numbers by fair dice roll...
[    0.956987] Creating cloned children...
[    1.397637] Synthesizing system calls...
```

### 1.4 Execute Untrusted Code
```bash
kubectl -n agent-sandbox exec $POD_NAME -- python3 -c "import platform, sys; print(f'Executed inside Sandbox: {platform.system()} Python {sys.version.split()[0]}')"
```

### 1.5 Release Sandbox (Scale-to-Zero)
```bash
kubectl -n agent-sandbox delete sandboxclaim demo-module1-claim
```
*Notice:* The claimed pod terminates automatically, and the warm pool immediately replenishes a fresh standby pod in the background.

---

## ⚡ Demo Step 2: Ephemeral CI/CD Warm Pool Runner (Module 3 Parity)

In AWS, I booted an ephemeral microVM to execute `ci/steps.sh` on git push and report results. Here, I do the same natively in Kubernetes without cold-start latency.

### 2.1 Claim a Runner Sandbox
```bash
cat <<EOF | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: demo-ci-runner
  namespace: agent-sandbox
spec:
  warmPoolRef:
    name: default
  lifecycle:
    shutdownPolicy: Delete
EOF

kubectl wait --for=condition=Ready sandboxclaim/demo-ci-runner -n agent-sandbox --timeout=10s
CI_POD=$(kubectl -n agent-sandbox get sandboxclaim demo-ci-runner -o jsonpath='{.status.sandbox.name}')
echo "CI Runner Sandbox: $CI_POD"
```

### 2.2 Copy Repository & Run Test Pipeline
```bash
# Copy the ci-demo folder into the isolated sandbox workspace
kubectl -n agent-sandbox cp ./aws-lambda-microvms/ci-demo $CI_POD:/home/coder/project/ci-demo

# Execute the test pipeline inside the sandboxed environment
kubectl -n agent-sandbox exec $CI_POD -- bash -c "cd /home/coder/project/ci-demo && python3 -m unittest discover tests"
```

### 2.3 Automatic Tear Down
```bash
kubectl -n agent-sandbox delete sandboxclaim demo-ci-runner
```
*Result:* The build environment is wiped cleanly. Zero persistent residue, zero idle compute cost.

---

## 🏢 Demo Step 3: Multi-Tenant SaaS Isolation (Module 4 Parity)

Demonstrate tenant workspace isolation where each tenant gets a dedicated gVisor sandbox and persistent storage.

### 3.1 Claim Dedicated Sandboxes for Tenant A and Tenant B
```bash
# Claim Tenant A
cat <<EOF | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: tenant-alpha-claim
  namespace: agent-sandbox
spec:
  warmPoolRef:
    name: default
  lifecycle:
    shutdownPolicy: Delete
EOF

# Claim Tenant B
cat <<EOF | kubectl apply -f -
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: tenant-beta-claim
  namespace: agent-sandbox
spec:
  warmPoolRef:
    name: default
  lifecycle:
    shutdownPolicy: Delete
EOF
```

### 3.2 Verify Tenant Pods and Storage Isolation
```bash
kubectl wait --for=condition=Ready sandboxclaim/tenant-alpha-claim -n agent-sandbox --timeout=10s
kubectl wait --for=condition=Ready sandboxclaim/tenant-beta-claim -n agent-sandbox --timeout=10s

POD_ALPHA=$(kubectl -n agent-sandbox get sandboxclaim tenant-alpha-claim -o jsonpath='{.status.sandbox.name}')
POD_BETA=$(kubectl -n agent-sandbox get sandboxclaim tenant-beta-claim -o jsonpath='{.status.sandbox.name}')

# Tenant Alpha creates private data
kubectl -n agent-sandbox exec $POD_ALPHA -- bash -c "echo 'CONFIDENTIAL_ALPHA_DATA' > /home/coder/project/secret.txt"

# Tenant Beta attempts to access it (completely isolated)
kubectl -n agent-sandbox exec $POD_BETA -- ls -la /home/coder/project/
```
*Result:* Tenant Beta has a completely separate filesystem and mount namespace. Neither tenant shares memory or kernel syscall access with the host or each other.

### 3.3 Cleanup
```bash
kubectl -n agent-sandbox delete sandboxclaim tenant-alpha-claim tenant-beta-claim
```

---

## 📊 Summary of What to Highlight in the Demo

1. **Sub-second Start:** Sandboxes allocate in `< 500ms` thanks to `SandboxWarmPool`.
2. **True Kernel Sandboxing:** Every container syscall is intercepted by Google gVisor (`runsc`), providing microVM-grade defense without bare-metal hypervisor complexity.
3. **Native Kubernetes Control Plane:** No custom fleet manager, no AWS API rate limits, no proprietary IAM token vending machine. It uses standard Kubernetes CRDs, RBAC, and NetworkPolicies.
4. **Automatic Replenishment:** When a sandbox is claimed, the warm pool automatically provisions the next standby instance in the background.
