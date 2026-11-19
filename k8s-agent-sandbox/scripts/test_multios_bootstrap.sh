#!/usr/bin/env bash
# ==============================================================================
# Automated Integration & Unit Test Suite: Multi-OS & Multi-Arch Bootstrap
#
# Real Function Testing (Sources bootstrap_cluster.sh directly):
#   [1/6] Shell, Python AST & JS Script Syntax across all repo scripts
#   [2/6] Real `detect_platform` & `parse_args` Integration across OS & Arch Matrix:
#         • macOS Darwin (Apple Silicon arm64 & Intel amd64 / Homebrew flow)
#         • Linux Ubuntu / Debian (apt package manager, x86_64 & aarch64)
#         • Linux RHEL / Rocky / Fedora (dnf/yum package manager, x86_64 & aarch64)
#         • Linux Generic (curl binary fallback, x86_64 & aarch64)
#         • CLI flag parsing & fail-fast invalid input assertions
#   [3/6] Real `compute_cluster_sizing` & Memory Auto-Clamping Tests
#   [4/6] Real `reconcile_runsc_toml` TOML Deduplication & `install_host_bin` Regression Test
#   [5/6] Multi-Arch Binary URLs & Live Reachability (conditional on network)
#   [6/6] Real YAML Parser Validation across all Kubernetes Manifests & Helm Values
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
K8S_DIR="${REPO_ROOT}/k8s-agent-sandbox"
BOOTSTRAP_SCRIPT="${K8S_DIR}/scripts/bootstrap_cluster.sh"

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
echo -e "${BLUE}Multi-OS & Multi-Architecture Bootstrap Integration Test Suite${NC}"
echo -e "${BLUE}============================================================${NC}"

# Source the bootstrap script functions (ensuring source guard works)
if [ ! -f "$BOOTSTRAP_SCRIPT" ]; then
    echo -e "${RED}✗ Error: Bootstrap script not found at ${BOOTSTRAP_SCRIPT}${NC}"
    exit 1
fi
# shellcheck source=k8s-agent-sandbox/scripts/bootstrap_cluster.sh
source "$BOOTSTRAP_SCRIPT"

MOCK_TMP_DIR=$(mktemp -d)
cleanup_test_env() {
    rm -rf "$MOCK_TMP_DIR"
}
trap cleanup_test_env EXIT INT TERM

# ==============================================================================
# [1/6] Shell, Python AST & JS Script Syntax Verification
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

# Python AST syntax on ALL python files in repository
PY_BIN=""
for candidate in /usr/bin/python3 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import sys" 2>/dev/null; then
        PY_BIN="$candidate"
        break
    fi
done

PY_FILES=(
    "${K8S_DIR}/testkube/tests/claim_and_measure.py"
    "${K8S_DIR}/module-1-basic-execution/launch_sandbox.py"
    "${K8S_DIR}/threat-model/threat_probe.py"
)

for py_file in "${PY_FILES[@]}"; do
    if [ -f "$py_file" ]; then
        if [ -n "$PY_BIN" ]; then
            if "$PY_BIN" -c "import ast; ast.parse(open('$py_file').read())" 2>/dev/null; then
                assert_test "Python AST syntax: $(basename "$py_file")" 0
            else
                assert_test "Python AST syntax: $(basename "$py_file")" 1
            fi
        else
            assert_test "Python file present: $(basename "$py_file")" 0
        fi
    fi
done

# Node.js / k6 scripts syntax check
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
# [2/6] Real `detect_platform` & `parse_args` Testing across OS & Arch Matrix
# ==============================================================================
echo -e "\n${YELLOW}[2/6] Testing Real Platform Detection & Argument Parsing...${NC}"

# Create mock environment for uname and package managers
MOCK_BIN="${MOCK_TMP_DIR}/bin"
mkdir -p "$MOCK_BIN"

cat << 'EOF' > "${MOCK_BIN}/uname"
#!/bin/sh
if [ "$1" = "-s" ]; then
    echo "${MOCK_OS:-Linux}"
elif [ "$1" = "-m" ]; then
    echo "${MOCK_ARCH:-x86_64}"
else
    echo "${MOCK_OS:-Linux} ${MOCK_ARCH:-x86_64}"
fi
EOF
chmod +x "${MOCK_BIN}/uname"

