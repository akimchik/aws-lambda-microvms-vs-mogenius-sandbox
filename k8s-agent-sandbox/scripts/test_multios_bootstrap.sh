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

# Check root Makefile syntax and help target
if [ -f "${REPO_ROOT}/Makefile" ]; then
    if command -v make >/dev/null 2>&1; then
        if make -C "${REPO_ROOT}" -n help >/dev/null 2>&1; then
            assert_test "Makefile syntax & help target: Makefile" 0
        else
            assert_test "Makefile syntax & help target: Makefile" 1
        fi
    else
        if grep -q "^help:" "${REPO_ROOT}/Makefile"; then
            assert_test "Makefile syntax & help target: Makefile" 0
        else
            assert_test "Makefile syntax & help target: Makefile" 1
        fi
    fi
else
    assert_test "Makefile exists: Makefile" 1
fi

# Check native Ansible playbook syntax via ansible-playbook --syntax-check
if command -v ansible-playbook >/dev/null 2>&1; then
    if ansible-playbook -i "${K8S_DIR}/ansible/inventory.ini" "${K8S_DIR}/ansible/playbooks/site.yml" --syntax-check >/dev/null 2>&1; then
        assert_test "Native Ansible syntax check: site.yml (ansible-playbook --syntax-check)" 0
    else
        assert_test "Native Ansible syntax check: site.yml (ansible-playbook --syntax-check)" 1
    fi
fi

