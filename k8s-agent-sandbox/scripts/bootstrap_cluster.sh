#!/usr/bin/env bash
# ==============================================================================
# Idempotent Bootstrap & Self-Healing Reconciler for Minikube + gVisor + Testkube
#
# ARCHITECTURE OVERVIEW:
#   This script automates the complete provisioning, reconciliation, and self-
#   healing of a 2-node local Kubernetes AI Agent Sandbox platform comparing
#   Google gVisor kernel virtualization against AWS Lambda MicroVMs (Firecracker).
#
# MULTI-NODE TOPOLOGY:
#   • Node 1 (minikube)      : Control-plane and sandboxed workloads (gVisor runsc).
#   • Node 2 (minikube-m02)  : Dedicated worker node tainted (dedicated=testkube:NoSchedule)
#                              hosting Testkube OSS, MongoDB, NATS, and k6 load generators.
#                              This isolation prevents testing traffic from skewing benchmark
#                              latency or competing for CPU/memory with agent sandboxes.
#
# 8 ARCHITECTURE RECONCILIATION LAYERS:
#   [1/8] Multi-node Minikube cluster topology & node taints/labels
#   [2/8] Control-plane sanity guard (CoreDNS) & internal host resolution (/etc/hosts)
#   [3/8] Native Google gVisor (runsc) binary, containerd config healing & RuntimeClass
#   [4/8] NGINX Ingress Controller (L7 routing & header multiplexing)
#   [5/8] Observability Stack (kube-prometheus-stack, 3 custom Grafana Dashboards,
#         ServiceMonitors, and Sandbox Latency/Security Exporter)
#   [6/8] mogenius Agent Sandbox Controller, Warm Pool (gVisor), and Dynamic Sandbox Router
#   [7/8] Zero-Trust Out-of-Sandbox Egress & Credential Broker + NetworkPolicies
#   [8/8] Testkube OSS on worker node (minikube-m02), RBAC & dynamic TestWorkflow discovery
#
# USAGE MODES:
#   • Cold Start from Scratch : ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh
#   • Force Helm Upgrades    : ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --upgrade-helm
# ==============================================================================
set -euo pipefail

# ANSI Color codes for formatted terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FORCE_HELM="${1:-}"

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}Minikube Agent Sandbox & Testkube Full-Stack Reconciler${NC}"
echo -e "${BLUE}============================================================${NC}"

# ==============================================================================
# [1/8] Check / Start Minikube & Multi-Node Worker Topology
# ==============================================================================
# Why multi-node?
# Benchmarking AI agent execution requires rigorous physical separation. If load
# generators (k6, curl, probe runners) run on the same node as gVisor sandboxes,
# CPU cache thrashing and context switches invalidate latency measurements.
# I create a 2-node cluster and isolate Testkube onto 'minikube-m02'.
# ==============================================================================
echo -e "\n${YELLOW}[1/8] Checking Minikube & Multi-Node Topology...${NC}"

if ! minikube status >/dev/null 2>&1; then
    if minikube profile list 2>/dev/null | grep -q "minikube"; then
        echo -e "  ${CYAN}[>]${NC} Existing Minikube profile found (stopped). Starting Minikube primary node..."
        minikube start --driver=docker
    else
        echo -e "  ${CYAN}[>]${NC} No Minikube cluster found. Creating fresh cluster from scratch (4 CPUs, 8192 MB RAM)..."
        minikube start --driver=docker --cpus=4 --memory=8192
    fi
else
    echo -e "  ${GREEN}✓${NC} Primary node 'minikube' is running."
fi

# Verify or add dedicated worker node 'minikube-m02'
if ! kubectl get node minikube-m02 >/dev/null 2>&1; then
    echo -e "  ${CYAN}[>]${NC} Dedicated worker node 'minikube-m02' not found. Adding worker node..."
    minikube node add --worker=true
else
    echo -e "  ${GREEN}✓${NC} Worker node 'minikube-m02' is present."
fi

# Label and taint worker node to restrict scheduling exclusively to Testkube workloads
echo -e "  ${CYAN}[>]${NC} Applying labels and taints to 'minikube-m02' (dedicated=testkube:NoSchedule)..."
kubectl label node minikube-m02 dedicated=testkube node-role.kubernetes.io/worker=testkube --overwrite >/dev/null
kubectl taint node minikube-m02 dedicated=testkube:NoSchedule --overwrite >/dev/null 2>&1 || true
echo -e "  ${GREEN}✓${NC} Worker node 'minikube-m02' labeled and tainted successfully."