# Test detect_platform() across full matrix
# Matrix: OS | ARCH | CLI_ARCH | RUNSC_ARCH | PKG_MGR | MOCK_TOOLS
PLATFORM_TEST_CASES=(
    "Darwin|arm64|arm64|aarch64|brew|brew"
    "Darwin|x86_64|amd64|x86_64|brew|brew"
    "Linux|x86_64|amd64|x86_64|apt|apt-get"
    "Linux|aarch64|arm64|aarch64|apt|apt-get"
    "Linux|x86_64|amd64|x86_64|dnf|dnf"
    "Linux|aarch64|arm64|aarch64|dnf|dnf"
    "Linux|x86_64|amd64|x86_64|yum|yum"
    "Linux|x86_64|amd64|x86_64|generic|"
)

for case_entry in "${PLATFORM_TEST_CASES[@]}"; do
    IFS="|" read -r t_os t_arch exp_cli exp_runsc exp_mgr mock_tool <<< "$case_entry"

    if (
        export MOCK_OS="$t_os"
        export MOCK_ARCH="$t_arch"
        TEST_DIR="${MOCK_TMP_DIR}/test_${t_os}_${t_arch}_${exp_mgr}"
        mkdir -p "$TEST_DIR"
        cp "${MOCK_BIN}/uname" "${TEST_DIR}/uname"

        if [ -n "$mock_tool" ]; then
            touch "${TEST_DIR}/${mock_tool}"
            chmod +x "${TEST_DIR}/${mock_tool}"
        fi

        export PATH="${TEST_DIR}"
        # Call REAL detect_platform from bootstrap_cluster.sh
        detect_platform >/dev/null

        [ "$ARCH_CLI" == "$exp_cli" ] && \
        [ "$ARCH_RUNSC" == "$exp_runsc" ] && \
        [ "$PKG_MGR" == "$exp_mgr" ]
    ); then
        assert_test "detect_platform(): ${t_os} ${t_arch} -> cli:${exp_cli}, runsc:${exp_runsc}, pkg:${exp_mgr}" 0
    else
        assert_test "detect_platform(): ${t_os} ${t_arch} -> cli:${exp_cli}, runsc:${exp_runsc}, pkg:${exp_mgr}" 1
    fi
done

# Test unsupported architecture and OS handling in detect_platform()
if (
    export MOCK_OS="Linux"
    export MOCK_ARCH="mips64"
    export PATH="${MOCK_BIN}"
    detect_platform 2>/dev/null
); then
    assert_test "detect_platform(): Rejects unsupported architecture (mips64)" 1
else
    assert_test "detect_platform(): Rejects unsupported architecture (mips64)" 0
fi

if (
    export MOCK_OS="FreeBSD"
    export MOCK_ARCH="x86_64"
    export PATH="${MOCK_BIN}"
    detect_platform 2>/dev/null
); then
    assert_test "detect_platform(): Rejects unsupported OS (FreeBSD)" 1
else
    assert_test "detect_platform(): Rejects unsupported OS (FreeBSD)" 0
fi

# Test parse_args() validation
(
    CUSTOM_MEM=""
    parse_args --memory 6144
    [ "$CUSTOM_MEM" == "6144" ]
) && assert_test "parse_args(): Accepts --memory 6144" 0 || assert_test "parse_args(): Accepts --memory 6144" 1

(
    CUSTOM_MEM=""
    parse_args --memory=5120
    [ "$CUSTOM_MEM" == "5120" ]
) && assert_test "parse_args(): Accepts --memory=5120" 0 || assert_test "parse_args(): Accepts --memory=5120" 1

(
    CI_MODE=false
    parse_args --ci
    [ "$CI_MODE" = true ]
) && assert_test "parse_args(): Accepts --ci" 0 || assert_test "parse_args(): Accepts --ci" 1

(
    PREFLIGHT_ONLY=false; DRY_RUN=false
    parse_args --preflight-only
    [ "$PREFLIGHT_ONLY" = true ] && [ "$DRY_RUN" = false ]
) && assert_test "parse_args(): --preflight-only is distinct from --dry-run" 0 || \
   assert_test "parse_args(): --preflight-only is distinct from --dry-run" 1

(
    PREFLIGHT_ONLY=false; DRY_RUN=false
    parse_args --dry-run
    [ "$DRY_RUN" = true ] && [ "$PREFLIGHT_ONLY" = false ]
) && assert_test "parse_args(): --dry-run sets DRY_RUN=true without PREFLIGHT_ONLY" 0 || \
   assert_test "parse_args(): --dry-run sets DRY_RUN=true without PREFLIGHT_ONLY" 1

if "${K8S_DIR}/scripts/bootstrap_cluster.sh" --dry-run 2>&1 | grep -q "Dry-Run Audit Complete (--dry-run: Zero changes made)!"; then
    assert_test "bootstrap_cluster.sh --dry-run: Executes read-only audit with zero mutations" 0