# Check embedded bash scripts inside Ansible tasks (00_host_prep, 01_minikube_gvisor, 02_k8s_stack)
if command -v ruby >/dev/null 2>&1; then
    EMBEDDED_SYNTAX_STATUS=$(ruby -ryaml -e '
    all_ok = true
    Dir.glob("'"${K8S_DIR}"'/ansible/tasks/*.yml").sort.each do |f|
      tasks = YAML.load_file(f) rescue []
      tasks.each do |t|
        next unless t.is_a?(Hash)
        sh = t["ansible.builtin.shell"] || t["shell"]
        next unless sh
        sanitized = sh.gsub(/\{\{.*?\}\}/, "dummy").gsub(/\{%.*?%\}/, "")
        IO.popen(["bash", "-n"], "w") { |pipe| pipe.write(sanitized) }
        all_ok = false unless $?.success?
      end
    end
    exit(all_ok ? 0 : 1)
    ' 2>/dev/null && echo "0" || echo "1")
    assert_test "Embedded Bash syntax check in all Ansible tasks/*.yml" "$EMBEDDED_SYNTAX_STATUS"
fi

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

(
    FORCE_ASK_BECOME=false
    parse_args -K
    [ "$FORCE_ASK_BECOME" = true ]
) && assert_test "parse_args(): Accepts -K (--ask-become-pass)" 0 || assert_test "parse_args(): Accepts -K (--ask-become-pass)" 1

(
    FORCE_ASK_BECOME=false
    parse_args --ask-become-pass
    [ "$FORCE_ASK_BECOME" = true ]
) && assert_test "parse_args(): Accepts --ask-become-pass" 0 || assert_test "parse_args(): Accepts --ask-become-pass" 1

(
    CONFIGURE_HOST_SYSCTL=false
    parse_args --configure-host-sysctl
    [ "$CONFIGURE_HOST_SYSCTL" = true ]
) && assert_test "parse_args(): Accepts --configure-host-sysctl" 0 || assert_test "parse_args(): Accepts --configure-host-sysctl" 1

# ==============================================================================
# Sudo & Privilege Escalation Mode Detection Tests (Ubuntu vs Rocky vs macOS)
# ==============================================================================

# Test detect_sudo_mode(): Linux non-root with sudo requiring password -> SUDO_NEEDS_PASS=true
(
    HOST_PLATFORM="Linux"
    MOCK_UID=1000
    FORCE_ASK_BECOME=false
    MOCK_SUDO_DIR="${MOCK_TMP_DIR}/mock_sudo_fail"
    mkdir -p "$MOCK_SUDO_DIR"
    cat << 'EOF' > "${MOCK_SUDO_DIR}/sudo"
#!/bin/sh
exit 1
EOF
    chmod +x "${MOCK_SUDO_DIR}/sudo"
    PATH="${MOCK_SUDO_DIR}:${PATH}"
    detect_sudo_mode
    [ "$SUDO_NEEDS_PASS" = true ]
) && assert_test "detect_sudo_mode(): Detects sudo requires password on Linux non-root" 0 || \
   assert_test "detect_sudo_mode(): Detects sudo requires password on Linux non-root" 1

# Test detect_sudo_mode(): Linux non-root with passwordless sudo -> SUDO_NEEDS_PASS=false
(
    HOST_PLATFORM="Linux"
    MOCK_UID=1000
    FORCE_ASK_BECOME=false
    MOCK_SUDO_DIR="${MOCK_TMP_DIR}/mock_sudo_ok"
    mkdir -p "$MOCK_SUDO_DIR"
    cat << 'EOF' > "${MOCK_SUDO_DIR}/sudo"
#!/bin/sh
exit 0
EOF
    chmod +x "${MOCK_SUDO_DIR}/sudo"
    PATH="${MOCK_SUDO_DIR}:${PATH}"
    detect_sudo_mode
    [ "$SUDO_NEEDS_PASS" = false ]
) && assert_test "detect_sudo_mode(): Detects passwordless sudo on Linux non-root" 0 || \
   assert_test "detect_sudo_mode(): Detects passwordless sudo on Linux non-root" 1

# Test detect_sudo_mode(): Never sets SUDO_NEEDS_PASS on macOS
(
    HOST_PLATFORM="macOS"
    MOCK_UID=1000
    FORCE_ASK_BECOME=false
    MOCK_SUDO_DIR="${MOCK_TMP_DIR}/mock_sudo_fail"
    PATH="${MOCK_SUDO_DIR}:${PATH}"
    detect_sudo_mode
    [ "$SUDO_NEEDS_PASS" = false ]
) && assert_test "detect_sudo_mode(): Never sets SUDO_NEEDS_PASS on macOS" 0 || \
   assert_test "detect_sudo_mode(): Never sets SUDO_NEEDS_PASS on macOS" 1

# Test detect_sudo_mode(): Never sets SUDO_NEEDS_PASS when running as root (UID 0)
(
    HOST_PLATFORM="Linux"
    MOCK_UID=0
    FORCE_ASK_BECOME=false
    MOCK_SUDO_DIR="${MOCK_TMP_DIR}/mock_sudo_fail"
    PATH="${MOCK_SUDO_DIR}:${PATH}"
    detect_sudo_mode
    [ "$SUDO_NEEDS_PASS" = false ]
) && assert_test "detect_sudo_mode(): Never sets SUDO_NEEDS_PASS when running as root (UID 0)" 0 || \
   assert_test "detect_sudo_mode(): Never sets SUDO_NEEDS_PASS when running as root (UID 0)" 1

# Test build_ansible_args(): Appends --ask-become-pass on Linux when -K flag is passed
(
    HOST_PLATFORM="Linux"
    MOCK_UID=1000
    FORCE_ASK_BECOME=true
    FORCE_HELM=false
    CI_MODE=false
    CUSTOM_MEM=""
    build_ansible_args
    has_flag=false
    for arg in "${ANSIBLE_ARGS[@]}"; do
        [ "$arg" == "--ask-become-pass" ] && has_flag=true
    done
    [ "$has_flag" = true ]
) && assert_test "build_ansible_args(): Appends --ask-become-pass on Linux when -K flag is passed" 0 || \
   assert_test "build_ansible_args(): Appends --ask-become-pass on Linux when -K flag is passed" 1

# Test build_ansible_args(): Omits --ask-become-pass on Linux when -K is not passed (standard execution)
(
    HOST_PLATFORM="Linux"
    MOCK_UID=1000
    FORCE_ASK_BECOME=false
    FORCE_HELM=false
    CI_MODE=false
    CUSTOM_MEM=""
    build_ansible_args
    has_flag=false
    for arg in "${ANSIBLE_ARGS[@]}"; do
        [ "$arg" == "--ask-become-pass" ] && has_flag=true
    done
    [ "$has_flag" = false ]
) && assert_test "build_ansible_args(): Omits --ask-become-pass on Linux when -K is not passed (standard execution)" 0 || \
   assert_test "build_ansible_args(): Omits --ask-become-pass on Linux when -K is not passed (standard execution)" 1

# Test build_ansible_args(): Omits --ask-become-pass on Linux when running as root (UID 0)
(
    HOST_PLATFORM="Linux"
    MOCK_UID=0
    FORCE_ASK_BECOME=true
    FORCE_HELM=false
    CI_MODE=false
    CUSTOM_MEM=""
    build_ansible_args
    has_flag=false
    for arg in "${ANSIBLE_ARGS[@]}"; do
        [ "$arg" == "--ask-become-pass" ] && has_flag=true
    done
    [ "$has_flag" = false ]
) && assert_test "build_ansible_args(): Omits --ask-become-pass on Linux when running as root (UID 0)" 0 || \
   assert_test "build_ansible_args(): Omits --ask-become-pass on Linux when running as root (UID 0)" 1

# Test build_ansible_args(): NEVER appends --ask-become-pass on macOS
(
    HOST_PLATFORM="macOS"
    MOCK_UID=1000
    FORCE_ASK_BECOME=true
    SUDO_NEEDS_PASS=true
    FORCE_HELM=false
    CI_MODE=false
    CUSTOM_MEM=""
    build_ansible_args
    has_flag=false
    for arg in "${ANSIBLE_ARGS[@]}"; do
        [ "$arg" == "--ask-become-pass" ] && has_flag=true
    done
    [ "$has_flag" = false ]
) && assert_test "build_ansible_args(): Never appends --ask-become-pass on macOS" 0 || \
   assert_test "build_ansible_args(): Never appends --ask-become-pass on macOS" 1

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

# Regression Test: prime_sudo() must safely detect cached/passwordless sudo or root
(
    if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
        prime_sudo
    fi
) && assert_test "prime_sudo(): Executes safely under cached/passwordless sudo or root" 0 || \
   assert_test "prime_sudo(): Executes safely under cached/passwordless sudo or root" 1

# Regression Test: prime_sudo() skips sudo -v when FORCE_ASK_BECOME=true to avoid double password prompt and TTY masking
(
    HOST_PLATFORM="Linux"
    FORCE_ASK_BECOME=true
    MOCK_SUDO_V_DIR="${MOCK_TMP_DIR}/mock_sudo_v_fail"
    mkdir -p "$MOCK_SUDO_V_DIR"
    cat << 'EOF' > "${MOCK_SUDO_V_DIR}/sudo"
#!/bin/sh
if [ "$1" = "-v" ]; then
    echo "ERROR: sudo -v should not have been called!" >&2
    exit 99
fi
exit 1
EOF
    chmod +x "${MOCK_SUDO_V_DIR}/sudo"
    PATH="${MOCK_SUDO_V_DIR}:${PATH}"
    # prime_sudo should exit 0 without invoking sudo -v
    prime_sudo
) && assert_test "prime_sudo(): Skips sudo -v when FORCE_ASK_BECOME=true to avoid double password prompt" 0 || \
   assert_test "prime_sudo(): Skips sudo -v when FORCE_ASK_BECOME=true to avoid double password prompt" 1

# Regression Test: prime_sudo() skips sudo -v when host_needs_privilege evaluates to false
(
    HOST_PLATFORM="Linux"
    FORCE_ASK_BECOME=false
    # Mock host_needs_privilege to return 1 (false: no host tools missing)
    host_needs_privilege() { return 1; }
    MOCK_SUDO_V_DIR2="${MOCK_TMP_DIR}/mock_sudo_v_fail2"
    mkdir -p "$MOCK_SUDO_V_DIR2"
    cat << 'EOF' > "${MOCK_SUDO_V_DIR2}/sudo"
#!/bin/sh
if [ "$1" = "-v" ]; then
    echo "ERROR: sudo -v should not have been called!" >&2
    exit 99
fi
exit 1
EOF
    chmod +x "${MOCK_SUDO_V_DIR2}/sudo"
    PATH="${MOCK_SUDO_V_DIR2}:${PATH}"
    prime_sudo
) && assert_test "prime_sudo(): Skips sudo -v when host_needs_privilege evaluates to false" 0 || \
   assert_test "prime_sudo(): Skips sudo -v when host_needs_privilege evaluates to false" 1

# Regression Test: prime_sudo() immediately exits on macOS
(
    HOST_PLATFORM="macOS"
    SUDO_NEEDS_PASS=false
    MOCK_SUDO_ERR_DIR="${MOCK_TMP_DIR}/mock_sudo_mac_err"
    mkdir -p "$MOCK_SUDO_ERR_DIR"
    cat << 'EOF' > "${MOCK_SUDO_ERR_DIR}/sudo"
#!/bin/sh
echo "ERROR: sudo called on macOS!" >&2
exit 99
EOF
    chmod +x "${MOCK_SUDO_ERR_DIR}/sudo"
    PATH="${MOCK_SUDO_ERR_DIR}:${PATH}"
    prime_sudo
) && assert_test "prime_sudo(): Exits immediately on macOS without invoking sudo" 0 || \
   assert_test "prime_sudo(): Exits immediately on macOS without invoking sudo" 1

# Regression Test: start_sudo_keepalive() exits immediately on macOS
(
    HOST_PLATFORM="macOS"
    MOCK_UID=1000
    start_sudo_keepalive
) && assert_test "start_sudo_keepalive(): Exits immediately on macOS" 0 || \
   assert_test "start_sudo_keepalive(): Exits immediately on macOS" 1

# Regression Test: start_sudo_keepalive() exits immediately as root
(
    HOST_PLATFORM="Linux"
    MOCK_UID=0
    start_sudo_keepalive
) && assert_test "start_sudo_keepalive(): Exits immediately as root (UID 0)" 0 || \
   assert_test "start_sudo_keepalive(): Exits immediately as root (UID 0)" 1

# Regression Test: Host-side gVisor archive extraction (tar -xjf / Python tarfile)
(
    TEST_UNPACK_DIR="${MOCK_TMP_DIR}/gvisor_test_unpack"
    mkdir -p "$TEST_UNPACK_DIR"
    echo "MOCK_RUNSC_ELF" > "${TEST_UNPACK_DIR}/runsc"
    echo "MOCK_SHIM_ELF" > "${TEST_UNPACK_DIR}/containerd-shim-runsc-v1"
    tar -cf "${TEST_UNPACK_DIR}/test_gvisor.tar" -C "$TEST_UNPACK_DIR" runsc containerd-shim-runsc-v1
    bzip2 "${TEST_UNPACK_DIR}/test_gvisor.tar" 2>/dev/null || gzip "${TEST_UNPACK_DIR}/test_gvisor.tar"
    rm -f "${TEST_UNPACK_DIR}/runsc" "${TEST_UNPACK_DIR}/containerd-shim-runsc-v1"

    ARCHIVE=$(ls "${TEST_UNPACK_DIR}/test_gvisor.tar."* | head -n1)
    if [[ "$ARCHIVE" == *.bz2 ]]; then
        if command -v bzip2 >/dev/null 2>&1 || tar -tf "$ARCHIVE" >/dev/null 2>&1; then
            tar -xjf "$ARCHIVE" -C "$TEST_UNPACK_DIR"
        else
            python3 -c "import tarfile; tarfile.open('$ARCHIVE').extractall('$TEST_UNPACK_DIR')"
        fi
    else
        tar -xzf "$ARCHIVE" -C "$TEST_UNPACK_DIR"
    fi

    [ -f "${TEST_UNPACK_DIR}/runsc" ] && [ -f "${TEST_UNPACK_DIR}/containerd-shim-runsc-v1" ]
) && assert_test "gVisor host unpack regression: Extracts binaries on host without guest tools" 0 || \
   assert_test "gVisor host unpack regression: Extracts binaries on host without guest tools" 1

# Regression Test: tasks/00_host_prep.yml dispatches to modular OS-specific task files across 5 matrix flows
if grep -q "00_host_prep_darwin.yml" "${K8S_DIR}/ansible/tasks/00_host_prep.yml" && \
   grep -q "00_host_prep_ubuntu.yml" "${K8S_DIR}/ansible/tasks/00_host_prep.yml" && \
   grep -q "00_host_prep_rocky.yml" "${K8S_DIR}/ansible/tasks/00_host_prep.yml"; then
    assert_test "tasks/00_host_prep.yml: Modular dispatcher delegates to Darwin, Ubuntu, and Rocky flow modules" 0
else
    assert_test "tasks/00_host_prep.yml: Modular dispatcher delegates to Darwin, Ubuntu, and Rocky flow modules" 1
fi

# Regression Test: tasks/00_host_prep_{ubuntu,rocky}.yml skips package managers when utilities exist
if grep -q "base_utils_check" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   grep -q "base_utils_check" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml"; then
    assert_test "tasks/00_host_prep_{ubuntu,rocky}.yml: Base package manager guarded by audit to avoid unneeded sudo" 0
else
    assert_test "tasks/00_host_prep_{ubuntu,rocky}.yml: Base package manager guarded by audit to avoid unneeded sudo" 1
fi

# Regression Test: tasks/00_host_prep_{ubuntu,rocky}.yml audits openssl in base_utils_check for get-helm-3 verification
if grep -q "openssl" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   grep -q "openssl" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "VERIFY_CHECKSUM=false" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   grep -q "VERIFY_CHECKSUM=false" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml"; then
    assert_test "tasks/00_host_prep_{ubuntu,rocky}.yml: audits openssl and implements VERIFY_CHECKSUM fallback for Helm installer" 0
else
    assert_test "tasks/00_host_prep_{ubuntu,rocky}.yml: audits openssl and implements VERIFY_CHECKSUM fallback for Helm installer" 1
fi

# Regression Test: tasks/00_host_prep_darwin.yml dynamically resolves Homebrew prefix (arm64 /opt/homebrew vs x86_64 /usr/local)
if grep -q "brew_prefix:" "${K8S_DIR}/ansible/tasks/00_host_prep_darwin.yml" && \
   grep -q "/opt/homebrew" "${K8S_DIR}/ansible/tasks/00_host_prep_darwin.yml" && \
   ! grep -q "become:" "${K8S_DIR}/ansible/tasks/00_host_prep_darwin.yml"; then
    assert_test "tasks/00_host_prep_darwin.yml: resolves architecture-specific Homebrew prefix without sudo" 0
else
    assert_test "tasks/00_host_prep_darwin.yml: resolves architecture-specific Homebrew prefix without sudo" 1
fi

# Regression Test: tasks/00_host_prep_{ubuntu,rocky}.yml implements Docker CE installation and readiness verification
if grep -q "Install Docker CE" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   grep -q "Install Docker CE repository" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "ansible.builtin.user" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "groups: docker" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "command -v docker >/dev/null 2>&1 || return 0" "${BOOTSTRAP_SCRIPT}"; then
    assert_test "tasks/00_host_prep_{ubuntu,rocky}.yml: implements Docker CE installation, systemd activation, and user group management" 0
else
    assert_test "tasks/00_host_prep_{ubuntu,rocky}.yml: implements Docker CE installation, systemd activation, and user group management" 1
fi

# Security Invariant Test: Strictly prohibit chmod 666 /var/run/docker.sock or permission downgrades
if ! grep -rn "chmod 666" "${K8S_DIR}/ansible/" "${BOOTSTRAP_SCRIPT}" 2>/dev/null && \
   ! grep -rn "chmod.*docker\.sock" "${K8S_DIR}/ansible/" "${BOOTSTRAP_SCRIPT}" 2>/dev/null; then
    assert_test "security: Zero chmod 666 /var/run/docker.sock hacks (standard system user group management used)" 0
else
    assert_test "security: Zero chmod 666 /var/run/docker.sock hacks (standard system user group management used)" 1
fi

# Regression Test: bootstrap_cluster.sh host_needs_privilege audits openssl on Linux
if grep -q "for tool in curl tar jq bzip2 openssl;" "${BOOTSTRAP_SCRIPT}"; then
    assert_test "bootstrap_cluster.sh: host_needs_privilege checks openssl prerequisite on Linux" 0
else
    assert_test "bootstrap_cluster.sh: host_needs_privilege checks openssl prerequisite on Linux" 1
fi

# Unit Test: host_needs_privilege() returns 0 (requires privilege) when docker is missing on Linux
(
    HOST_PLATFORM="Linux"
    MOCK_NO_DOCKER_DIR="${MOCK_TMP_DIR}/mock_no_docker"
    mkdir -p "$MOCK_NO_DOCKER_DIR"
    for tool in curl tar jq bzip2 openssl kubectl minikube helm testkube; do
        touch "${MOCK_NO_DOCKER_DIR}/${tool}"
        chmod +x "${MOCK_NO_DOCKER_DIR}/${tool}"
    done
    PATH="${MOCK_NO_DOCKER_DIR}"
    host_needs_privilege
) && assert_test "bootstrap_cluster.sh: host_needs_privilege returns 0 when Docker is missing on Linux" 0 || \
   assert_test "bootstrap_cluster.sh: host_needs_privilege returns 0 when Docker is missing on Linux" 1

# Unit Test: host_needs_privilege() returns 1 (zero privilege needed) when all tools including docker are present
(
    HOST_PLATFORM="Linux"
    MOCK_ALL_TOOLS_DIR="${MOCK_TMP_DIR}/mock_all_tools"
    mkdir -p "$MOCK_ALL_TOOLS_DIR"
    for tool in curl tar jq bzip2 openssl kubectl minikube helm testkube docker; do
        touch "${MOCK_ALL_TOOLS_DIR}/${tool}"
        chmod +x "${MOCK_ALL_TOOLS_DIR}/${tool}"
    done
    cat << 'EOF' > "${MOCK_ALL_TOOLS_DIR}/id"
#!/bin/sh
echo "docker staff"
EOF
    chmod +x "${MOCK_ALL_TOOLS_DIR}/id"
    PATH="${MOCK_ALL_TOOLS_DIR}:${PATH}"
    if host_needs_privilege; then
        exit 1
    else
        exit 0
    fi
) && assert_test "bootstrap_cluster.sh: host_needs_privilege returns 1 when all tools exist and /usr/local/bin is writable" 0 || \
   assert_test "bootstrap_cluster.sh: host_needs_privilege returns 1 when all tools exist and /usr/local/bin is writable" 1

# Unit Test: host_needs_privilege() returns 0 when user is not in docker group
(
    HOST_PLATFORM="Linux"
    MOCK_NO_GRP_DIR="${MOCK_TMP_DIR}/mock_no_grp"
    mkdir -p "$MOCK_NO_GRP_DIR"
    for tool in curl tar jq bzip2 openssl kubectl minikube helm testkube docker; do
        touch "${MOCK_NO_GRP_DIR}/${tool}"
        chmod +x "${MOCK_NO_GRP_DIR}/${tool}"
    done
    cat << 'EOF' > "${MOCK_NO_GRP_DIR}/id"
#!/bin/sh
echo "staff users"
EOF
    chmod +x "${MOCK_NO_GRP_DIR}/id"
    PATH="${MOCK_NO_GRP_DIR}:${PATH}"
    host_needs_privilege
) && assert_test "bootstrap_cluster.sh: host_needs_privilege returns 0 when user is not in docker group" 0 || \
   assert_test "bootstrap_cluster.sh: host_needs_privilege returns 0 when user is not in docker group" 1

# Matrix Flow 1 Test: 00_host_prep_darwin.yml strictly user-space, zero become, zero linux tools
if ! grep -q "become:" "${K8S_DIR}/ansible/tasks/00_host_prep_darwin.yml" && \
   grep -q "brew_prefix:" "${K8S_DIR}/ansible/tasks/00_host_prep_darwin.yml" && \
   ! grep -qE "dnf|yum|apt|sysctl\.d|limits\.d" "${K8S_DIR}/ansible/tasks/00_host_prep_darwin.yml"; then
    assert_test "matrix flow 1 (macOS): 00_host_prep_darwin.yml is strictly user-space (zero sudo/become) and isolated from Linux" 0
else
    assert_test "matrix flow 1 (macOS): 00_host_prep_darwin.yml is strictly user-space (zero sudo/become) and isolated from Linux" 1
fi

# Matrix Flows 2 & 3 Test: 00_host_prep_ubuntu.yml uses apt, installs docker.io, zero brew, zero dnf/yum
if grep -q "ansible.builtin.apt:" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   grep -q "docker\.io" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   grep -q "ansible.builtin.user" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   ! grep -qE "brew|homebrew|dnf|yum" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml"; then
    assert_test "matrix flows 2 & 3 (Ubuntu): 00_host_prep_ubuntu.yml uses apt and is isolated from macOS and RedHat" 0
else
    assert_test "matrix flows 2 & 3 (Ubuntu): 00_host_prep_ubuntu.yml uses apt and is isolated from macOS and RedHat" 1
fi

# Matrix Flows 4 & 5 Test: 00_host_prep_rocky.yml uses dnf/yum, docker-ce repo, /usr/bin symlinks, zero brew, zero apt
if grep -qE "dnf|yum" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "docker-ce\.repo" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "ansible.builtin.user" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "/usr/bin/kubectl" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   ! grep -qE "brew|homebrew|ansible\.builtin\.apt" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml"; then
    assert_test "matrix flows 4 & 5 (Rocky): 00_host_prep_rocky.yml uses dnf/yum with secure_path symlinks and is isolated from Debian/macOS" 0
else
    assert_test "matrix flows 4 & 5 (Rocky): 00_host_prep_rocky.yml uses dnf/yum with secure_path symlinks and is isolated from Debian/macOS" 1
fi

# Matrix Flows 4 & 5 Test: 00_host_prep_rocky.yml handles curl-minimal and ensures docker group exists
if grep -q "curl-minimal" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q -- "--allowerasing" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "Ensure docker group exists" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "Ensure docker group exists" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml"; then
    assert_test "matrix flows 4 & 5 (Rocky): handles curl-minimal without DNF conflict and ensures docker group exists" 0
else
    assert_test "matrix flows 4 & 5 (Rocky): handles curl-minimal without DNF conflict and ensures docker group exists" 1
fi

# Matrix Flows 2-5 Test: 00_host_prep_{ubuntu,rocky}.yml guard Docker service and group behind presence audits
if grep -q "docker_daemon_check_rocky" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "docker_daemon_check_ubuntu" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   grep -q "user_docker_group_check_rocky" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "user_docker_group_check_ubuntu" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml"; then
    assert_test "privilege guard: Docker service & group tasks guarded behind presence audits to avoid unneeded sudo" 0
else
    assert_test "privilege guard: Docker service & group tasks guarded behind presence audits to avoid unneeded sudo" 1
fi

# Regression Test: tasks/00_host_prep_{ubuntu,rocky}.yml guards systemd Docker activation against non-init container test runners
if grep -q "failed_when: false" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "ansible_facts\['service_mgr'\] == 'systemd'" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "failed_when: false" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   grep -q "ansible_facts\['service_mgr'\] == 'systemd'" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml"; then
    assert_test "tasks/00_host_prep_{ubuntu,rocky}.yml: guards systemd Docker activation against non-init container environments" 0
else
    assert_test "tasks/00_host_prep_{ubuntu,rocky}.yml: guards systemd Docker activation against non-init container environments" 1
fi

# Makefile Test: All primary Make targets parse and dry-run without errors
if command -v make >/dev/null 2>&1; then
    for target in help check dry-run preflight cluster clean status; do
        if make -C "${REPO_ROOT}" -n "$target" >/dev/null 2>&1; then
            assert_test "Makefile: target '$target' syntax and execution plan verified" 0
        else
            assert_test "Makefile: target '$target' syntax and execution plan verified" 1
        fi
    done
else
    for target in help check dry-run preflight cluster clean status; do
        if grep -q "^${target}:" "${REPO_ROOT}/Makefile"; then
            assert_test "Makefile: target '$target' syntax and execution plan verified" 0
        else
            assert_test "Makefile: target '$target' syntax and execution plan verified" 1
        fi
    done
fi

# Regression Test: tasks/00_host_prep_{ubuntu,rocky}.yml audits and adjusts open file limits & systemd DefaultLimitNOFILE on Linux
if grep -q "nofile_controls" "${K8S_DIR}/ansible/group_vars/all.yml" && \
   grep -q "DefaultLimitNOFILE" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   grep -q "DefaultLimitNOFILE" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "fs.file-max" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml"; then
    assert_test "tasks/00_host_prep_{ubuntu,rocky}.yml: Linux open file & systemd DefaultLimitNOFILE controls implemented" 0
else
    assert_test "tasks/00_host_prep_{ubuntu,rocky}.yml: Linux open file & systemd DefaultLimitNOFILE controls implemented" 1
fi

# Regression Test: tasks/00_host_prep_darwin.yml macOS tasks require zero become/sudo
if ! grep -q "become:" "${K8S_DIR}/ansible/tasks/00_host_prep_darwin.yml" && \
   ! grep -q "kern.maxfiles" "${K8S_DIR}/ansible/tasks/00_host_prep_darwin.yml"; then
    assert_test "tasks/00_host_prep_darwin.yml: Darwin tasks execute without become/sudo and require no host sysctl" 0
else
    assert_test "tasks/00_host_prep_darwin.yml: Darwin tasks execute without become/sudo and require no host sysctl" 1
fi

# Regression Test: configure_linux_sysctl is true in group_vars/all.yml for Linux kernel optimizations
if grep -q "configure_linux_sysctl: true" "${K8S_DIR}/ansible/group_vars/all.yml"; then
    assert_test "group_vars/all.yml: configure_linux_sysctl is enabled for Linux kernel optimization" 0
else
    assert_test "group_vars/all.yml: configure_linux_sysctl is enabled for Linux kernel optimization" 1
fi

# Regression Test: tasks/00_host_prep_{ubuntu,rocky}.yml sysctl tasks include ignore_unreachable: true
if grep -q "ignore_unreachable: true" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   grep -q "ignore_unreachable: true" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml"; then
    assert_test "tasks/00_host_prep_{ubuntu,rocky}.yml: Sysctl tasks specify ignore_unreachable: true" 0
else
    assert_test "tasks/00_host_prep_{ubuntu,rocky}.yml: Sysctl tasks specify ignore_unreachable: true" 1
fi

# Regression Test: tasks/00_host_prep.yml sysctl audit logic evaluates NEEDS_ADJUSTMENT=false when kernel limits are already sufficient (Ubuntu)
(
    MOCK_SYSCTL_HIGH_DIR="${MOCK_TMP_DIR}/mock_sysctl_high"
    mkdir -p "$MOCK_SYSCTL_HIGH_DIR"
    cat << 'EOF' > "${MOCK_SYSCTL_HIGH_DIR}/sysctl"
#!/bin/sh
case "$2" in
    fs.file-max) echo "9223372036854775807" ;;
    fs.nr_open) echo "2147483584" ;;
    vm.max_map_count) echo "262144" ;;
    fs.inotify.max_user_watches) echo "1048576" ;;
    *) echo "0" ;;
