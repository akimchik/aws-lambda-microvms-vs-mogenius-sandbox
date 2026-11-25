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

Whether starting from a completely wiped environment (`minikube delete`) or waking the cluster after a laptop reboot or partial component drift, run the Ansible bootstrapper:

```bash
# 0. Fast verification suite (143 unit, live HTTP runtime, POSIX /bin/sh & Jinja2 tests, zero VM spin-up)
make check

# 1. Non-mutating read-only audit (runs ansible-playbook --check --diff, 0 changes made)
make dry-run

# 2. Host toolchain discovery & preflight setup only ([0/8])
make preflight

# 3. Full 8-stage declarative cluster reconciliation via Ansible
make cluster

# Or pass custom memory on 8 GB hosts/VMs to prevent RSRC_OVER_ALLOC_MEM:
# make cluster ARGS="--memory 6144"
# (Recommended: expand VM memory to 10 GB on host: VBoxManage modifyvm "<VM_NAME>" --memory 10240)
```

The root `Makefile` and `bootstrap_cluster.sh` CLI wrapper delegate all 8 reconciliation layers to `k8s-agent-sandbox/ansible/playbooks/site.yml` (using zero-pip `ansible.builtin.*` modules):
1. **Multi-Node Topology (`minikube` + `minikube-m02`):** Starts the control-plane node, adds the dedicated worker node `minikube-m02` if missing, applies the `dedicated=testkube:NoSchedule` taint and labels, and dynamically captures the real `minikube ip` into the `minikube_ip` Ansible fact.
2. **Host Resolution & Addon Cleanup:** Maps `control-plane.minikube.internal` in `/etc/hosts` and disables the legacy `gvisor` addon.
3. **Native gVisor (`runsc`) Runtime:** Installs the official Google `runsc` binary inside the node if missing, deduplicates `/etc/containerd/config.toml`, restarts `containerd`, and registers `RuntimeClass: gvisor`.
4. **NGINX Ingress Controller:** Enables and waits for `ingress-nginx-controller` readiness.
5. **Observability Stack (`monitoring`):** Deploys `kube-prometheus-stack` via Helm and reconciles `monitoring-ingress.yaml` plus all 3 Grafana dashboards.
6. **Agent Sandbox & Dynamic Router (`agent-sandbox-system` / `agent-sandbox`):** Deploys `mogenius-agent-sandbox` (`v1.2.1`), `sandbox-router`, `sandbox-ingress`, `ServiceMonitor`, and `sandbox-latency-exporter`.
7. **Out-of-Sandbox Egress & Credential Broker (`sandbox-egress-system`):** Reconciles `egress-broker.yaml` and cross-namespace zero-trust `NetworkPolicy` rules.
8. **Testkube OSS & Dynamic Templated Workflows (`testkube` on `minikube-m02`):** Deploys Testkube OSS (`v2.14.2`) pinned strictly to `minikube-m02`, applies RBAC (`rbac.yaml`), renders the Jinja2 workflow templates (`k8s-agent-sandbox/testkube/templates/test-workflow*.yaml.j2`) with the dynamic `{{ minikube_ip }}`, and registers all 3 TestWorkflows (`agent-sandbox-benchmark`, `agent-sandbox-security-audit`, and `agent-sandbox-sustained-load`).

---

## 🧪 Automated 60 QPS Load & Red-Team Security Workflows (Testkube OSS)

All load generation and security fuzzing workloads execute exclusively on the isolated worker node `minikube-m02` so they never contend with the gVisor sandboxes on `minikube`:

```bash
# 1. Run the 60 QPS Ingress Performance & Warm Pool Claim Latency Benchmark (with scale-to-zero)
make test-benchmark
# (Or override parameters: make test-benchmark DURATION=30s QPS=80)

# 2. Run the Continuous Red-Team Security Audit (In-Guest T1-T6 Probe + k6 Egress Broker Fuzzing)
make test-security
# (Or override duration: make test-security DURATION=1m)

# 3. Run the High-Throughput Sustained Load Benchmark (70 RPS targeting active sandbox without restarts)
make test-load
# (Or custom 2-minute Scaled-Out run across 3 sandboxes: make test-load DURATION=2m QPS=100 SANDBOX_COUNT=3)

# 4. Inspect past executions
testkube get twe
```