# ==============================================================================
# [2/8] Control-Plane Sanity Guard & Host Resolution
# ==============================================================================
# Why control-plane guard?
# Cluster DNS (kube-dns/CoreDNS on 10.96.0.10:53) is fundamental to all Kubernetes
# networking. If CoreDNS is manually deleted or corrupted, service discovery fails
# across all namespaces (e.g. Testkube API Server cannot connect to NATS or MongoDB).
# Because this bootstrap reconciler does not act as an out-of-band GitOps control-plane
# state manager (like ArgoCD or Flux), corrupted kube-system components require a
# clean cluster rebuild.
#
# Why /etc/hosts resolution?
# Ingress and API proxies inside the Minikube Docker network resolve control-plane
# services via 'control-plane.minikube.internal'.
# ==============================================================================
echo -e "\n${YELLOW}[2/8] Verifying control-plane health & internal host resolution...${NC}"

echo -e "  ${CYAN}[>]${NC} Checking core DNS health in namespace 'kube-system'..."
if ! kubectl -n kube-system get deployment coredns >/dev/null 2>&1; then
    echo -e "  ${RED}✗ CRITICAL: Core control-plane component 'coredns' is missing in 'kube-system'.${NC}"
    echo -e "  ${YELLOW}The cluster control plane is corrupted. Because this bootstrap script does not maintain GitOps control-plane state (like Flux or ArgoCD), please rebuild cleanly from scratch:${NC}"
    echo -e "      minikube delete && ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh\n"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Control-plane DNS (kube-system/coredns) is healthy."

# Disable legacy minikube gvisor addon (uses outdated shims that conflict with native runsc)
echo -e "  ${CYAN}[>]${NC} Ensuring legacy Minikube gVisor addon is disabled..."
minikube addons disable gvisor 2>/dev/null || true

# Map control-plane.minikube.internal in node /etc/hosts
CP_IP=$(minikube ip)
echo -e "  ${CYAN}[>]${NC} Mapping control-plane.minikube.internal -> ${CP_IP} in node /etc/hosts..."
minikube ssh "grep -q 'control-plane.minikube.internal' /etc/hosts || echo '${CP_IP} control-plane.minikube.internal' | sudo tee -a /etc/hosts >/dev/null"
echo -e "  ${GREEN}✓${NC} control-plane.minikube.internal mapped to ${CP_IP}."

# ==============================================================================
# [3/8] Native Google gVisor (runsc) Runtime & Containerd TOML Healing
# ==============================================================================
# Why native Google runsc?
# Minikube's built-in gvisor addon bundles an obsolete KVM shim. I install the
# official Google gVisor package from https://gvisor.dev/archive.key directly
# into the primary Minikube node.
#
# Containerd TOML Healing:
# Containerd requires a dedicated runtime handler stanza for runsc:
#   [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
#     runtime_type = "io.containerd.runsc.v1"
# I idempotently inject this stanza into /etc/containerd/config.toml, ensure no
# duplicate stanzas exist, restart containerd, and declare the Kubernetes RuntimeClass.
# ==============================================================================
echo -e "\n${YELLOW}[3/8] Reconciling containerd & native gVisor (runsc) runtime...${NC}"

echo -e "  ${CYAN}[>]${NC} Checking native Google gVisor (runsc) binary and containerd runtime on primary node..."
minikube ssh "
set -e
# Install official Google runsc binary if missing or corrupted
if ! head -c 4 /usr/bin/containerd-shim-runsc-v1 2>/dev/null | grep -q ELF; then
    echo '  -> Downloading and installing official Google gVisor (runsc) package...'
    sudo apt-get update -qq
    sudo apt-get install -y -qq apt-transport-https ca-certificates curl gnupg
    curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg --yes
    echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main\" | sudo tee /etc/apt/sources.list.d/gvisor.list >/dev/null
    sudo apt-get update -qq && sudo apt-get install --reinstall -y -qq runsc
fi