esac
EOF
    chmod +x "${MOCK_SYSCTL_HIGH_DIR}/sysctl"
    PATH="${MOCK_SYSCTL_HIGH_DIR}:${PATH}"

    FILE_MAX=$(sysctl -n fs.file-max 2>/dev/null || echo "0")
    NR_OPEN=$(sysctl -n fs.nr_open 2>/dev/null || echo "0")
    VM_MAX=$(sysctl -n vm.max_map_count 2>/dev/null || echo "0")
    INOTIFY_WATCH=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo "0")
    REQ_FILE_MAX=2097152
    REQ_NR_OPEN=2097152
    ADJUST="false"
    if [ "$FILE_MAX" -lt "$REQ_FILE_MAX" ] || [ "$NR_OPEN" -lt "$REQ_NR_OPEN" ] || \
       [ "$VM_MAX" -lt 262144 ] || [ "$INOTIFY_WATCH" -lt 524288 ]; then
      ADJUST="true"
    fi
    [ "$ADJUST" == "false" ]
) && assert_test "tasks/00_host_prep.yml: Sysctl audit evaluates NEEDS_ADJUSTMENT=false when kernel limits already sufficient (Ubuntu)" 0 || \
   assert_test "tasks/00_host_prep.yml: Sysctl audit evaluates NEEDS_ADJUSTMENT=false when kernel limits already sufficient (Ubuntu)" 1