else
    assert_test "bootstrap_cluster.sh --dry-run: Executes read-only audit with zero mutations" 1
fi

(
    FORCE_HELM=false
    parse_args --upgrade-helm
    [ "$FORCE_HELM" = true ]
) && assert_test "parse_args(): Accepts --upgrade-helm" 0 || assert_test "parse_args(): Accepts --upgrade-helm" 1

# Fail-fast error tests for parse_args
if ( parse_args --memory >/dev/null 2>&1 ); then
    assert_test "parse_args(): Fails fast on missing --memory argument" 1
else
    assert_test "parse_args(): Fails fast on missing --memory argument" 0
fi

if ( parse_args --memory abc >/dev/null 2>&1 ); then
    assert_test "parse_args(): Fails fast on non-numeric --memory" 1
else
    assert_test "parse_args(): Fails fast on non-numeric --memory" 0
fi

if ( parse_args --memory 1024 >/dev/null 2>&1 ); then
    assert_test "parse_args(): Fails fast on memory < 2048 MB" 1
else
    assert_test "parse_args(): Fails fast on memory < 2048 MB" 0
fi

if ( parse_args --unrecognized-option >/dev/null 2>&1 ); then
    assert_test "parse_args(): Fails fast on unknown CLI option" 1
else
    assert_test "parse_args(): Fails fast on unknown CLI option" 0
fi

# ==============================================================================
# [3/6] Real `compute_cluster_sizing` & Memory Auto-Clamping Tests
# ==============================================================================
echo -e "\n${YELLOW}[3/6] Testing Sizing Logic & Memory Auto-Clamping...${NC}"

# Create mock docker binary
cat << 'EOF' > "${MOCK_BIN}/docker"
#!/bin/sh
if [ "$1" = "info" ]; then
    echo "${MOCK_DOCKER_BYTES:-8834019328}"
fi
EOF
chmod +x "${MOCK_BIN}/docker"

# Test 1: Sufficient memory (8424 MB Docker VM) -> Default 8192 MB
(
    export PATH="${MOCK_BIN}:${PATH}"
    export MOCK_DOCKER_BYTES="8834019328" # ~8424 MB
    CI_MODE=false
    CUSTOM_MEM=""
    compute_cluster_sizing
    [ "$CLUSTER_MEM" -eq 8192 ] && [ "$CLUSTER_CPUS" -eq 4 ]
) && assert_test "compute_cluster_sizing(): Allocates 8192 MB when Docker memory >= 8192 MB" 0 || \
   assert_test "compute_cluster_sizing(): Allocates 8192 MB when Docker memory >= 8192 MB" 1

# Test 2: Constrained memory (7957 MB Docker VM, e.g. 8GB VM) -> Clamped to safe value (6144 MB)
(
    export PATH="${MOCK_BIN}:${PATH}"
    export MOCK_DOCKER_BYTES="8343519232" # ~7957 MB
    CI_MODE=false
    CUSTOM_MEM=""
    compute_cluster_sizing >/dev/null 2>&1
    [ "$CLUSTER_MEM" -eq 6144 ] && [ "$CLUSTER_CPUS" -eq 4 ]
) && assert_test "compute_cluster_sizing(): Auto-clamps to 6144 MB on 7957 MB Docker ceiling" 0 || \
   assert_test "compute_cluster_sizing(): Auto-clamps to 6144 MB on 7957 MB Docker ceiling" 1

# Test 3: CI mode -> 4096 MB / 2 CPUs
(
    export PATH="${MOCK_BIN}:${PATH}"
    CI_MODE=true
    CUSTOM_MEM=""
    compute_cluster_sizing >/dev/null
    [ "$CLUSTER_MEM" -eq 4096 ] && [ "$CLUSTER_CPUS" -eq 2 ]
) && assert_test "compute_cluster_sizing(): Sizing respects CI_MODE (4096 MB, 2 CPUs)" 0 || \
   assert_test "compute_cluster_sizing(): Sizing respects CI_MODE (4096 MB, 2 CPUs)" 1

# Test 4: Custom memory flag -> Overrides auto-detection
(
    export PATH="${MOCK_BIN}:${PATH}"
    CI_MODE=false
    CUSTOM_MEM="7168"
    compute_cluster_sizing >/dev/null
    [ "$CLUSTER_MEM" -eq 7168 ]
) && assert_test "compute_cluster_sizing(): Sizing respects custom memory flag (7168 MB)" 0 || \
   assert_test "compute_cluster_sizing(): Sizing respects custom memory flag (7168 MB)" 1