# Ensure containerd config.toml has exactly one runsc runtime stanza
sudo python3 -c '
import subprocess
path = \"/etc/containerd/config.toml\"
with open(path, \"r\") as f:
    content = f.read()
target = \"[plugins.\\\"io.containerd.grpc.v1.cri\\\".containerd.runtimes.runsc]\"
stanza = target + \"\n  runtime_type = \\\"io.containerd.runsc.v1\\\"\n\"
parts = content.split(target)
if len(parts) == 1:
    clean = content.rstrip() + \"\n\n\" + stanza
elif len(parts) > 2:
    clean = parts[0] + target + parts[1]
else:
    clean = content
if clean != content:
    with open(\"/tmp/config.toml.clean\", \"w\") as out:
        out.write(clean)
    subprocess.run([\"sudo\", \"mv\", \"/tmp/config.toml.clean\", path], check=True)
    subprocess.run([\"sudo\", \"systemctl\", \"restart\", \"containerd\"], check=True)
'
"

# Register the gVisor RuntimeClass with Kubernetes API
echo -e "  ${CYAN}[>]${NC} Registering Kubernetes RuntimeClass 'gvisor' (handler: runsc)..."
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
EOF
echo -e "  ${GREEN}✓${NC} Native gVisor (runsc) binary, containerd config, and RuntimeClass 'gvisor' verified."

# ==============================================================================
# [4/8] Reconcile NGINX Ingress Controller
# ==============================================================================
# Why NGINX Ingress?
# Ingress acts as the single HTTP/HTTPS entrypoint for both the AI agent router
# (routing execution traffic based on X-Sandbox-ID) and the Grafana observability UI.
#
# Self-healing logic:
# If the ingress deployment was removed but the namespace remains, disable and re-enable
# the Minikube addon and wait up to 180s for deployment rollout to complete.
# ==============================================================================
echo -e "\n${YELLOW}[4/8] Checking NGINX Ingress Controller...${NC}"

if ! kubectl get ns ingress-nginx >/dev/null 2>&1 || \
   ! kubectl -n ingress-nginx get deployment ingress-nginx-controller >/dev/null 2>&1; then
    echo -e "  ${CYAN}[>]${NC} Ingress controller missing. Enabling / recovering Minikube ingress addon..."
    minikube addons disable ingress >/dev/null 2>&1 || true
    minikube addons enable ingress
fi

# Wait for ingress deployment object to be registered in API server
echo -e "  ${CYAN}[>]${NC} Waiting for 'ingress-nginx-controller' deployment to become available..."
for i in {1..30}; do
    if kubectl -n ingress-nginx get deployment ingress-nginx-controller >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# Wait for controller rollout to be Ready
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
echo -e "  ${GREEN}✓${NC} NGINX Ingress Controller is Ready."

# ==============================================================================
# [5/8] Reconcile Observability Stack (Prometheus, Grafana & Dashboards)
# ==============================================================================
# Why custom values for Prometheus & Grafana?
# Under sustained 70 RPS load generation, Grafana's default embedded SQLite engine
# suffers database lock contention and memory spikes. My custom values enable
# SQLite WAL mode ('wal: true'), set a 1.5Gi memory limit, and lengthen health probes
# to 5 seconds to eliminate OOMKilled crashes.
#
# Reconciles:
#   • kube-prometheus-stack Helm chart (Prometheus TSDB, Grafana, node-exporter)
#   • monitoring-ingress.yaml (Exposes Grafana on NodePort/Ingress)
#   • 3 provisioned Grafana Dashboards via ConfigMaps (Agent Sandbox, HTTP Responses, Testkube)
# ==============================================================================
echo -e "\n${YELLOW}[5/8] Reconciling Observability Stack (Prometheus & Grafana)...${NC}"

if ! helm status monitoring -n monitoring >/dev/null 2>&1 || \
   ! kubectl -n monitoring get deployment monitoring-grafana >/dev/null 2>&1 || \
   ! kubectl -n monitoring get deployment monitoring-kube-prometheus-operator >/dev/null 2>&1 || \
   ! kubectl -n monitoring get deployment monitoring-kube-state-metrics >/dev/null 2>&1 || \
   ! kubectl -n monitoring get statefulset prometheus-monitoring-kube-prometheus-prometheus >/dev/null 2>&1 || \
   [ "${FORCE_HELM}" == "--upgrade-helm" ]; then
    echo -e "  ${CYAN}[>]${NC} Installing / recovering kube-prometheus-stack in namespace 'monitoring'..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update prometheus-community >/dev/null
    helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
        -n monitoring --create-namespace \
        -f "${K8S_DIR}/monitoring/values-prometheus-grafana.yaml" \
        --wait --timeout=5m
else
    echo -e "  ${GREEN}✓${NC} Helm release 'monitoring' and core deployments verified."
fi

echo -e "  ${CYAN}[>]${NC} Applying Monitoring Ingress and Grafana Dashboard ConfigMaps..."
kubectl apply -f "${K8S_DIR}/monitoring/monitoring-ingress.yaml" \
              -f "${K8S_DIR}/monitoring/grafana-dashboard-agent-sandbox.yaml" \
              -f "${K8S_DIR}/monitoring/grafana-dashboard-sandbox-http-responses.yaml" \
              -f "${K8S_DIR}/monitoring/grafana-dashboard-testkube.yaml" >/dev/null
echo -e "  ${GREEN}✓${NC} Monitoring Ingress and all 3 Grafana Dashboards reconciled."

# ==============================================================================
# [6/8] Reconcile Agent Sandbox Control Plane, Warm Pool & Dynamic Router
# ==============================================================================
# Why mogenius Agent Sandbox?
# The mogenius CRD controller manages 'SandboxWarmPool', maintaining pre-warmed
# gVisor sandboxes with pre-loaded runtimes. This reduces sandbox startup latency
# from >10s (cold container pull + boot) to sub-50ms (instant warm claim).
#
# Why sandbox-router?
# The Go-based sandbox-router routes incoming HTTP requests carrying 'X-Sandbox-ID'
# headers directly to the assigned microVM.
#
# CRITICAL NETWORK POLICY REQUIREMENT:
# mogenius warm-pool generates a NetworkPolicy that permits ingress ONLY from pods
# carrying the label 'app: sandbox-router'. I enforce this label in sandbox-router.yaml.
# ==============================================================================
echo -e "\n${YELLOW}[6/8] Reconciling mogenius Agent Sandbox, Warm Pool & Router...${NC}"

if ! helm status agent-sandbox -n agent-sandbox-system >/dev/null 2>&1 || \
   ! kubectl -n agent-sandbox-system get deployment agent-sandbox-controller >/dev/null 2>&1 || \
   ! kubectl -n agent-sandbox get sandboxwarmpool default >/dev/null 2>&1 || \
   [ "${FORCE_HELM}" == "--upgrade-helm" ]; then
    echo -e "  ${CYAN}[>]${NC} Installing / recovering mogenius-agent-sandbox in 'agent-sandbox-system'..."
    helm repo add mogenius https://helm.mogenius.com/public >/dev/null 2>&1 || true
    helm repo update mogenius >/dev/null
    helm upgrade --install agent-sandbox mogenius/mogenius-agent-sandbox \
        --version 1.2.1 \
        -n agent-sandbox-system --create-namespace \
        -f "${K8S_DIR}/helm/values-mogenius.yaml" \
        --wait --timeout=3m
else
    echo -e "  ${GREEN}✓${NC} Helm release 'agent-sandbox' and WarmPool 'default' verified."
fi

echo -e "  ${CYAN}[>]${NC} Applying Sandbox Router, Ingress, ServiceMonitor, and Latency Exporter..."
kubectl apply -f "${K8S_DIR}/ingress/sandbox-router.yaml" \
              -f "${K8S_DIR}/ingress/sandbox-ingress.yaml" \
              -f "${K8S_DIR}/monitoring/agent-sandbox-servicemonitor.yaml" \
              -f "${K8S_DIR}/monitoring/sandbox-latency-exporter.yaml" >/dev/null

echo -e "  ${CYAN}[>]${NC} Waiting for sandbox-router rollout to complete..."
kubectl -n agent-sandbox-system rollout status deployment/sandbox-router --timeout=180s >/dev/null
echo -e "  ${GREEN}✓${NC} Sandbox Router, Ingress, ServiceMonitor, and Latency/Security Exporter reconciled."

# ==============================================================================
# [7/8] Reconcile Out-of-Sandbox Egress & Credential Broker (Zero-Trust)
# ==============================================================================
# Why Egress Broker?
# In an AI agent execution platform, code executed inside the sandbox is untrusted.
# If an agent attempts Server-Side Request Forgery (SSRF) against cloud metadata
# (AWS IMDS 169.254.169.254, GCP metadata), or tries to exfiltrate data, direct
# outbound access must be blocked.
#
# Zero-Trust NetworkPolicies:
#   • All direct external egress from 'agent-sandbox' is BLOCKED.
#   • Sandboxes may only speak HTTP port 8080 to 'egress-broker.sandbox-egress-system'.
#   • The broker injects secrets out-of-band, validates outbound destinations, and
#     enforces strict rate limits.
#
# Readiness/Liveness Probes:
#   • Health probes monitor HTTP /healthz port 8080 to prevent cold traffic drops.
# ==============================================================================
echo -e "\n${YELLOW}[7/8] Reconciling Out-of-Sandbox Egress & Credential Broker...${NC}"

echo -e "  ${CYAN}[>]${NC} Applying egress-broker deployment, service, and zero-trust NetworkPolicies..."
kubectl apply -f "${K8S_DIR}/threat-model/egress-broker.yaml" >/dev/null

echo -e "  ${CYAN}[>]${NC} Waiting for egress-broker rollout status (verifying /healthz probes)..."
kubectl -n sandbox-egress-system rollout status deployment/egress-broker --timeout=180s
echo -e "  ${GREEN}✓${NC} Egress & Credential Broker and cross-namespace NetworkPolicies reconciled."

# ==============================================================================
# [8/8] Reconcile Testkube OSS CLI, Worker Node Stack (minikube-m02) & Workflows
# ==============================================================================
# Why Testkube OSS?
# Testkube provides cloud-native testing orchestration inside Kubernetes.
# Rather than running ad-hoc scripts from the host machine, Testkube executes
# test workflows as native Kubernetes jobs on my dedicated worker node ('minikube-m02').
#
# Components Pinned to 'minikube-m02':
#   • testkube-api-server  : Orchestration control plane
#   • testkube-mongodb     : Test execution state and log store
#   • testkube-nats        : Event-driven pub/sub messaging bus
#   • testkube-minio       : Test workflow execution artifact storage
#
# Self-healing logic:
# If MongoDB stalls during cold startup probe initialization, a rollout restart
# is automatically triggered before waiting for API Server readiness.
# ==============================================================================
echo -e "\n${YELLOW}[8/8] Reconciling Testkube OSS & Benchmark/Security TestWorkflows...${NC}"

# Check for Testkube CLI on local host machine
if ! command -v testkube >/dev/null 2>&1; then
    echo -e "  ${CYAN}[>]${NC} Testkube CLI not found on host. Installing..."
    if command -v brew >/dev/null 2>&1; then
        echo -e "  ${CYAN}[>]${NC} Installing via Homebrew..."
        brew install kubeshop/testkube/testkube || brew install testkube
    else
        echo -e "  ${CYAN}[>]${NC} Homebrew not detected (Linux/WSL2). Installing via official Testkube installer..."
        curl -sSLf https://get.testkube.io | bash
    fi
fi

# Reconcile Testkube Helm release on worker node
if ! helm status testkube -n testkube >/dev/null 2>&1 || \
   ! kubectl -n testkube get deployment testkube-api-server >/dev/null 2>&1 || \
   ! kubectl -n testkube get deployment testkube-mongodb >/dev/null 2>&1 || \
   ! kubectl -n testkube get statefulset testkube-nats >/dev/null 2>&1 || \
   ! kubectl -n testkube get deployment testkube-minio-testkube >/dev/null 2>&1 || \
   [ "${FORCE_HELM}" == "--upgrade-helm" ]; then
    echo -e "  ${CYAN}[>]${NC} Installing / recovering Testkube OSS on dedicated worker node 'minikube-m02'..."
    helm repo add kubeshop https://kubeshop.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update kubeshop >/dev/null
    helm upgrade --install testkube kubeshop/testkube \
        --version 2.14.2 \
        -n testkube --create-namespace \
        -f "${K8S_DIR}/testkube/values-testkube.yaml" \
        --wait --timeout=5m
else
    echo -e "  ${GREEN}✓${NC} Helm release 'testkube' and core deployments verified on 'minikube-m02'."
fi

# Apply Testkube RBAC permissions
echo -e "  ${CYAN}[>]${NC} Reconciling Testkube RBAC permissions..."
kubectl apply -f "${K8S_DIR}/testkube/rbac.yaml" >/dev/null

# Dynamically discover and reconcile all TestWorkflows and verify tests count
echo -e "  ${CYAN}[>]${NC} Discovering and registering TestWorkflows from codebase..."
WORKFLOW_FILES=($(find "${K8S_DIR}/testkube" -maxdepth 1 -name "test-workflow*.yaml" | sort))
WORKFLOW_COUNT=${#WORKFLOW_FILES[@]}
TEST_SCRIPTS=($(find "${K8S_DIR}/testkube/tests" -maxdepth 1 -type f | sort))
TEST_SCRIPT_COUNT=${#TEST_SCRIPTS[@]}

for wf in "${WORKFLOW_FILES[@]}"; do
    echo -e "     • Applying workflow manifest: $(basename "$wf")"
    kubectl apply -f "$wf" >/dev/null
done

REGISTERED_WF_COUNT=$(kubectl -n testkube get testworkflows --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo -e "  ${GREEN}✓${NC} Reconciled ${REGISTERED_WF_COUNT}/${WORKFLOW_COUNT} TestWorkflows active in cluster (${TEST_SCRIPT_COUNT} benchmark/probe scripts in 'tests/')."

# Check MongoDB and API Server readiness on worker node
echo -e "  ${CYAN}[>]${NC} Verifying Testkube service readiness on 'minikube-m02'..."
echo -e "  ${CYAN}[>]${NC} Checking MongoDB readiness (waiting up to 3m)..."
if ! kubectl -n testkube rollout status deployment/testkube-mongodb --timeout=180s; then
    echo -e "  ${YELLOW}⚠ MongoDB liveness/readiness timed out after 3m. Performing forced rollout restart...${NC}"
    kubectl -n testkube rollout restart deployment/testkube-mongodb
    kubectl -n testkube rollout status deployment/testkube-mongodb --timeout=180s
fi
echo -e "  ${CYAN}[>]${NC} Checking Testkube API Server rollout status..."
kubectl -n testkube rollout status deployment/testkube-api-server --timeout=180s
echo -e "  ${GREEN}✓${NC} Testkube MongoDB and API Server are Ready on 'minikube-m02'."

# ==============================================================================
# Final Architecture Health & Service Endpoint Verification
# ==============================================================================
# Why comprehensive endpoint verification?
# In distributed Kubernetes architectures, a Pod can be in 'Running' status while
# its readiness probe has not yet passed, or its selector does not match the
# Service definition. Checking Service EndpointSlices guarantees that:
#   1. The Service exists in the target namespace.
#   2. At least one Pod has passed readiness probes and is receiving traffic.
#   3. Traffic routing from Ingress through to the backend microVMs is live.
# ==============================================================================
echo -e "\n${YELLOW}Verifying core architecture service endpoints across all namespaces...${NC}"

CORE_SERVICES=(
    "ingress-nginx:ingress-nginx-controller"
    "agent-sandbox-system:agent-sandbox-controller"
    "agent-sandbox-system:sandbox-router"
    "agent-sandbox-system:sandbox-latency-exporter"
    "sandbox-egress-system:egress-broker"
    "monitoring:monitoring-grafana"
    "monitoring:monitoring-kube-prometheus-prometheus"
    "testkube:testkube-api-server"
    "testkube:testkube-mongodb"
    "testkube:testkube-nats"
    "testkube:testkube-minio-service-testkube"
)

ALL_SERVICES_OK=true
for item in "${CORE_SERVICES[@]}"; do
    IFS=":" read -r ns svc <<< "$item"
    ips=$(kubectl -n "$ns" get endpointslices -l "kubernetes.io/service-name=$svc" -o jsonpath="{.items[*].endpoints[?(@.conditions.ready==true)].addresses[*]}" 2>/dev/null)
    if [ -z "$ips" ]; then
        ips=$(kubectl -n "$ns" get endpoints "$svc" -o jsonpath="{.subsets[*].addresses[*].ip}" 2>/dev/null)
    fi

    if [ -n "$ips" ]; then
        echo -e "  ${GREEN}✓${NC} [${ns}] ${svc} -> (${ips})"
    else
        echo -e "  ${RED}✗${NC} [${ns}] ${svc} -> No active endpoints!"
        ALL_SERVICES_OK=false
    fi
done

if [ "$ALL_SERVICES_OK" = false ]; then
    echo -e "\n${RED}✗ WARNING: One or more services do not have active endpoints.${NC}"
    echo -e "${YELLOW}Check pod status via: kubectl get pods -A${NC}"
    exit 1
fi

echo -e "\n${CYAN}[>]${NC} Waiting for all cluster nodes to reach Ready state..."
kubectl wait --for=condition=Ready node/minikube node/minikube-m02 --timeout=60s >/dev/null

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}Cluster is 100% CONVERGED, HEALTHY & READY!${NC}"
echo -e "${GREEN}============================================================${NC}"
kubectl get nodes -o wide
echo ""
echo "Active TestWorkflows in 'testkube' (${REGISTERED_WF_COUNT}/${WORKFLOW_COUNT} ready, ${TEST_SCRIPT_COUNT} scripts in 'tests/'):"
kubectl -n testkube get testworkflows