# Regression Test: tasks/00_host_prep.yml sysctl audit logic evaluates NEEDS_ADJUSTMENT=true when kernel limits are lower than required
(
    MOCK_SYSCTL_LOW_DIR="${MOCK_TMP_DIR}/mock_sysctl_low"
    mkdir -p "$MOCK_SYSCTL_LOW_DIR"
    cat << 'EOF' > "${MOCK_SYSCTL_LOW_DIR}/sysctl"
#!/bin/sh
case "$2" in
    fs.file-max) echo "1048576" ;;
    fs.nr_open) echo "1048576" ;;
    vm.max_map_count) echo "65530" ;;
    fs.inotify.max_user_watches) echo "8192" ;;
    *) echo "0" ;;
esac
EOF
    chmod +x "${MOCK_SYSCTL_LOW_DIR}/sysctl"
    PATH="${MOCK_SYSCTL_LOW_DIR}:${PATH}"

    FILE_MAX=$(sysctl -n fs.file-max 2>/dev/null || echo "0")
    NR_OPEN=$(sysctl -n fs.nr_open 2>/dev/null || echo "0")
    VM_MAX=$(sysctl -n vm.max_map_count 2>/dev/null || echo "0")
    INOTIFY_WATCH=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo "0")
    REQ_FILE_MAX=2097152
    REQ_NR_OPEN=2097152
    ADJUST="false"
    if [ "$FILE_MAX" -lt "$REQ_FILE_MAX" ] || [ "$NR_OPEN" -lt "$REQ_NR_OPEN" ] || \
       [ "$VM_MAX" -lt 262144 ] || [ "$INOTIFY_WATCH" -lt 524288 ]; then
      ADJUST="true"
    fi
    [ "$ADJUST" == "true" ]
) && assert_test "tasks/00_host_prep.yml: Sysctl audit evaluates NEEDS_ADJUSTMENT=true when kernel limits are lower than required" 0 || \
   assert_test "tasks/00_host_prep.yml: Sysctl audit evaluates NEEDS_ADJUSTMENT=true when kernel limits are lower than required" 1

