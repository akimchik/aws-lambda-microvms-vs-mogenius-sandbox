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
#   [0/8] Host OS, Architecture & Toolchain Discovery
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
#   • Force Helm Upgrades     : ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --upgrade-helm
#   • Custom Memory Allocation: ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --memory 6144
#   • CI Mode (Lower Sizing)  : ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --ci
#   • Preflight/Dry-Run Only  : ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --preflight-only
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

# Global flag defaults
FORCE_HELM=false
PREFLIGHT_ONLY=false
CI_MODE=false
CUSTOM_MEM="${MINIKUBE_MEMORY:-}"
TMP_DIR=""

cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Idempotent bootstrap & self-healing reconciler for Kubernetes Agent Sandbox.

Options:
  --upgrade-helm          Force upgrade of existing Helm releases (monitoring, mogenius, testkube)
  --preflight-only        Verify host OS, CPU arch, and toolchains without modifying cluster state
  --dry-run               Alias for --preflight-only
  --ci                    CI mode: size Minikube cluster for 2 vCPUs and 4096 MB RAM
  --memory <MB>           Set custom Minikube memory in MB (e.g. --memory 6144, min: 2048)
  -h, --help              Show this help message and exit

Environment Variables:
  MINIKUBE_MEMORY         Alternative to --memory (e.g. MINIKUBE_MEMORY=6144)
EOF
}

# Privilege helper: run as root directly if already root, or invoke sudo
run_priv() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo -e "  ${RED}✗ Error: Root privileges required for '$*' but 'sudo' is not installed.${NC}" >&2
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --upgrade-helm)
                FORCE_HELM=true
                shift
                ;;
            --preflight-only|--dry-run)
                PREFLIGHT_ONLY=true
                shift
                ;;
            --ci)
                CI_MODE=true
                shift
                ;;
            --memory)
                if [[ $# -lt 2 ]] || [[ -z "$2" ]] || [[ "$2" == --* ]]; then
                    echo -e "${RED}✗ Error: --memory requires a positive integer argument in MB (e.g. --memory 6144).${NC}" >&2
                    exit 1
                fi
                CUSTOM_MEM="$2"
                shift 2
                ;;
            --memory=*)
                CUSTOM_MEM="${1#*=}"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo -e "${RED}✗ Error: Unrecognized option '$1'.${NC}" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    if [ -n "$CUSTOM_MEM" ]; then
        if ! [[ "$CUSTOM_MEM" =~ ^[0-9]+$ ]] || [ "$CUSTOM_MEM" -lt 2048 ]; then
            echo -e "${RED}✗ Error: Invalid memory value '${CUSTOM_MEM}'. Must be an integer >= 2048 MB.${NC}" >&2
            exit 1
        fi
    fi
}

detect_platform() {
    OS_NAME="$(uname -s)"
    RAW_ARCH="$(uname -m)"

    case "${RAW_ARCH}" in
        x86_64|amd64)
            ARCH_CLI="amd64"
            ARCH_RUNSC="x86_64"
            ;;
        arm64|aarch64)
            ARCH_CLI="arm64"
            ARCH_RUNSC="aarch64"
            ;;
        *)
            echo -e "  ${RED}✗ Unsupported CPU architecture: ${RAW_ARCH}${NC}" >&2
            return 1
            ;;
    esac

    if [ "${OS_NAME}" == "Darwin" ]; then
        HOST_PLATFORM="macOS"
        PKG_MGR="brew"
    elif [ "${OS_NAME}" == "Linux" ]; then
        HOST_PLATFORM="Linux"
        if command -v apt-get >/dev/null 2>&1; then
            PKG_MGR="apt"
        elif command -v dnf >/dev/null 2>&1; then
            PKG_MGR="dnf"
        elif command -v yum >/dev/null 2>&1; then
            PKG_MGR="yum"
        else
            PKG_MGR="generic"
        fi
    else
        echo -e "  ${RED}✗ Unsupported operating system: ${OS_NAME}${NC}" >&2
        return 1
    fi
}

install_host_bin() {
    local src="$1"
    local dst="$2"
    local dst_dir
    dst_dir="$(dirname "$dst")"

    if [ ! -d "$dst_dir" ]; then
        run_priv mkdir -p "$dst_dir"
    fi

    # Use install -m 0755 to copy rather than mv, preventing double-mv removal
    if [ -w "$dst_dir" ]; then
        install -m 0755 "$src" "$dst"
    else
        run_priv install -m 0755 "$src" "$dst"
    fi
}

