# Secure AI Agent Code Execution Platform: AWS Lambda MicroVMs vs. Kubernetes Agent Sandbox (`mogenius` + `gVisor`)

![Secure AI Agent Code Execution Platform: AWS Lambda MicroVMs vs. Kubernetes Agent Sandbox & gVisor](docs/images/k8s_vs_aws_microvms_banner_v1.jpg)

This repository contains the end-to-end reference architectures, deployment manifests, observability stack, and live engineering benchmarks comparing two approaches to executing untrusted, LLM-generated code securely:

1. **[AWS Lambda MicroVMs (`aws-lambda-microvms/`)](aws-lambda-microvms/):** Snapshot-based Firecracker MicroVMs orchestrated via AWS SAM/CloudFormation, API Gateway, Lambda Control Planes, and dynamic STS session policies.
2. **[Kubernetes Agent Sandbox (`k8s-agent-sandbox/`)](k8s-agent-sandbox/):** Cloud-agnostic Kubernetes sandboxes powered by [`kubernetes-sigs/agent-sandbox`](https://github.com/kubernetes-sigs/agent-sandbox) and the [mogenius Agent Sandbox](https://docs.mogenius.com/agent-sandbox/overview) Helm distribution, isolated with **Google gVisor (`runsc`)**, routed dynamically via NGINX Ingress + `sandbox-router`, and monitored with **Prometheus + Grafana OSS**.

---

## 📖 Articles & Engineering Specifications

* **Part 1 (Published Article):** [🚀 AI agents are writing code. But are our platforms ready to execute it securely?](https://www.linkedin.com/pulse/ai-agenten-schrijven-code-maar-zijn-onze-platforms-klaar-iakym-lynnyk-bbmye/) *(AWS Lambda MicroVMs & Firecracker)*
* **Part 2 (Follow-Up Technical Article):** [I Praised AWS MicroVMs for AI Agents. Then I Built the Exact Same Stack on Kubernetes with gVisor.](docs/FOLLOW_UP_ARTICLE_K8S_VS_MICROVMS.md)
* **Part 3 (Threat Model, Egress Broker & Testkube Security Deep-Dive):** [Beyond Kernel Isolation: Why Egress Control and Zero-In-Guest Credentials Make or Break AI Agent Sandboxes](docs/THREAT_MODEL_EGRESS_AND_CREDENTIALS.md)
* **Functional Specification & Deep Comparison:** [AWS Lambda MicroVMs vs. mogenius (Kubernetes Agent Sandbox)](docs/AWS_LAMBDA_MICROVMS_VS_MOGENIUS_FUNCTIONAL_SPEC.md)
* **Live Demo & Verification Runbook:** [Kubernetes vs. AWS MicroVMs Demo Runbook](docs/DEMO_RUNBOOK.md)
* **Multi-OS & Multi-Architecture Guide:** [macOS, Linux & Windows (WSL 2) Setup Guide](docs/MULTI_OS_SETUP_GUIDE.md) *(covering `aarch64` & `x86_64`)*

---

## 📁 Repository Structure

```text
.
├── aws-lambda-microvms/                 # Original AWS Lambda MicroVMs (Firecracker) Workshop
│   ├── module-1/                        # Basic MicroVM execution & Port-9000 lifecycle hooks
│   ├── module-2/                        # Event-driven Pull Request code reviewer
│   ├── module-3-ci-runner/              # Scale-to-zero ephemeral CI/CD runner
│   ├── module-4-saas/                   # Multi-tenant SaaS Control Plane & STS Token Vending Machine
│   ├── ci-demo/                         # Sample Python unit-test workload for CI runner demos
│   └── cleanup.sh                       # Teardown script for AWS SAM stacks & MicroVMs
│
├── k8s-agent-sandbox/                   # Kubernetes Agent Sandbox (mogenius + Google gVisor)
│   ├── scripts/
│   │   └── bootstrap_cluster.sh         # 8-stage idempotent cluster reconciler & self-healing bootstrapper
│   ├── helm/
│   │   └── values-mogenius.yaml         # Helm values enabling gVisor RuntimeClass & NetworkPolicies
│   ├── module-1-basic-execution/
│   │   └── launch_sandbox.py            # Sub-second SandboxClaim provisioning & execution script
│   ├── ingress/
│   │   ├── sandbox-router.yaml          # Go reverse proxy routing by X-Sandbox-ID + ServiceMonitor
│   │   ├── sandbox-ingress.yaml         # NGINX Ingress exposing sandbox.127.0.0.1.nip.io
│   │   └── test_ingress_poc.sh          # Automated end-to-end Ingress & routing benchmark script
│   ├── threat-model/
│   │   ├── threat_probe.py              # Zero-dependency in-guest red-team probe (T1-T6 threat vectors)
│   │   ├── egress-broker.yaml           # Out-of-sandbox L7 FQDN Egress & On-the-Wire Credential Broker
│   │   ├── baseline_before_output.txt   # Unhardened baseline probe results
│   │   └── hardened_after_output.txt    # Hardened broker probe results
│   ├── testkube/
│   │   ├── values-testkube.yaml         # Helm values pinning Testkube OSS strictly to worker node minikube-m02
│   │   ├── rbac.yaml                    # ClusterRole & bindings for automated SandboxClaim lifecycle testing
│   │   ├── test-workflow.yaml           # Git-sourced 60 QPS Ingress benchmark & warm-pool latency workflow
│   │   ├── test-workflow-security.yaml  # Continuous red-team security audit & k6 broker fuzzing workflow
│   │   ├── test-workflow-sustained-load.yaml # 70 RPS / 10K requests sustained load workflow (no pod restarts)
│   │   └── tests/
│   │       ├── k6-sandbox-benchmark.js  # 60 QPS rate-limited Ingress benchmark script
│   │       ├── k6-security-audit.js     # k6 SSRF, C2 egress, credential leak & tenant isolation fuzzer
│   │       ├── k6-sustained-load.js     # 70 RPS / 10K+ sustained traffic generator script
│   │       └── claim_and_measure.py     # Warm pool claim-to-ready latency measurement hook
│   └── monitoring/
│       ├── values-prometheus-grafana.yaml                     # kube-prometheus-stack Helm values
│       ├── monitoring-ingress.yaml                            # Ingress for Grafana UI
│       ├── agent-sandbox-servicemonitor.yaml                  # ServiceMonitor for sandbox controller
│       ├── sandbox-latency-exporter.yaml                      # Exporter for claim latency & T1-T6 security posture
│       ├── grafana-dashboard-agent-sandbox.yaml               # Cluster & Warm Pool Overview Dashboard
│       ├── grafana-dashboard-sandbox-http-responses.yaml      # Dedicated HTTP Responses & Latency Dashboard
│       └── grafana-dashboard-testkube.yaml                    # Testkube 60 QPS & Red-Team Security Dashboard
│
└── docs/                                # Documentation, Articles & Architecture Diagrams
    ├── AWS_LAMBDA_MICROVMS_VS_MOGENIUS_FUNCTIONAL_SPEC.md
    ├── FOLLOW_UP_ARTICLE_K8S_VS_MICROVMS.md
    ├── THREAT_MODEL_EGRESS_AND_CREDENTIALS.md
    ├── DEMO_RUNBOOK.md
    ├── MULTI_OS_SETUP_GUIDE.md
    ├── ARTICLE_IMAGES.md
    ├── WORKFLOW_HISTORY.md
    └── images/                          # Architecture diagrams & article cover banners
```

---

## ⚡ Key Architectural & Benchmark Highlights

| Capability / Metric | AWS Lambda MicroVMs (`aws-lambda-microvms/`) | Kubernetes Agent Sandbox (`k8s-agent-sandbox/`) |
| :--- | :--- | :--- |
| **Kernel Isolation** | Firecracker KVM hypervisor per VM (AWS Nitro only) | Pluggable `RuntimeClass`: **Google gVisor (`runsc`)** or **Kata Containers** |
| **End-to-End Allocation Latency** | `1.5s – 3.0s` (`run-microvm` + status poll + JWE auth token) | **`220ms – 410ms`** (`SandboxClaim` bound from `SandboxWarmPool`) |
| **Ingress Proxy Latency** | API Gateway -> Control Plane Lambda -> MicroVM Proxy | **`< 15ms` (`p50 < 5ms`, `HTTP 200 OK`)** via NGINX Ingress -> `sandbox-router` |
| **Container Portability** | Requires custom S3 `.zip` snapshot baking + Port-9000 hook server | Runs **any unmodified OCI/Docker image** (`python`, `code-server`, `opencode`) |
| **Workspace Persistence** | Ephemeral rootfs (8-hour max session; custom S3 sync) | Indefinite **POSIX `PersistentVolumeClaim` (`PVC`)** across `Suspended`/`Running` |
| **Multi-Tenant Credentials** | In-guest `sts:AssumeRole` (exposes parent role to untrusted code) | **Zero in-guest credentials** (`automountServiceAccountToken: false` + host PVC) |
| **Cloud & On-Prem Portability** | Locked 100% to AWS Lambda preview regions | **100% Portable** (EKS, GKE, AKS, OpenShift, bare-metal, local Minikube) |

---

## 💻 Hardware & Multi-OS Resource Requirements (Prerequisites)

Running a production-grade 2-node Kubernetes cluster locally (`minikube` control-plane + `minikube-m02` worker) with Google gVisor kernel virtualization, Prometheus + Grafana OSS, MongoDB, and automated Testkube load generation is an enterprise-scale architecture.

**Supported Environments & Architectures:**
* **OS:** macOS (Apple Silicon / Intel), Linux (Ubuntu, Debian, RHEL, Fedora), and Windows 10/11 (via WSL 2 + Ubuntu).
* **CPU Architectures:** Both **`aarch64` (ARM64)** and **`x86_64` (AMD64)** are fully supported with multi-architecture OCI manifests and dynamic gVisor (`runsc`) package resolution.
* **Detailed Setup:** For operating system and architecture-specific installation instructions, see the **[Multi-OS & Multi-Architecture Setup Guide](docs/MULTI_OS_SETUP_GUIDE.md)**.

**Required host tooling:** Docker (Docker Desktop on macOS/Windows, or native Docker Engine CE on Linux), `minikube`, `kubectl`, and `helm`. The `testkube` CLI is automatically installed by `bootstrap_cluster.sh` (via Homebrew on macOS, or the official Linux installer on Linux/WSL2) if missing.

> [!IMPORTANT]
> **Resource Sizing (macOS Docker Desktop / Linux / Windows WSL 2):**
> Do **NOT** run this stack with default settings (4 GB RAM / 2 CPUs); Grafana, MongoDB or the gVisor sandbox pods will be `OOMKilled` (Exit Code 137).
> - **Memory:** I recommend **10 GB – 12 GB** dedicated to Docker/WSL. `bootstrap_cluster.sh` creates `minikube` with an 8,192 MB limit, and `minikube-m02` is added with Minikube's default (~4 GB limit), so the container limits add up to ~12 GB. On my machine the converged, idle stack uses **~5 GiB** and runs inside an 8.8 GB Docker VM; 10–12 GB is headroom for cold image pulls and sustained 70 RPS load, not a measured minimum.
> - **CPUs:** **4+ vCPUs** (`minikube` is created with `--cpus=4`) to avoid throttling during load generation, gVisor syscall interception, and Prometheus TSDB indexing.
> - **Disk:** **40 GB+ free** (see the measured image footprint below).

### 📦 Container Image Footprint (~8.2 GB on disk)

I measured this on a converged cluster with `docker exec <node> du -sh /var/lib/containerd` and `crictl images`:

| Node | containerd store on disk |
| :--- | :--- |
| `minikube` (control-plane + sandboxes + observability) | **5.1 GB** |
| `minikube-m02` (Testkube worker) | **3.1 GB** |
| **Total** | **~8.2 GB** (plus the 1.3 GB `kicbase` node image held by Docker) |

The distinct images add up to only ~2.8 GB as reported by `crictl`; the rest is containerd keeping both the downloaded layers and their unpacked snapshots, and each node holding its own copy of shared images (`kube-system`, `kindnet`, `kube-proxy`, `node-exporter`). The largest images (sizes as reported by `crictl images`):

| Image | Size | Node | Purpose |
| :--- | :--- | :--- | :--- |
| `ghcr.io/mogenius/agent-sandbox-chart/sandbox-default:1.2.1` | 723 MB | `minikube` | Warm-pool sandbox workload (`code-server`, Python and Node toolchains) |
| `kubeshop/bitnami-mongodb:8.3.11` | 615 MB | `minikube-m02` | Testkube execution state and logs |
| `grafana/grafana:13.2.4-distroless` | 435 MB | `minikube` | Dashboards |
| `ingress-nginx/controller` | 110 MB | `minikube` | L7 ingress |
| `prometheus/prometheus:v3.15.1-distroless` | 105 MB | `minikube` | TSDB and scraping |
| `kubeshop/testkube-minio:2025.10` | 85 MB | `minikube-m02` | Test artifact storage |
| `kubeshop/testkube-api-server:2.14.2` | 77 MB | `minikube-m02` | Testkube control plane |
| `bitnami/kubectl:latest` | 76 MB | `minikube-m02` | Helper jobs |
| `kubeshop/testkube-tw-toolkit` + `tw-init` `:2.14.2` | 69 MB | `minikube-m02` | TestWorkflow pod toolkit |
| `grafana/k6:latest` | 34 MB | `minikube-m02` | Load generator |
| Everything else (Kubernetes core, CNI, NATS, operators, sidecars, router, controller, `python:3.11-alpine` broker) | ~440 MB | both | Platform plumbing |

> [!TIP]
> **Cold Boot Patience:** On a fresh cluster (`minikube delete`), the image pulls dominate; the 723 MB sandbox image alone can occupy containerd for over a minute, which is why the bootstrap rollout timeouts are 180 s. Once the images are cached on the nodes, re-running `./k8s-agent-sandbox/scripts/bootstrap_cluster.sh` on a converged cluster took ~20 seconds in my run.

---

### 🌐 Multi-Node Cluster Topology & Hardware Sizing

To guarantee unbiased, accurate benchmarking and prevent noisy-neighbor interference between high-throughput load generators and sandboxed workloads, the platform architecture enforces a strict **2-node topology**:

| Node Role | Sizing (Cloud / VM) | Required Labels & Taints | Running Workloads & Purpose |
| :--- | :--- | :--- | :--- |
| **Node 1: Sandboxing & Control Plane** | 4 vCPUs, 8–16 GB RAM (e.g., AWS `c6i.xlarge`, GCP `c2-standard-4`) | `RuntimeClass: gvisor` enabled | • `mogenius-agent-sandbox` controller<br>• `sandbox-router` dynamic proxy<br>• `egress-broker` L7 egress gateway<br>• `kube-prometheus-stack` (Prometheus & Grafana)<br>• Active & Standby `SandboxWarmPool` pods (gVisor microVMs) |
| **Node 2: Dedicated Worker Node** | 2–4 vCPUs, 4–8 GB RAM (e.g., AWS `c6i.large`, GCP `e2-standard-4`) | **Label:** `dedicated=testkube`<br>**Taint:** `dedicated=testkube:NoSchedule` | • `testkube` OSS orchestrator & API server<br>• `mongodb` execution store & MinIO<br>• k6 sustained load runners (70+ RPS)<br>• In-guest red-team security probe jobs |

> [!NOTE]
> **Why Node Separation is Mandatory:**
> Generating 70–100 RPS sustained load while simultaneously running container security fuzzing consumes significant network sockets and CPU cycles. Isolating load generation onto `minikube-m02` (or a dedicated worker node in the cloud) ensures that Ingress latency (`< 15ms`) and Warm Pool claim acquisition (`~230ms`) reflect true sandbox performance rather than client-side CPU starvation.

---

### ☸️ Bootstrapping on Any Other Kubernetes Context (EKS, GKE, AKS, Bare-Metal)

While `bootstrap_cluster.sh` automates local Minikube setup, I designed this architecture so you can deploy it to **any** Kubernetes cluster (AWS EKS, GCP GKE, Azure AKS, Talos, or bare-metal):

#### 1. Label and Taint Your Dedicated Worker Node
Select a dedicated worker node for Testkube load generation to isolate testing traffic:
```bash
kubectl config use-context <your-cluster-context>

# Label and taint your dedicated test node
kubectl label node <worker-node-name> dedicated=testkube node-role.kubernetes.io/worker=testkube --overwrite
kubectl taint node <worker-node-name> dedicated=testkube:NoSchedule --overwrite
```

#### 2. Ensure gVisor (`runsc`) RuntimeClass is Present
On GKE, create a node pool with `--sandbox type=gvisor`. On EKS or bare-metal, install `runsc` on the sandbox node and register the `RuntimeClass`:
```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
```

#### 3. Deploy the Stack Layers via Helm & Kubectl
Apply the declarative manifests directly against your current cluster context:
```bash
# A. Observability Stack (Prometheus & Grafana OSS)
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f k8s-agent-sandbox/monitoring/values-prometheus-grafana.yaml

kubectl apply -f k8s-agent-sandbox/monitoring/monitoring-ingress.yaml \
              -f k8s-agent-sandbox/monitoring/grafana-dashboard-agent-sandbox.yaml \
              -f k8s-agent-sandbox/monitoring/grafana-dashboard-sandbox-http-responses.yaml \
              -f k8s-agent-sandbox/monitoring/grafana-dashboard-testkube.yaml

# B. mogenius Agent Sandbox & Dynamic Header Router
helm upgrade --install agent-sandbox mogenius/mogenius-agent-sandbox \
  --version 1.2.1 -n agent-sandbox-system --create-namespace \
  -f k8s-agent-sandbox/helm/values-mogenius.yaml

kubectl apply -f k8s-agent-sandbox/ingress/sandbox-router.yaml \
              -f k8s-agent-sandbox/ingress/sandbox-ingress.yaml \
              -f k8s-agent-sandbox/monitoring/agent-sandbox-servicemonitor.yaml \
              -f k8s-agent-sandbox/monitoring/sandbox-latency-exporter.yaml

# C. Zero-Trust Out-of-Sandbox Egress Broker
kubectl apply -f k8s-agent-sandbox/threat-model/egress-broker.yaml

# D. Testkube OSS & Automated Benchmark/Security Workflows
helm upgrade --install testkube kubeshop/testkube \
  --version 2.14.2 -n testkube --create-namespace \
  -f k8s-agent-sandbox/testkube/values-testkube.yaml

kubectl apply -f k8s-agent-sandbox/testkube/rbac.yaml \
              -f k8s-agent-sandbox/testkube/test-workflow.yaml \
              -f k8s-agent-sandbox/testkube/test-workflow-security.yaml \
              -f k8s-agent-sandbox/testkube/test-workflow-sustained-load.yaml
```

---

## 🚀 Quickstart

### Option A: Run the Kubernetes Agent Sandbox Stack (Minikube / Any K8s Cluster)
Follow the step-by-step instructions in [`docs/DEMO_RUNBOOK.md`](docs/DEMO_RUNBOOK.md) to:
1. **Provision or Self-Heal the Full 2-Node Cluster:** Run `./k8s-agent-sandbox/scripts/bootstrap_cluster.sh` (works from a fresh `minikube delete` or after a laptop sleep/reboot, reconciling all 8 layers including `minikube-m02`, `gVisor`, Prometheus/Grafana, `egress-broker`, and Testkube OSS).
2. **Run Continuous Red-Team Security & Benchmark Workflows via Testkube:**
   - `testkube run tw agent-sandbox-security-audit -f` *(In-guest `T1`–`T6` threat probe + k6 Egress Broker & tenant isolation fuzzing)*
   - `testkube run tw agent-sandbox-benchmark -f` *(Warm pool claim latency + 60 QPS rate-limited Ingress benchmark with scale-to-zero)*
   - `testkube run tw agent-sandbox-sustained-load -f` *(70 RPS sustained load for 10K+ requests targeting active sandbox without pod restarts)*
3. **Execute Interactive Demo Modules 1–4:** (`SandboxWarmPool`, Ephemeral CI/CD, Multi-Tenant PVC Isolation, `operatingMode: Suspended`, and `kubectl debug`).
4. **Inspect Live Telemetry & Security Posture in Grafana:** (`http://grafana.127.0.0.1.nip.io`, login `admin` / `admin`).

### Option B: Run the AWS Lambda MicroVMs Workshop
1. Ensure AWS CLI and AWS SAM CLI are configured with `lambda-microvms` preview access.
2. Navigate to [`aws-lambda-microvms/`](aws-lambda-microvms/) and run the module deployment scripts (`module-1`, `module-2`, `module-3-ci-runner`, `module-4-saas`).
3. Run `./aws-lambda-microvms/cleanup.sh` to tear down CloudFormation stacks and active MicroVMs.