---

## 🎬 Live Demo Choreography: Drift Detection, Container Freshness, Scale-Up & Scale-Out

Use this 5-part self-contained sequence to demonstrate every testing approach, container freshness guarantee, live security drift detection & self-healing, vertical scaling (**Scaled-Up**), and horizontal warm-pool scaling (**Scaled-Out**). Every scenario below includes the **exact execution command**, **exact terminal verification command**, and **expected output**—no extra planning or manual calculation required.

### Pre-Demo: Verify Local Integration Suite & Open Live Terminal/Grafana Watchers
Before running cluster scenarios, you can prove that the entire multi-OS bootstrap, live `egress-broker` + `threat_probe.py` policy engine, `sandbox-latency-exporter` metrics server, and `/bin/sh -e` TestWorkflow scripts pass 143/143 checks in ~15 seconds without touching a VM:

```bash
# 1. Execute the 143-test Multi-OS, Multi-Arch & Live Component Runtime Suite
make check

# 2. (Optional) Open a second terminal to watch warm-pool standby & claimed pods in real time
kubectl -n agent-sandbox get pods,sandboxclaims -w
```

* **Dedicated Testkube & Security Grafana Dashboard:**
  * `http://grafana.127.0.0.1.nip.io/d/testkube-agent-benchmarks/testkube-agent-sandbox-benchmark-dashboard`
* **Sandbox HTTP Responses & Latency Comparison Dashboard:**
  * `http://grafana.127.0.0.1.nip.io/d/sandbox-http-responses/sandbox-ingress-and-http-responses-comparison-dashboard`

---

### Act 1: Fresh Container / Code Rollout Proof (`FORCE_FRESH=true`)
Every benchmark and security run supports a **Freshness Gate** (`FORCE_FRESH=true`, enabled by default on `test-benchmark` and `test-security`). It evicts pre-existing warm-pool standby pods, waits for the controller (`warmPool.updateStrategy: Immediate`) to provision fresh standby pods, stamps `CODE_VERSION` into `/home/coder/project/.code_version`, measures true pod birth age via `/proc/uptime` (`warm` `<350ms` vs `cold`), and audits in-guest Linux cgroup v2 limits (`/sys/fs/cgroup/cpu.max` and `/sys/fs/cgroup/memory.max`):

```bash
# 1. Run the 60 QPS benchmark with explicit fresh pod recycling and version stamp
make test-benchmark CODE_VERSION=v2.1.0-fresh FORCE_FRESH=true QPS=60 DURATION=15s

# 2. Verify the recorded freshness, launch_type, and cgroup audit directly from the exporter
kubectl -n agent-sandbox exec deploy/sandbox-latency-exporter -- \
  wget -qO- http://127.0.0.1:9102/metrics | grep -E "agent_sandbox_(claim_controller_startup_latency_ms_count|active_test_sandboxes)"
```
* **What to observe in the terminal output:**
  * `[Freshness Gate] Deleting pre-existing standby pods (app=sandbox)...`
  * `[Sandbox 1/1] Claimed pod: default-... (Latency: ~220-350ms, Launch: warm)`
  * `[Audit] default-... -> version=v2.1.0-fresh | cpu.max=100000 100000 | memory.max=1073741824`

---

### Act 2: Simulating Live Security Drift & Self-Healing (`T6B` Vector `1 -> 0 -> 1`)
Demonstrate that the platform detects real-time L7 egress policy drift—not static or mocked statuses—and self-heals via Ansible:

```bash
# 1. Baseline Check: Verify all 6/6 threat vectors (T1-T6C) are currently PASS (1)
make test-security DURATION=15s QPS=10
kubectl -n agent-sandbox exec deploy/sandbox-latency-exporter -- \
  wget -qO- http://127.0.0.1:9102/metrics | grep 'agent_sandbox_security_'

# 2. Inject Live Security Drift: Whitelist an unauthorized external host (example.com) on egress-broker
kubectl -n sandbox-egress-system set env deployment/egress-broker EXTRA_ALLOWED_HOSTS="example.com"
kubectl -n sandbox-egress-system rollout status deployment/egress-broker --timeout=60s

# 3. Trigger Red-Team Security Audit to catch the drift
make test-security DURATION=15s QPS=10 || true

# 4. Verify in terminal (and on Grafana) that T6B flipped to 0 (FAIL EXPOSED) and passed count dropped to 5/6
kubectl -n agent-sandbox exec deploy/sandbox-latency-exporter -- \
  wget -qO- http://127.0.0.1:9102/metrics | grep -E 'agent_sandbox_security_(checks_passed|vector_status\{vector="T6B_BROKER_POLICY_ENFORCEMENT"\})'
```
* **Expected output after Step 4:**
  ```text
  agent_sandbox_security_checks_passed 5
  agent_sandbox_security_vector_status{vector="T6B_BROKER_POLICY_ENFORCEMENT"} 0
  ```
  *(On the Grafana Testkube & Security Dashboard, the `T6B_BROKER_POLICY_ENFORCEMENT` panel immediately turns **RED `FAIL (EXPOSED)`** and the workflow exits non-zero).*

```bash
# 5. Self-Heal Drift: Re-run Ansible cluster reconciliation (or unset EXTRA_ALLOWED_HOSTS) and re-verify
make cluster
make test-security DURATION=15s QPS=10
kubectl -n agent-sandbox exec deploy/sandbox-latency-exporter -- \
  wget -qO- http://127.0.0.1:9102/metrics | grep -E 'agent_sandbox_security_(checks_passed|vector_status\{vector="T6B_BROKER_POLICY_ENFORCEMENT"\})'
```
* **Expected output after Step 5:**
  ```text
  agent_sandbox_security_checks_passed 6
  agent_sandbox_security_vector_status{vector="T6B_BROKER_POLICY_ENFORCEMENT"} 1
  ```
  *(Grafana returns to **GREEN `6/6 PASS (SECURED)`**).*

---

### Act 3: Scaled-Up Mode (Vertical CPU & Memory Scaling Verified Inside gVisor)
Prove how vertical resource limits propagate into the gVisor sandbox cgroup hierarchy and affect 60 QPS tail latency:

```bash
# 1. Constrained Profile (250m CPU / 512Mi RAM)
helm upgrade --install agent-sandbox mogenius/mogenius-agent-sandbox \
  -n agent-sandbox-system -f k8s-agent-sandbox/helm/values-mogenius.yaml \
  --set sandboxes.profiles.default.resources.limits.cpu=250m \
  --set sandboxes.profiles.default.resources.limits.memory=512Mi

make test-benchmark CODE_VERSION=v1-constrained FORCE_FRESH=true QPS=60 DURATION=15s
```
* **Expected terminal audit output:** `version=v1-constrained | cpu.max=25000 100000 | memory.max=536870912` (`0.25 vCPU` quota / `512 MiB` ceiling) with higher p95 response times under 60 QPS load.

```bash
# 2. Scaled-Up Profile (2 vCPUs / 2Gi RAM)
helm upgrade --install agent-sandbox mogenius/mogenius-agent-sandbox \
  -n agent-sandbox-system -f k8s-agent-sandbox/helm/values-mogenius.yaml \
  --set sandboxes.profiles.default.resources.limits.cpu=2 \
  --set sandboxes.profiles.default.resources.limits.memory=2Gi

make test-benchmark CODE_VERSION=v2-scaled-up FORCE_FRESH=true QPS=60 DURATION=15s
```
* **Expected terminal audit output:** `version=v2-scaled-up | cpu.max=200000 100000 | memory.max=2147483648` (`2.0 vCPU` quota / `2 GiB` ceiling) and p95 latency `< 15ms`.

---

### Act 4: Scaled-Out Mode (Horizontal Warm-Pool Exhaustion vs. Multi-Sandbox Round-Robin Load)
Prove the difference between an under-provisioned warm pool (`replicas=1`, where concurrent agent claims trigger cold starts) and a horizontally scaled warm pool (`replicas=3`, where all 3 claims bind sub-second from standby and `k6` distributes load round-robin across all 3 sandboxes):