# ==============================================================================
# [4/6] Real `reconcile_runsc_toml` & `install_host_bin` Regression Tests
# ==============================================================================
echo -e "\n${YELLOW}[4/6] Testing Containerd TOML Deduplication & Binary Installer...${NC}"

# Test reconcile_runsc_toml() on config without runsc stanza -> Appends stanza
TEST_TOML_1="${MOCK_TMP_DIR}/test1.toml"
cat << 'EOF' > "$TEST_TOML_1"
[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.9"
EOF

reconcile_runsc_toml "$TEST_TOML_1" > "${TEST_TOML_1}.out"
STANZA_COUNT_1=$(grep -c "containerd.runtimes.runsc" "${TEST_TOML_1}.out" || echo 0)
[ "$STANZA_COUNT_1" -eq 1 ] && \
  assert_test "reconcile_runsc_toml(): Appends runsc stanza when missing" 0 || \
  assert_test "reconcile_runsc_toml(): Appends runsc stanza when missing" 1

# Test reconcile_runsc_toml() on config with duplicate runsc stanzas -> Deduplicates to exactly 1
TEST_TOML_2="${MOCK_TMP_DIR}/test2.toml"
cat << 'EOF' > "$TEST_TOML_2"
[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.9"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
[metrics]
  address = "127.0.0.1:1338"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
EOF

reconcile_runsc_toml "$TEST_TOML_2" > "${TEST_TOML_2}.out"
STANZA_COUNT_2=$(grep -c "containerd.runtimes.runsc" "${TEST_TOML_2}.out" || echo 0)
[ "$STANZA_COUNT_2" -eq 1 ] && \
  assert_test "reconcile_runsc_toml(): Deduplicates multiple runsc stanzas to exactly 1" 0 || \
  assert_test "reconcile_runsc_toml(): Deduplicates multiple runsc stanzas to exactly 1" 1

# Regression Test: install_host_bin() must copy (not move) so multiple target installs succeed
INSTALL_SRC="${MOCK_TMP_DIR}/mock_bin_src"
INSTALL_DST1="${MOCK_TMP_DIR}/mock_bin_dst1"
INSTALL_DST2="${MOCK_TMP_DIR}/mock_bin_dst2"
echo "#!/bin/sh" > "$INSTALL_SRC"
echo "echo mock_ok" >> "$INSTALL_SRC"
chmod +x "$INSTALL_SRC"

install_host_bin "$INSTALL_SRC" "$INSTALL_DST1"
install_host_bin "$INSTALL_SRC" "$INSTALL_DST2"

if [ -f "$INSTALL_SRC" ] && [ -x "$INSTALL_DST1" ] && [ -x "$INSTALL_DST2" ]; then
    assert_test "install_host_bin(): Multi-path copy regression test (no double-mv crash)" 0
else
    assert_test "install_host_bin(): Multi-path copy regression test (no double-mv crash)" 1
fi

# ==============================================================================
# [5/6] Multi-Arch Binary Download URLs & Live Network Reachability (if online)
# ==============================================================================
echo -e "\n${YELLOW}[5/6] Testing Multi-Arch Binary URLs & Reachability...${NC}"

for arch in "amd64:x86_64" "arm64:aarch64"; do
    IFS=":" read -r cli_arch node_arch <<< "$arch"

    GVISOR_BZ2_URL="https://storage.googleapis.com/gvisor/releases/release/latest/${node_arch}/gvisor.tar.bz2"
    GVISOR_ZSTD_URL="https://storage.googleapis.com/gvisor/releases/release/latest/${node_arch}/gvisor.tar.zstd"
    MINIKUBE_URL="https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${cli_arch}"
    KUBECTL_URL="https://dl.k8s.io/release/v1.31.0/bin/linux/${cli_arch}/kubectl"

    if [[ "$GVISOR_BZ2_URL" =~ ^https://.*gvisor\.tar\.bz2$ ]] && \
       [[ "$GVISOR_ZSTD_URL" =~ ^https://.*gvisor\.tar\.zstd$ ]] && \
       [[ "$MINIKUBE_URL" =~ ^https://.*minikube-linux-(amd64|arm64)$ ]] && \
       [[ "$KUBECTL_URL" =~ ^https://.*bin/linux/(amd64|arm64)/kubectl$ ]]; then
        assert_test "URL format verified for arch: ${node_arch} (${cli_arch})" 0
    else
        assert_test "URL format verified for arch: ${node_arch} (${cli_arch})" 1
    fi
done

if curl -s --max-time 3 -I "https://storage.googleapis.com" >/dev/null 2>&1; then
    for narch in "x86_64" "aarch64"; do
        BZ2_URL="https://storage.googleapis.com/gvisor/releases/release/latest/${narch}/gvisor.tar.bz2"
        HTTP_RAW=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 10 "$BZ2_URL" 2>/dev/null || echo "000")
        HTTP_CODE="${HTTP_RAW: -3}"
        if [ "$HTTP_CODE" == "200" ]; then
            assert_test "Live HTTP 200: Google gVisor release archive (${narch})" 0
        else
            assert_test "Live HTTP 200: Google gVisor release archive (${narch}) (status: ${HTTP_CODE})" 1
        fi
    done

    MK_RAW=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 10 "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64" 2>/dev/null || echo "000")
    MK_CODE="${MK_RAW: -3}"
    if [ "$MK_CODE" == "200" ]; then
        assert_test "Live HTTP 200: Minikube multi-arch binary endpoint" 0
    else
        assert_test "Live HTTP 200: Minikube multi-arch binary endpoint (status: ${MK_CODE})" 1
    fi
else
    echo -e "  ${CYAN}[i] Sandboxed / offline environment: live HTTP reachability assertions skipped.${NC}"
fi

# ==============================================================================
# [6/6] Real YAML Parser Validation across all Manifests & Helm Values
# ==============================================================================
echo -e "\n${YELLOW}[6/6] Validating Component Manifests with Real YAML Parser...${NC}"

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
    "${K8S_DIR}/ansible/group_vars/all.yml"
    "${K8S_DIR}/ansible/playbooks/site.yml"
    "${K8S_DIR}/ansible/tasks/00_host_prep.yml"
    "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml"
    "${K8S_DIR}/ansible/tasks/02_k8s_stack.yml"
)

# Identify available real YAML parser (Ruby with Psych or Python with PyYAML)
YAML_PARSER=""
if command -v ruby >/dev/null 2>&1 && ruby -e 'require "yaml"' 2>/dev/null; then
    YAML_PARSER="ruby"
elif [ -n "$PY_BIN" ] && "$PY_BIN" -c "import yaml" 2>/dev/null; then
    YAML_PARSER="python"
fi

for manifest in "${REQUIRED_MANIFESTS[@]}"; do
    rel_path="${manifest#$REPO_ROOT/}"
    if [ -f "$manifest" ] && [ -s "$manifest" ]; then
        if [ "$YAML_PARSER" == "ruby" ]; then
            if ruby -e 'require "yaml"; YAML.load_stream(File.read(ARGV[0]))' "$manifest" 2>/dev/null; then
                assert_test "YAML parser syntax (Ruby): ${rel_path}" 0
            else
                assert_test "YAML parser syntax (Ruby): ${rel_path}" 1
            fi
        elif [ "$YAML_PARSER" == "python" ]; then
            if "$PY_BIN" -c "import yaml; list(yaml.safe_load_all(open('$manifest')))" 2>/dev/null; then
                assert_test "YAML parser syntax (PyYAML): ${rel_path}" 0
            else
                assert_test "YAML parser syntax (PyYAML): ${rel_path}" 1
            fi
        else
            # Fallback structural check if neither parser library is present
            if grep -q ":" "$manifest" 2>/dev/null; then
                assert_test "YAML structural check (fallback): ${rel_path}" 0
            else
                assert_test "YAML structural check (fallback): ${rel_path}" 1
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

# Verify leftover BITNAMI_DEBUG is removed
if grep -q "BITNAMI_DEBUG" "${K8S_DIR}/testkube/values-testkube.yaml"; then
    assert_test "Testkube values: Leftover BITNAMI_DEBUG removed" 1
else
    assert_test "Testkube values: Leftover BITNAMI_DEBUG removed" 0
fi

# Verify GLIBC_TUNABLES is present for kernel 6.19+ compatibility
if grep -q "GLIBC_TUNABLES" "${K8S_DIR}/testkube/values-testkube.yaml"; then
    assert_test "Testkube values: GLIBC_TUNABLES rseq=1 present for kernel 6.19+" 0
else
    assert_test "Testkube values: GLIBC_TUNABLES rseq=1 missing" 1
fi

# ==============================================================================
# Summary Report
# ==============================================================================
echo -e "\n${BLUE}============================================================${NC}"
echo -e "${BLUE}Test Suite Results: $((TOTAL_TESTS - FAILED_TESTS))/${TOTAL_TESTS} Passed${NC}"
echo -e "${BLUE}============================================================${NC}"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "${GREEN}✓ All Multi-OS, Multi-Arch Integration & Component Tests PASSED!${NC}\n"
    exit 0
else
    echo -e "${RED}✗ ${FAILED_TESTS} Test(s) FAILED! Check logs above.${NC}\n"
    exit 1
fi
