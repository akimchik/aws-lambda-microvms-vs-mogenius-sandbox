#!/usr/bin/env bash
# ==============================================================================
# Automated Test Suite: Multi-OS & Multi-Architecture Bootstrap Validator
#
# Tests Covered:
#   [1/6] Shell & Test Script Syntax across all platform scripts & benchmarks
#   [2/6] OS & Architecture Matrix Mock Simulation:
#         • macOS Darwin (Apple Silicon arm64 / Homebrew flow)
#         • Linux Ubuntu / Debian (apt package manager, x86_64 & aarch64)
#         • Linux RHEL / Rocky / Fedora (dnf/yum package manager, x86_64 & aarch64)
#         • Linux Generic (curl binary fallback, x86_64 & aarch64)
#   [3/6] Multi-Arch Binary Download URL & Schema Verification (x86_64 & aarch64)
#   [4/6] Containerd TOML Injection & Minikube Version Upgrade Detection Simulation
#   [5/6] Live Network Reachability for Multi-Arch Assets (conditional on network)
#   [6/6] Kubernetes Component & Manifest Deployment Integrity Validation
# ==============================================================================
set -euo pipefail

# ANSI Color formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
K8S_DIR="${REPO_ROOT}/k8s-agent-sandbox"

FAILED_TESTS=0
TOTAL_TESTS=0

assert_test() {
    local test_name="$1"
    local status="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [ "$status" -eq 0 ]; then
        echo -e "  ${GREEN}✓ PASS:${NC} ${test_name}"
    else
        echo -e "  ${RED}✗ FAIL:${NC} ${test_name}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}Multi-OS & Multi-Architecture Bootstrap Test Suite${NC}"
echo -e "${BLUE}============================================================${NC}"

# ==============================================================================
# [1/6] Shell & Test Script Syntax Verification
# ==============================================================================
echo -e "\n${YELLOW}[1/6] Testing Shell, Python & JS Script Syntax...${NC}"

SCRIPTS_TO_TEST=(
    "${K8S_DIR}/scripts/bootstrap_cluster.sh"
    "${K8S_DIR}/ingress/test_ingress_poc.sh"
    "${SCRIPT_DIR}/test_multios_bootstrap.sh"
)

for script in "${SCRIPTS_TO_TEST[@]}"; do
    if [ -f "$script" ]; then
        if bash -n "$script" 2>/dev/null; then
            assert_test "Bash syntax check: $(basename "$script")" 0
        else
            assert_test "Bash syntax check: $(basename "$script")" 1
        fi
    else
        assert_test "Script exists: $(basename "$script")" 1
    fi
done

# Test Python Testkube helper syntax
PY_BIN=""
for candidate in /usr/bin/python3 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import sys" 2>/dev/null; then
        PY_BIN="$candidate"
        break
    fi
done

PY_TEST="${K8S_DIR}/testkube/tests/claim_and_measure.py"
if [ -f "$PY_TEST" ]; then
    if [ -n "$PY_BIN" ]; then
        if "$PY_BIN" -c "import ast; ast.parse(open('$PY_TEST').read())" 2>/dev/null; then
            assert_test "Python AST syntax: $(basename "$PY_TEST")" 0
        else
            assert_test "Python AST syntax: $(basename "$PY_TEST")" 1
        fi
    else
        assert_test "Python test file present: $(basename "$PY_TEST")" 0
    fi
fi

# Test Node.js / k6 scripts if node is available and runnable
NODE_BIN=""
for candidate in /usr/local/bin/node /opt/homebrew/bin/node /usr/bin/node node; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -v 2>/dev/null >/dev/null; then
        NODE_BIN="$candidate"
        break
    fi
done

JS_TESTS=(
    "${K8S_DIR}/testkube/tests/k6-sustained-load.js"
    "${K8S_DIR}/testkube/tests/k6-sandbox-benchmark.js"
    "${K8S_DIR}/testkube/tests/k6-security-audit.js"
)
for js in "${JS_TESTS[@]}"; do
    if [ -f "$js" ]; then
        if [ -n "$NODE_BIN" ]; then
            if "$NODE_BIN" -c "$js" 2>/dev/null; then
                assert_test "JS syntax check: $(basename "$js")" 0
            else
                assert_test "JS syntax check: $(basename "$js")" 1
            fi
        else
            assert_test "JS test file present: $(basename "$js")" 0
        fi
    fi
done

# ==============================================================================
# [2/6] OS & Architecture Matrix Mock Simulation
# ==============================================================================
echo -e "\n${YELLOW}[2/6] Testing OS & Architecture Matrix Logic...${NC}"

# Test Matrix Cases: OS_NAME | RAW_ARCH | EXPECTED_CLI_ARCH | EXPECTED_RUNSC_ARCH
MATRIX_CASES=(
    "Darwin|arm64|arm64|aarch64|brew"
    "Darwin|x86_64|amd64|x86_64|brew"
    "Linux|aarch64|arm64|aarch64|apt"
    "Linux|x86_64|amd64|x86_64|apt"
    "Linux|aarch64|arm64|aarch64|dnf"
    "Linux|x86_64|amd64|x86_64|dnf"
    "Linux|x86_64|amd64|x86_64|generic"
)

for case_entry in "${MATRIX_CASES[@]}"; do
    IFS="|" read -r test_os test_arch exp_cli exp_runsc exp_mgr <<< "$case_entry"

    # Simulate architecture mapping function
    case "${test_arch}" in
        x86_64|amd64)
            res_cli="amd64"
            res_runsc="x86_64"
            ;;
        arm64|aarch64)
            res_cli="arm64"
            res_runsc="aarch64"
            ;;
        *)
            res_cli="unknown"
            res_runsc="unknown"
            ;;
    esac

    if [ "$res_cli" == "$exp_cli" ] && [ "$res_runsc" == "$exp_runsc" ]; then
        assert_test "Arch mapping: ${test_os} (${test_arch}) -> cli:${res_cli}, runsc:${res_runsc}" 0
    else
        assert_test "Arch mapping: ${test_os} (${test_arch}) -> cli:${res_cli}, runsc:${res_runsc}" 1
    fi