install_system_deps() {
    if [ "${HOST_PLATFORM}" != "Linux" ]; then
        return 0
    fi

    local base_tools=(curl ca-certificates tar jq bzip2)
    local missing_base=()
    for t in "${base_tools[@]}"; do
        command -v "$t" >/dev/null 2>&1 || missing_base+=("$t")
    done

    if [ ${#missing_base[@]} -gt 0 ]; then
        echo -e "  ${CYAN}[>]${NC} Installing missing system dependencies: ${missing_base[*]}..."
        if [ "$PKG_MGR" == "apt" ]; then
            run_priv apt-get update -qq && run_priv apt-get install -y -qq "${missing_base[@]}"
        elif [ "$PKG_MGR" == "dnf" ]; then
            run_priv dnf install -y --allowerasing "${missing_base[@]}"
        elif [ "$PKG_MGR" == "yum" ]; then
            run_priv yum install -y "${missing_base[@]}"
        fi
    fi
}

ensure_kubectl() {
    if command -v kubectl >/dev/null 2>&1; then
        return 0
    fi

    if [ "${OS_NAME}" == "Darwin" ]; then
        echo -e "  ${CYAN}[>]${NC} Installing 'kubectl' via Homebrew..."
        brew install kubectl
    else
        echo -e "  ${CYAN}[>]${NC} 'kubectl' not found. Installing official multi-arch binary (${ARCH_CLI})..."
        [ -n "$TMP_DIR" ] || TMP_DIR=$(mktemp -d)
        local k8s_ver
        k8s_ver=$(curl -fsSL https://dl.k8s.io/release/stable.txt || echo "v1.31.0")
        if ! [[ "$k8s_ver" =~ ^v[0-9]+\.[0-9]+ ]]; then
            k8s_ver="v1.31.0"
        fi
        curl -fsSL --retry 3 "https://dl.k8s.io/release/${k8s_ver}/bin/linux/${ARCH_CLI}/kubectl" -o "${TMP_DIR}/kubectl"
        install_host_bin "${TMP_DIR}/kubectl" /usr/local/bin/kubectl
    fi
}

ensure_minikube() {
    local minikube_bin
    minikube_bin="$(command -v minikube 2>/dev/null || echo "/usr/local/bin/minikube")"
    local need_minikube=false

    if ! command -v minikube >/dev/null 2>&1; then
        need_minikube=true
    else
        local mk_ver mk_major mk_minor
        mk_ver=$(minikube version --short 2>/dev/null || minikube version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+' | head -n1 || echo "")
        mk_ver="${mk_ver#v}"
        mk_major=$(echo "$mk_ver" | cut -d. -f1)
        mk_minor=$(echo "$mk_ver" | cut -d. -f2)
        if [ -z "$mk_major" ] || [ -z "$mk_minor" ] || [ "$mk_major" -lt 1 ] || { [ "$mk_major" -eq 1 ] && [ "$mk_minor" -lt 30 ]; }; then
            echo -e "  ${YELLOW}[!] Detected outdated or unparseable Minikube (v${mk_ver:-unknown}). Minimum required is Minikube >= v1.30.${NC}"
            need_minikube=true
        fi
    fi

    if [ "$need_minikube" = true ]; then
        if [ "${OS_NAME}" == "Darwin" ]; then
            echo -e "  ${CYAN}[>]${NC} Installing / upgrading Minikube via Homebrew..."
            brew install minikube || brew upgrade minikube
        else
            echo -e "  ${CYAN}[>]${NC} Installing latest official multi-arch Minikube (${ARCH_CLI})..."
            [ -n "$TMP_DIR" ] || TMP_DIR=$(mktemp -d)
            curl -fsSL --retry 3 "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${ARCH_CLI}" -o "${TMP_DIR}/minikube"
            install_host_bin "${TMP_DIR}/minikube" "$minikube_bin"
            if [ "$minikube_bin" != "/usr/local/bin/minikube" ]; then
                install_host_bin "${TMP_DIR}/minikube" /usr/local/bin/minikube
            fi
        fi
    fi
}

ensure_helm() {
    if command -v helm >/dev/null 2>&1; then
        return 0
    fi

    if [ "${OS_NAME}" == "Darwin" ]; then
        echo -e "  ${CYAN}[>]${NC} Installing 'helm' via Homebrew..."
        brew install helm
    else
        echo -e "  ${CYAN}[>]${NC} 'helm' not found. Installing official Helm via curl script..."
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi
}

ensure_testkube_cli() {
    if command -v testkube >/dev/null 2>&1; then
        return 0
    fi

    echo -e "  ${CYAN}[>]${NC} Testkube CLI not found on host. Installing..."
    if [ "${OS_NAME}" == "Darwin" ]; then
        brew install kubeshop/testkube/testkube || brew install testkube
    else
        curl -sSLf https://get.testkube.io | bash
        if ! command -v testkube >/dev/null 2>&1; then
            export PATH="$HOME/.testkube/bin:/usr/local/bin:$PATH"
        fi
    fi
}

compute_cluster_sizing() {
    CLUSTER_CPUS=4
    CLUSTER_MEM=8192

    if [ "$CI_MODE" = true ]; then
        CLUSTER_CPUS=2
        CLUSTER_MEM=4096
        echo -e "  ${CYAN}[>]${NC} CI Mode active: Sizing Minikube to ${CLUSTER_CPUS} CPUs, ${CLUSTER_MEM} MB RAM."
        return 0
    fi

    if [ -n "$CUSTOM_MEM" ]; then
        CLUSTER_MEM="$CUSTOM_MEM"
        echo -e "  ${CYAN}[>]${NC} Custom memory requested: Sizing Minikube to ${CLUSTER_MEM} MB RAM."
        return 0
    fi

    # Detect memory ceiling: prioritize Docker daemon limit, fallback to host system RAM
    local sys_mem_mb=0
    local docker_mem_bytes
    docker_mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
    if [ -n "$docker_mem_bytes" ] && [ "$docker_mem_bytes" -gt 0 ] 2>/dev/null; then
        sys_mem_mb=$(( docker_mem_bytes / 1024 / 1024 ))
    fi

    if [ -z "$sys_mem_mb" ] || [ "$sys_mem_mb" -eq 0 ] 2>/dev/null; then
        if [ "${OS_NAME}" == "Linux" ]; then
            sys_mem_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 0)
        elif [ "${OS_NAME}" == "Darwin" ]; then
            sys_mem_mb=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024)}' || echo 0)
        fi
    fi

    if [ -n "$sys_mem_mb" ] && [ "$sys_mem_mb" -gt 0 ] 2>/dev/null; then
        if [ "$sys_mem_mb" -lt 8192 ]; then
            # Available Docker/host ceiling is < 8192 MB (e.g. 8 GB VM or Docker Desktop allocation)
            local safe_mem=$(( sys_mem_mb - 1200 ))
            if [ "$safe_mem" -lt 3072 ]; then
                safe_mem=3072
            fi
            if [ "$safe_mem" -gt 6144 ]; then
                safe_mem=6144
            fi
            CLUSTER_MEM="$safe_mem"
            echo -e "  ${YELLOW}[!] Detected available Docker/host memory (${sys_mem_mb} MB) is below 8192 MB.${NC}"
            echo -e "  ${YELLOW}[!] Automatically adjusting primary node allocation to ${CLUSTER_MEM} MB to prevent RSRC_OVER_ALLOC_MEM.${NC}"
            echo -e "  ${YELLOW}[!] Note: 'minikube-m02' requires additional memory (~4 GB). For optimal stability, allocate 10–12 GB to Docker.${NC}"
        fi
    fi
}

helm_release_healthy() {
    local release="$1"
    local ns="$2"
    local status
    status=$(helm status "$release" -n "$ns" 2>/dev/null | awk '/^STATUS:/{print $2}' || echo "")
    [ "$status" == "deployed" ]
}

reconcile_runsc_toml() {
    awk '
    BEGIN { in_dup = 0; seen = 0; }
    index($0, "[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runsc]") == 1 {
        seen = seen + 1;
        if (seen > 1) {
            in_dup = 1;
            next;
        }
        print;
        next;
    }
    index($0, "[") == 1 {
        in_dup = 0;
    }
    {
        if (in_dup) {
            next;
        }
        print;
    }
    END {
        if (seen == 0) {
            printf "\n[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runsc]\n  runtime_type = \"io.containerd.runsc.v1\"\n";
        }
    }
    ' "$@"
}

main() {
    parse_args "$@"

    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}Minikube Agent Sandbox & Testkube Full-Stack Reconciler${NC}"
    echo -e "${BLUE}============================================================${NC}"

    # ==============================================================================
    # [0/8] Host OS, Architecture & Toolchain Discovery
    # ==============================================================================
    echo -e "\n${YELLOW}[0/8] Detecting Host OS, Architecture & Toolchain...${NC}"
    detect_platform
    echo -e "  ${CYAN}[>]${NC} Host: ${GREEN}${HOST_PLATFORM}${NC} | Arch: ${GREEN}${RAW_ARCH} (${ARCH_CLI})${NC} | Package Manager: ${GREEN}${PKG_MGR}${NC}"

    install_system_deps
    ensure_kubectl
    ensure_minikube
    ensure_helm
    ensure_testkube_cli

    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} Docker engine is running and accessible."
    else
        echo -e "  ${YELLOW}⚠ Docker engine is not currently running or accessible.${NC}"
        if [ "$PREFLIGHT_ONLY" = false ]; then
            echo -e "  ${RED}✗ Cannot proceed with Minikube provisioning without Docker. Please start Docker.${NC}"
            exit 1
        fi
    fi

    echo -e "  ${GREEN}✓${NC} Host platform and toolchain verified."

    if [ "$PREFLIGHT_ONLY" = true ]; then
        echo -e "\n${GREEN}============================================================${NC}"
        echo -e "${GREEN}Preflight & Toolchain Discovery Successful (--preflight-only)!${NC}"
        echo -e "${GREEN}============================================================${NC}"
        echo -e "Host: ${GREEN}${HOST_PLATFORM}${NC} | Arch: ${GREEN}${RAW_ARCH} (${ARCH_CLI})${NC} | Toolchain: ${GREEN}${PKG_MGR}${NC}"
        exit 0
    fi

    # ==============================================================================
    # [1/8] Check / Start Minikube & Multi-Node Worker Topology
    # ==============================================================================
    echo -e "\n${YELLOW}[1/8] Checking Minikube & Multi-Node Topology...${NC}"
    compute_cluster_sizing

    if ! minikube status >/dev/null 2>&1; then
        if minikube profile list 2>/dev/null | grep -E '^[| ]*minikube[ |]' >/dev/null 2>&1; then
            echo -e "  ${CYAN}[>]${NC} Existing Minikube profile found (stopped). Starting Minikube primary node..."
            minikube start --driver=docker --container-runtime=containerd --cpus="${CLUSTER_CPUS}" --memory="${CLUSTER_MEM}"
        else
            echo -e "  ${CYAN}[>]${NC} No Minikube cluster found. Creating fresh cluster from scratch (${CLUSTER_CPUS} CPUs, ${CLUSTER_MEM} MB RAM)..."
            minikube start --driver=docker --container-runtime=containerd --cpus="${CLUSTER_CPUS}" --memory="${CLUSTER_MEM}"
        fi
    else
        echo -e "  ${GREEN}✓${NC} Primary node 'minikube' is running."
    fi

    # Check if running cluster uses containerd runtime
    local cri_runtime
    cri_runtime=$(kubectl get node minikube -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}' 2>/dev/null || echo "")
    if [ -n "$cri_runtime" ] && echo "$cri_runtime" | grep -qE '^docker://'; then
        echo -e "  ${YELLOW}⚠ WARNING: Cluster node runtime is legacy dockershim (${cri_runtime}). Native gVisor RuntimeClass requires containerd.${NC}"
        echo -e "  ${YELLOW}If sandboxes fail to schedule, please recreate the cluster with containerd:${NC}"
        echo -e "      minikube delete && ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh\n"
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
    echo -e "\n${YELLOW}[2/8] Verifying control-plane health & internal host resolution...${NC}"
    echo -e "  ${CYAN}[>]${NC} Checking core DNS health in namespace 'kube-system'..."
    if ! kubectl -n kube-system get deployment coredns >/dev/null 2>&1; then
        echo -e "  ${RED}✗ CRITICAL: Core control-plane component 'coredns' is missing in 'kube-system'.${NC}"
        echo -e "  ${YELLOW}The cluster control plane is corrupted. Please rebuild cleanly from scratch:${NC}"
        echo -e "      minikube delete && ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh\n"
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} Control-plane DNS (kube-system/coredns) is healthy."

    # Disable legacy minikube gvisor addon (uses outdated shims that conflict with native runsc)
    echo -e "  ${CYAN}[>]${NC} Ensuring legacy Minikube gVisor addon is disabled..."
    minikube addons disable gvisor 2>/dev/null || true

    # Map control-plane.minikube.internal in node /etc/hosts
    local cp_ip
    cp_ip=$(minikube ip)
    echo -e "  ${CYAN}[>]${NC} Mapping control-plane.minikube.internal -> ${cp_ip} in node /etc/hosts..."
    minikube ssh "grep -q 'control-plane.minikube.internal' /etc/hosts || echo '${cp_ip} control-plane.minikube.internal' | sudo tee -a /etc/hosts >/dev/null"
    echo -e "  ${GREEN}✓${NC} control-plane.minikube.internal mapped to ${cp_ip}."

    # ==============================================================================
    # [3/8] Native Google gVisor (runsc) Runtime & Containerd TOML Healing
    # ==============================================================================
    echo -e "\n${YELLOW}[3/8] Reconciling containerd & native gVisor (runsc) runtime...${NC}"
    echo -e "  ${CYAN}[>]${NC} Checking native Google gVisor (runsc) binary and containerd runtime on primary node..."
    minikube ssh '