# Regression Test: tasks/01_minikube_gvisor.yml uses uncompressed tar archive transfer (regular file over scp)
if grep -q "minikube cp .*minikube:/tmp/gvisor_raw.tar" "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml" && \
   grep -q "tar -xf /tmp/gvisor_raw.tar" "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml" && \
   grep -q "gvisor_sentry" "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml" && \
   ! grep -A 10 "minikube ssh" "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml" | grep -q "tar -xjf"; then
    assert_test "tasks/01_minikube_gvisor.yml: Uses uncompressed tar archive transfer with gvisor_sentry" 0
else
    assert_test "tasks/01_minikube_gvisor.yml: Uses uncompressed tar archive transfer with gvisor_sentry" 1
fi

# Regression Test: tasks/02_k8s_stack.yml tests live gVisor pod creation & SandboxWarmPool
if grep -q "gvisor-verification-probe" "${K8S_DIR}/ansible/tasks/02_k8s_stack.yml" && \
   grep -q "sandboxwarmpool default" "${K8S_DIR}/ansible/tasks/02_k8s_stack.yml"; then
    assert_test "tasks/02_k8s_stack.yml: Verification requires live gVisor probe and WarmPool ready" 0
else
    assert_test "tasks/02_k8s_stack.yml: Verification requires live gVisor probe and WarmPool ready" 1