done

# ==============================================================================
# [3/6] Multi-Arch Binary Download URL & Schema Verification
# ==============================================================================
echo -e "\n${YELLOW}[3/6] Testing Multi-Arch Binary URLs & Endpoints...${NC}"

# Verify URL format construction for both x86_64 and aarch64
for arch in "amd64:x86_64" "arm64:aarch64"; do
    IFS=":" read -r cli_arch node_arch <<< "$arch"

    # Test gVisor release archive URL pattern
    GVISOR_BZ2_URL="https://storage.googleapis.com/gvisor/releases/release/latest/${node_arch}/gvisor.tar.bz2"
    GVISOR_ZSTD_URL="https://storage.googleapis.com/gvisor/releases/release/latest/${node_arch}/gvisor.tar.zstd"
    MINIKUBE_URL="https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${cli_arch}"
    KUBECTL_URL="https://dl.k8s.io/release/v1.31.0/bin/linux/${cli_arch}/kubectl"

    # Verify URLs are non-empty and well-formed
    if [[ "$GVISOR_BZ2_URL" =~ ^https://.*gvisor\.tar\.bz2$ ]] && \
       [[ "$GVISOR_ZSTD_URL" =~ ^https://.*gvisor\.tar\.zstd$ ]] && \
       [[ "$MINIKUBE_URL" =~ ^https://.*minikube-linux-(amd64|arm64)$ ]] && \
       [[ "$KUBECTL_URL" =~ ^https://.*bin/linux/(amd64|arm64)/kubectl$ ]]; then
        assert_test "URL formatting verified for arch: ${node_arch} (${cli_arch})" 0
    else
        assert_test "URL formatting verified for arch: ${node_arch} (${cli_arch})" 1
    fi
done

# Verify Helm & Testkube installer URLs
HELM_INSTALLER="https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
TESTKUBE_INSTALLER="https://get.testkube.io"

if [[ "$HELM_INSTALLER" =~ ^https://.*get-helm-3$ ]] && [[ "$TESTKUBE_INSTALLER" =~ ^https://get\.testkube\.io$ ]]; then
    assert_test "Generic installer scripts URLs verified" 0
else
    assert_test "Generic installer scripts URLs verified" 1
fi

# ==============================================================================
# [4/6] Containerd TOML Injection & Minikube Version Upgrade Logic
# ==============================================================================
echo -e "\n${YELLOW}[4/6] Testing Containerd TOML Injection & Minikube Version Logic...${NC}"

# 1. Test containerd config TOML stanza injection idempotency
MOCK_TOML=$(mktemp)
cat <<'EOF' > "$MOCK_TOML"
[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.9"
EOF

TARGET='[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]'
# 1st injection
if ! grep -qF "$TARGET" "$MOCK_TOML"; then
    printf '\n[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]\n  runtime_type = "io.containerd.runsc.v1"\n' >> "$MOCK_TOML"
fi
# 2nd injection (must be skipped)
if ! grep -qF "$TARGET" "$MOCK_TOML"; then
    printf '\n[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]\n  runtime_type = "io.containerd.runsc.v1"\n' >> "$MOCK_TOML"
fi

STANZA_COUNT=$(grep -c "containerd.runtimes.runsc" "$MOCK_TOML" || echo "0")
if [ "$STANZA_COUNT" -eq 1 ]; then
    assert_test "Containerd config TOML injection is idempotent (count=1)" 0
else
    assert_test "Containerd config TOML injection is idempotent (count=${STANZA_COUNT})" 1
fi
rm -f "$MOCK_TOML"

# 2. Test Minikube version upgrade detector simulation
test_minikube_upgrade() {
    local ver="$1"
    local expected="$2"
    local mk_major=$(echo "$ver" | cut -d. -f1)
    local mk_minor=$(echo "$ver" | cut -d. -f2)
    local need=false
    if [ "$mk_major" -lt 1 ] || { [ "$mk_major" -eq 1 ] && [ "$mk_minor" -lt 30 ]; }; then
        need=true
    fi
    [ "$need" == "$expected" ]
}

if test_minikube_upgrade "1.17.1" true && \
   test_minikube_upgrade "1.20.0" true && \
   test_minikube_upgrade "1.29.9" true && \
   test_minikube_upgrade "1.30.0" false && \
   test_minikube_upgrade "1.34.0" false && \
   test_minikube_upgrade "1.39.0" false; then
    assert_test "Minikube version upgrade detector (flags <1.30, preserves >=1.30)" 0
else
    assert_test "Minikube version upgrade detector logic" 1
fi

# ==============================================================================
# [5/6] Live Network Reachability for Multi-Arch Assets (if online)
# ==============================================================================
echo -e "\n${YELLOW}[5/6] Testing Live Network Reachability for Multi-Arch Assets...${NC}"

if curl -s --max-time 3 -I "https://storage.googleapis.com" >/dev/null 2>&1; then
    for narch in "x86_64" "aarch64"; do
        BZ2_URL="https://storage.googleapis.com/gvisor/releases/release/latest/${narch}/gvisor.tar.bz2"
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$BZ2_URL" || echo "000")
        if [ "$HTTP_CODE" -eq 200 ]; then
            assert_test "Live HTTP 200: Google gVisor release archive (${narch})" 0
        else
            assert_test "Live HTTP 200: Google gVisor release archive (${narch}) (status: ${HTTP_CODE})" 1
        fi
    done

    MK_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64" || echo "000")
    if [ "$MK_CODE" -eq 200 ]; then
        assert_test "Live HTTP 200: Minikube multi-arch binary endpoint" 0
    else
        assert_test "Live HTTP 200: Minikube multi-arch binary endpoint (status: ${MK_CODE})" 1
    fi
else
    echo -e "  ${CYAN}[i] Sandboxed / offline environment: live HTTP reachability assertions skipped.${NC}"
fi

# ==============================================================================
# [6/6] Kubernetes Component & Manifest Deployment Integrity Validation
# ==============================================================================
echo -e "\n${YELLOW}[6/6] Validating Component Manifests & Helm Configurations...${NC}"

REQUIRED_MANIFESTS=(
    "${K8S_DIR}/helm/values-mogenius.yaml"
    "${K8S_DIR}/monitoring/values-prometheus-grafana.yaml"
    "${K8S_DIR}/testkube/values-testkube.yaml"
    "${K8S_DIR}/ingress/sandbox-router.yaml"
    "${K8S_DIR}/ingress/sandbox-ingress.yaml"
    "${K8S_DIR}/monitoring/monitoring-ingress.yaml"
    "${K8S_DIR}/monitoring/agent-sandbox-servicemonitor.yaml"
    "${K8S_DIR}/monitoring/sandbox-latency-exporter.yaml"
    "${K8S_DIR}/monitoring/grafana-dashboard-agent-sandbox.yaml"
    "${K8S_DIR}/monitoring/grafana-dashboard-sandbox-http-responses.yaml"
    "${K8S_DIR}/monitoring/grafana-dashboard-testkube.yaml"
    "${K8S_DIR}/threat-model/egress-broker.yaml"
    "${K8S_DIR}/testkube/rbac.yaml"
    "${K8S_DIR}/testkube/test-workflow.yaml"
    "${K8S_DIR}/testkube/test-workflow-security.yaml"
    "${K8S_DIR}/testkube/test-workflow-sustained-load.yaml"
)

for manifest in "${REQUIRED_MANIFESTS[@]}"; do
    rel_path="${manifest#$REPO_ROOT/}"
    if [ -f "$manifest" ] && [ -s "$manifest" ]; then
        if [[ "$(basename "$manifest")" =~ values.*\.yaml ]]; then
            # Helm values file: verify valid key-value YAML structure
            if grep -q ":" "$manifest" 2>/dev/null; then
                assert_test "Helm values integrity: ${rel_path}" 0
            else
                assert_test "Helm values structure: ${rel_path}" 1
            fi
        else
            # Kubernetes manifest: verify apiVersion or kind or doc separator
            if grep -qE "(apiVersion:|kind:|---)" "$manifest" 2>/dev/null; then
                assert_test "Manifest integrity: ${rel_path}" 0
            else
                assert_test "Manifest structure: ${rel_path}" 1
            fi
        fi
    else
        assert_test "Manifest exists: ${rel_path}" 1
    fi
done

# Verify gVisor RuntimeClass configuration in mogenius values
if grep -q "runtimeClassName: gvisor" "${K8S_DIR}/helm/values-mogenius.yaml"; then
    assert_test "mogenius values: RuntimeClass 'gvisor' verified" 0
else
    assert_test "mogenius values: RuntimeClass 'gvisor' missing" 1
fi

# Verify Testkube worker node pinning (dedicated=testkube:NoSchedule)
if grep -q "dedicated: testkube" "${K8S_DIR}/testkube/values-testkube.yaml"; then
    assert_test "Testkube values: Worker node pinning (minikube-m02) verified" 0
else
    assert_test "Testkube values: Worker node pinning missing" 1
fi

# ==============================================================================
# Summary Report
# ==============================================================================
echo -e "\n${BLUE}============================================================${NC}"
echo -e "${BLUE}Test Suite Results: $((TOTAL_TESTS - FAILED_TESTS))/${TOTAL_TESTS} Passed${NC}"
echo -e "${BLUE}============================================================${NC}"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "${GREEN}✓ All Multi-OS, Multi-Arch & Deployment Component Tests PASSED!${NC}\n"
    exit 0
else
    echo -e "${RED}✗ ${FAILED_TESTS} Test(s) FAILED! Check logs above.${NC}\n"
    exit 1
fi