set -euo pipefail
# Clean up stale/broken OBS kubic repositories baked into older minikube kicbase images
sudo rm -f /etc/apt/sources.list.d/*kubic*.list /etc/apt/sources.list.d/*cri-o*.list 2>/dev/null || true

# Install official Google runsc binary if missing, corrupted, or non-functional
if ! /usr/bin/runsc --version >/dev/null 2>&1 || ! head -c 4 /usr/bin/containerd-shim-runsc-v1 2>/dev/null | grep -q ELF; then
    echo "  -> Downloading official Google gVisor release archive..."
    NODE_ARCH=$(uname -m)
    case "$NODE_ARCH" in
        x86_64|amd64) GVISOR_ARCH="x86_64" ;;
        aarch64|arm64) GVISOR_ARCH="aarch64" ;;
        *) GVISOR_ARCH="$NODE_ARCH" ;;
    esac
    URL="https://storage.googleapis.com/gvisor/releases/release/latest/${GVISOR_ARCH}"

    INSTALLED=false
    # Method 1: Official bz2 release archive (contains runsc + containerd-shim-runsc-v1)
    if curl -fsSL --retry 3 --retry-delay 2 "${URL}/gvisor.tar.bz2" -o /tmp/gvisor.tar.bz2 2>/dev/null; then
        if tar -xjf /tmp/gvisor.tar.bz2 -C /tmp/ 2>/dev/null; then
            chmod a+rx /tmp/runsc /tmp/containerd-shim-runsc-v1 2>/dev/null || true
            sudo mv /tmp/runsc /tmp/containerd-shim-runsc-v1 /usr/bin/
            rm -f /tmp/gvisor.tar.bz2
            INSTALLED=true
        fi
    fi

    # Method 2: Official zstd release archive
    if [ "$INSTALLED" = false ] && curl -fsSL --retry 3 --retry-delay 2 "${URL}/gvisor.tar.zstd" -o /tmp/gvisor.tar.zstd 2>/dev/null; then
        if tar --zstd -xf /tmp/gvisor.tar.zstd -C /tmp/ 2>/dev/null; then
            chmod a+rx /tmp/runsc /tmp/containerd-shim-runsc-v1 2>/dev/null || true
            sudo mv /tmp/runsc /tmp/containerd-shim-runsc-v1 /usr/bin/
            rm -f /tmp/gvisor.tar.zstd
            INSTALLED=true
        fi
    fi

    # Method 3: Fallback to official Google APT repository
    if [ "$INSTALLED" = false ] && command -v apt-get >/dev/null 2>&1; then
        echo "  -> Fallback: installing gVisor via Google APT repository..."
        curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg --yes 2>/dev/null || true
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" | sudo tee /etc/apt/sources.list.d/gvisor.list >/dev/null
        sudo apt-get update -o Dir::Etc::sourcelist="sources.list.d/gvisor.list" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0" 2>/dev/null || sudo apt-get update 2>/dev/null || true
        sudo apt-get install -y runsc 2>/dev/null || true
        if /usr/bin/runsc --version >/dev/null 2>&1; then
            INSTALLED=true
        fi
    fi

    if ! /usr/bin/runsc --version >/dev/null 2>&1; then
        echo "ERROR: Failed to install Google gVisor (runsc) on Minikube node." >&2
        exit 1
    fi
fi

# Ensure containerd config.toml exists and deduplicate runsc stanza using pure POSIX awk
CONFIG_PATH="/etc/containerd/config.toml"
if [ ! -f "$CONFIG_PATH" ]; then
    sudo mkdir -p /etc/containerd
    if command -v containerd >/dev/null 2>&1; then
        containerd config default | sudo tee "$CONFIG_PATH" >/dev/null 2>&1 || sudo touch "$CONFIG_PATH"
    else
        sudo touch "$CONFIG_PATH"
    fi
fi

awk '\''
BEGIN { in_dup = 0; seen = 0; }
index($0, "[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runsc]") == 1 {
    seen = seen + 1;
    if (seen > 1) {
        in_dup = 1;
        next;
    }
    print;
    next;
}
index($0, "[") == 1 {
    in_dup = 0;
}
{
    if (in_dup) {
        next;
    }
    print;
}
END {
    if (seen == 0) {
        printf "\n[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runsc]\n  runtime_type = \"io.containerd.runsc.v1\"\n";
    }
}
'\'' "$CONFIG_PATH" > /tmp/config.toml.clean

if ! cmp -s "$CONFIG_PATH" /tmp/config.toml.clean; then
    echo "  -> Updating containerd config.toml with deduplicated runsc runtime handler..."
    sudo mv /tmp/config.toml.clean "$CONFIG_PATH"
    sudo systemctl restart containerd
else
    rm -f /tmp/config.toml.clean
fi
'

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
    echo -e "\n${YELLOW}[4/8] Checking NGINX Ingress Controller...${NC}"

    if ! kubectl get ns ingress-nginx >/dev/null 2>&1 || \
       ! kubectl -n ingress-nginx get deployment ingress-nginx-controller >/dev/null 2>&1; then
        echo -e "  ${CYAN}[>]${NC} Ingress controller missing. Enabling / recovering Minikube ingress addon..."
        minikube addons disable ingress >/dev/null 2>&1 || true
        minikube addons enable ingress
    fi

    echo -e "  ${CYAN}[>]${NC} Waiting for 'ingress-nginx-controller' deployment to become available..."
    for i in {1..30}; do
        if kubectl -n ingress-nginx get deployment ingress-nginx-controller >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
    echo -e "  ${GREEN}✓${NC} NGINX Ingress Controller is Ready."

    # ==============================================================================
    # [5/8] Reconcile Observability Stack (Prometheus, Grafana & Dashboards)
    # ==============================================================================
    echo -e "\n${YELLOW}[5/8] Reconciling Observability Stack (Prometheus & Grafana)...${NC}"

    if ! helm_release_healthy monitoring monitoring || \
       ! kubectl -n monitoring get deployment monitoring-grafana >/dev/null 2>&1 || \
       ! kubectl -n monitoring get deployment monitoring-kube-prometheus-operator >/dev/null 2>&1 || \
       ! kubectl -n monitoring get deployment monitoring-kube-state-metrics >/dev/null 2>&1 || \
       ! kubectl -n monitoring get statefulset prometheus-monitoring-kube-prometheus-prometheus >/dev/null 2>&1 || \
       [ "${FORCE_HELM}" = true ]; then
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
    echo -e "\n${YELLOW}[6/8] Reconciling mogenius Agent Sandbox, Warm Pool & Router...${NC}"

    if ! helm_release_healthy agent-sandbox agent-sandbox-system || \
       ! kubectl -n agent-sandbox-system get deployment agent-sandbox-controller >/dev/null 2>&1 || \
       ! kubectl -n agent-sandbox get sandboxwarmpool default >/dev/null 2>&1 || \
       [ "${FORCE_HELM}" = true ]; then
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
    echo -e "\n${YELLOW}[7/8] Reconciling Out-of-Sandbox Egress & Credential Broker...${NC}"

    echo -e "  ${CYAN}[>]${NC} Applying egress-broker deployment, service, and zero-trust NetworkPolicies..."
    kubectl apply -f "${K8S_DIR}/threat-model/egress-broker.yaml" >/dev/null

    echo -e "  ${CYAN}[>]${NC} Waiting for egress-broker rollout status (verifying /healthz probes)..."
    kubectl -n sandbox-egress-system rollout status deployment/egress-broker --timeout=180s
    echo -e "  ${GREEN}✓${NC} Egress & Credential Broker and cross-namespace NetworkPolicies reconciled."

    # ==============================================================================
    # [8/8] Reconcile Testkube OSS CLI, Worker Node Stack (minikube-m02) & Workflows
    # ==============================================================================
    echo -e "\n${YELLOW}[8/8] Reconciling Testkube OSS & Benchmark/Security TestWorkflows...${NC}"

    ensure_testkube_cli

    local tk_api_ready tk_mongo_ready tk_nats_ready tk_minio_ready
    tk_api_ready=$(kubectl -n testkube get deployment testkube-api-server -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    tk_mongo_ready=$(kubectl -n testkube get deployment testkube-mongodb -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    tk_nats_ready=$(kubectl -n testkube get statefulset testkube-nats -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    tk_minio_ready=$(kubectl -n testkube get deployment testkube-minio-testkube -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

    if ! helm_release_healthy testkube testkube || \
       [ "${tk_api_ready:-0}" -lt 1 ] || \
       [ "${tk_mongo_ready:-0}" -lt 1 ] || \
       [ "${tk_nats_ready:-0}" -lt 1 ] || \
       [ "${tk_minio_ready:-0}" -lt 1 ] || \
       [ "${FORCE_HELM}" = true ]; then
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

    echo -e "  ${CYAN}[>]${NC} Reconciling Testkube RBAC permissions..."
    kubectl apply -f "${K8S_DIR}/testkube/rbac.yaml" >/dev/null

    echo -e "  ${CYAN}[>]${NC} Discovering and registering TestWorkflows from codebase..."
    local workflow_files=()
    while IFS= read -r file; do
        [ -n "$file" ] && workflow_files+=("$file")
    done < <(find "${K8S_DIR}/testkube" -maxdepth 1 -name "test-workflow*.yaml" | sort)

    local test_scripts=()
    while IFS= read -r file; do
        [ -n "$file" ] && test_scripts+=("$file")
    done < <(find "${K8S_DIR}/testkube/tests" -maxdepth 1 -type f | sort)

    for wf in "${workflow_files[@]}"; do
        echo -e "     • Applying workflow manifest: $(basename "$wf")"
        kubectl apply -f "$wf" >/dev/null
    done

    local registered_wf_count
    registered_wf_count=$(kubectl -n testkube get testworkflows --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  ${GREEN}✓${NC} Reconciled ${registered_wf_count}/${#workflow_files[@]} TestWorkflows active in cluster (${#test_scripts[@]} benchmark/probe scripts in 'tests/')."

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
    echo -e "\n${YELLOW}Verifying core architecture service endpoints across all namespaces...${NC}"

    local core_services=(
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

    local all_services_ok=true
    for item in "${core_services[@]}"; do
        local ns svc ips
        IFS=":" read -r ns svc <<< "$item"
        ips=$(kubectl -n "$ns" get endpointslices -l "kubernetes.io/service-name=$svc" -o jsonpath="{.items[*].endpoints[?(@.conditions.ready==true)].addresses[*]}" 2>/dev/null || echo "")
        if [ -z "$ips" ]; then
            ips=$(kubectl -n "$ns" get endpoints "$svc" -o jsonpath="{.subsets[*].addresses[*].ip}" 2>/dev/null || echo "")
        fi

        if [ -n "$ips" ]; then
            echo -e "  ${GREEN}✓${NC} [${ns}] ${svc} -> (${ips})"
        else
            echo -e "  ${RED}✗${NC} [${ns}] ${svc} -> No active endpoints!"
            all_services_ok=false
        fi
    done

    if [ "$all_services_ok" = false ]; then
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
    echo "Active TestWorkflows in 'testkube' (${registered_wf_count}/${#workflow_files[@]} ready, ${#test_scripts[@]} scripts in 'tests/'):"
    kubectl -n testkube get testworkflows
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