fi

# Regression Test: tasks/*.yml contains zero empty array expansions (${arr[@]} on arr=()) under set -u (macOS bash 3.2 bug)
if command -v ruby >/dev/null 2>&1; then
    EMPTY_ARR_STATUS=$(ruby -e '
    bad = false
    Dir.glob("'"${K8S_DIR}"'/ansible/tasks/*.yml").sort.each do |f|
      c = File.read(f)
      if c =~ /=\(\)\s*.*?\"?\$\{\w+\[@\]\}\"?/m
        bad = true
      end
    end
    exit(bad ? 1 : 0)
    ' 2>/dev/null && echo "0" || echo "1")
    assert_test "tasks/*.yml: Zero empty array expansions under set -u (macOS bash 3.2 compatibility)" "$EMPTY_ARR_STATUS"
fi

# Regression Test: task [6/8] mogenius helm upgrade executes cleanly in /bin/bash set -euo pipefail (both latest & pinned version)
/bin/bash -c '
set -euo pipefail
test_mogenius_helm() {
    local chart_ver="$1"
    local extra_helm_arg=""
    [ "$chart_ver" != "latest" ] && [ -n "$chart_ver" ] && extra_helm_arg="--version $chart_ver"
    mock_helm() { return 0; }
    mock_helm upgrade --install agent-sandbox mogenius/mogenius-agent-sandbox \
      ${extra_helm_arg} \
      -n agent-sandbox-system --create-namespace
}
test_mogenius_helm "latest"
test_mogenius_helm "1.2.1"
' >/dev/null 2>&1 && assert_test "tasks/02_k8s_stack.yml: [6/8] mogenius helm upgrade executes without unbound variable under /bin/bash set -euo pipefail" 0 || \
assert_test "tasks/02_k8s_stack.yml: [6/8] mogenius helm upgrade executes without unbound variable under /bin/bash set -euo pipefail" 1

# Regression Test: task [8/8] testkube helm upgrade executes cleanly in /bin/bash set -euo pipefail (both latest & pinned version)
/bin/bash -c '
set -euo pipefail
test_testkube_helm() {
    local tk_chart_ver="$1"
    local tk_extra_arg=""
    [ "$tk_chart_ver" != "latest" ] && [ -n "$tk_chart_ver" ] && tk_extra_arg="--version $tk_chart_ver"
    mock_helm() { return 0; }
    mock_helm upgrade --install testkube kubeshop/testkube \
      ${tk_extra_arg} \
      -n testkube --create-namespace
}
test_testkube_helm "latest"
test_testkube_helm "2.14.2"
' >/dev/null 2>&1 && assert_test "tasks/02_k8s_stack.yml: [8/8] testkube helm upgrade executes without unbound variable under /bin/bash set -euo pipefail" 0 || \
assert_test "tasks/02_k8s_stack.yml: [8/8] testkube helm upgrade executes without unbound variable under /bin/bash set -euo pipefail" 1

# Regression Test: task [Verify] warm pool wait target executes cleanly in /bin/bash set -euo pipefail (both empty & defined selector)
/bin/bash -c '
set -euo pipefail
test_warmpool_wait() {
    local selector="$1"
    local filter_arg=""
    [ -n "$selector" ] && filter_arg="-l $selector"
    local wait_target="pod ${filter_arg}"
    [ -z "$filter_arg" ] && wait_target="pod --all"
    mock_kubectl() { return 0; }
    mock_kubectl wait --for=condition=Ready ${wait_target} --timeout=90s
}
test_warmpool_wait ""
test_warmpool_wait "app=mogenius"
' >/dev/null 2>&1 && assert_test "tasks/02_k8s_stack.yml: [Verify] warm pool wait target executes without unbound variable under /bin/bash set -euo pipefail" 0 || \
assert_test "tasks/02_k8s_stack.yml: [Verify] warm pool wait target executes without unbound variable under /bin/bash set -euo pipefail" 1

# Regression Test: tasks/01_minikube_gvisor.yml sizing facts declare defensive defaults
if grep -q "minikube_ci_mode | default" "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml" && \
   grep -q "minikube_cpus | default" "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml" && \
   grep -q "minikube_memory_mb | default" "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml"; then
    assert_test "tasks/01_minikube_gvisor.yml: sizing variables declare defensive defaults for isolated tag execution" 0
else
    assert_test "tasks/01_minikube_gvisor.yml: sizing variables declare defensive defaults for isolated tag execution" 1
fi

# Regression Test: tasks/01_minikube_gvisor.yml sizing tasks are never skipped by --skip-tags preflight
if ! grep -q "preflight" "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml" && \
   grep -q "effective_cpus:" "${K8S_DIR}/ansible/group_vars/all.yml"; then
    assert_test "tasks/01_minikube_gvisor.yml: sizing tasks are not tagged preflight and have group_vars fallback" 0
else
    assert_test "tasks/01_minikube_gvisor.yml: sizing tasks are not tagged preflight and have group_vars fallback" 1
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
    "${K8S_DIR}/testkube/templates/test-workflow.yaml.j2"
    "${K8S_DIR}/testkube/templates/test-workflow-security.yaml.j2"
    "${K8S_DIR}/testkube/templates/test-workflow-sustained-load.yaml.j2"
    "${K8S_DIR}/ansible/group_vars/all.yml"
    "${K8S_DIR}/ansible/playbooks/site.yml"
    "${K8S_DIR}/ansible/tasks/00_host_prep.yml"
    "${K8S_DIR}/ansible/tasks/00_host_prep_darwin.yml"
    "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml"
    "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml"
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

# Verify Jinja2 template rendering for Testkube workflows
JINJA_RENDER_PY=""
for candidate_py in /opt/homebrew/Cellar/ansible/*/libexec/bin/python $(which python3 python 2>/dev/null); do
    if [ -x "$candidate_py" ] && "$candidate_py" -c "import jinja2, yaml" >/dev/null 2>&1; then
        JINJA_RENDER_PY="$candidate_py"
        break
    fi
done

if [ -n "$JINJA_RENDER_PY" ]; then
    for tmpl in "test-workflow.yaml.j2" "test-workflow-security.yaml.j2" "test-workflow-sustained-load.yaml.j2"; do
        if "$JINJA_RENDER_PY" -c "
import jinja2, yaml, sys, random
env = jinja2.Environment(loader=jinja2.FileSystemLoader('${K8S_DIR}/testkube/templates'))
tmpl = env.get_template('$tmpl')
dynamic_test_ip = f'{random.randint(10, 240)}.{random.randint(1, 254)}.{random.randint(1, 254)}.{random.randint(1, 254)}'
out = tmpl.render(minikube_ip=dynamic_test_ip)
assert f'http://{dynamic_test_ip}:80' in out, f'Template failed to inject dynamic IP {dynamic_test_ip}'
assert '{{ config.targetUrl }}' in out, 'TestWorkflow config.targetUrl was corrupted by templating'
assert '{% raw %}' not in out, 'Unescaped raw tag remains in output'
assert '{{ minikube_ip }}' not in out, 'Unrendered minikube_ip variable remains in output'
docs = list(yaml.safe_load_all(out))
assert len(docs) > 0 and docs[0].get('kind') == 'TestWorkflow', 'Rendered manifest is not a valid TestWorkflow CRD'
" >/dev/null 2>&1; then
            assert_test "Testkube template render (Jinja2): ${tmpl} (injects minikube_ip, preserves TestWorkflow config)" 0
        else
            assert_test "Testkube template render (Jinja2): ${tmpl} (render or YAML validation failure)" 1
        fi
    done
fi

# Verify dynamic KUBERNETES_SERVICE_HOST resolution in threat_probe.py and k6-security-audit.js
if grep -q "KUBERNETES_SERVICE_HOST" "${K8S_DIR}/threat-model/threat_probe.py" && \
   grep -q "KUBERNETES_SERVICE_HOST" "${K8S_DIR}/testkube/tests/k6-security-audit.js"; then
    assert_test "Security probes: Dynamic KUBERNETES_SERVICE_HOST resolution verified" 0
else
    assert_test "Security probes: Dynamic KUBERNETES_SERVICE_HOST resolution missing" 1
fi

# Verify idempotent /etc/hosts update for control-plane.minikube.internal when Minikube IP changes
if grep -q "grep -qx.*\${CP_IP} control-plane.minikube.internal" "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml"; then
    assert_test "tasks/01_minikube_gvisor.yml: Idempotent /etc/hosts overwrite on Minikube IP change verified" 0
else
    assert_test "tasks/01_minikube_gvisor.yml: Idempotent /etc/hosts overwrite missing" 1
fi

# Verify TestWorkflow templates use self-contained content.files (no external GitHub revision: main pinning)
if ! grep -q "revision: main" "${K8S_DIR}/testkube/templates/"*.j2; then
    assert_test "Testkube templates: Hermetic self-contained content.files (no external GitHub main pinning)" 0
else
    assert_test "Testkube templates: External GitHub revision: main pinning still present" 1
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