```bash
# 1. Under-Provisioned Warm Pool (replicas=1) vs. 3 Concurrent Sandbox Claims (SANDBOX_COUNT=3)
helm upgrade --install agent-sandbox mogenius/mogenius-agent-sandbox \
  -n agent-sandbox-system -f k8s-agent-sandbox/helm/values-mogenius.yaml \
  --set sandboxes.profiles.default.warmPool.replicas=1
kubectl -n agent-sandbox wait --for=condition=Ready pod --all --timeout=90s

make test-benchmark SANDBOX_COUNT=3 CODE_VERSION=v2-pool-1 FORCE_FRESH=false QPS=90 DURATION=20s
```
* **What to observe in Testkube logs & Grafana:**
  * `[Sandbox 1/3]` binds in `~220ms (Launch: warm)` (consumes the sole standby pod).
  * `[Sandbox 2/3]` and `[Sandbox 3/3]` experience `>2,000ms (Launch: cold)` startup latency because the warm pool was exhausted and had to cold-boot 2 new gVisor pods on demand.

```bash
# 2. Scaled-Out Warm Pool (replicas=3) with 3 Concurrent Claims & 90-100 RPS Multi-Sandbox Round-Robin Load
helm upgrade --install agent-sandbox mogenius/mogenius-agent-sandbox \
  -n agent-sandbox-system -f k8s-agent-sandbox/helm/values-mogenius.yaml \
  --set sandboxes.profiles.default.warmPool.replicas=3
kubectl -n agent-sandbox wait --for=condition=Ready pod --all --timeout=90s

# Verify 3 warm standby pods are Ready before claiming
kubectl -n agent-sandbox get pods -l app=sandbox

# Run 60s multi-sandbox benchmark (all 3 active sandboxes remain visible in 'kubectl get pods' and Grafana for 60s)
make test-benchmark SANDBOX_COUNT=3 CODE_VERSION=v2-scaled-out-3 FORCE_FRESH=false QPS=90 DURATION=60s

# Or run a 2-minute sustained 100 RPS load test distributed round-robin across 3 sandboxes
make test-load SANDBOX_COUNT=3 DURATION=2m QPS=100

# (Optional Cleanup) Restore default 1-replica warm pool after the demo
helm upgrade --install agent-sandbox mogenius/mogenius-agent-sandbox \
  -n agent-sandbox-system -f k8s-agent-sandbox/helm/values-mogenius.yaml
```
* **What to observe in Testkube logs & Grafana:**
  * All 3 claims (`[Sandbox 1/3]`, `[Sandbox 2/3]`, `[Sandbox 3/3]`) bind in `<350ms (Launch: warm)`.
  * `agent_sandbox_active_test_sandboxes` reports `3` in Grafana.
  * `k6` distributes requests round-robin across all 3 sandbox IDs via the `X-Sandbox-ID` header (`[k6] Target URL: ... | Pool Size: 3 sandbox(es) | IDs: default-...,default-...,default-...`).

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

*(Note on Ingress Access across OSes:
  • **macOS:** Run `minikube tunnel` (which bridges `127.0.0.1` on Darwin), or run port-forwarding: `kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80`.
  • **Linux Native:** `minikube tunnel` does not proxy localhost for NodePort Ingress. Use `kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80` for `127.0.0.1.nip.io:8080` access, or access directly via `http://grafana.$(minikube ip).nip.io`.
  • **Linux VM (VirtualBox / UTM):** If running in a VM on a bridged or host-only network, run `kubectl -n ingress-nginx port-forward --address 0.0.0.0 svc/ingress-nginx-controller 8080:80` and map `<VM-LAN-IP> grafana.local prometheus.local sandbox.local` in your host `/etc/hosts` for direct browser access. See [Section 2.F of the Multi-OS Setup Guide](MULTI_OS_SETUP_GUIDE.md#f-performance-optimizations-for-linux-virtual-machines-virtualbox--utm) for details).*

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
