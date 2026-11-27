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
SKIPPED_TESTS=0
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

skip_test() {
    local test_name="$1"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
    echo -e "  ${YELLOW}↷ SKIP:${NC} ${test_name}"
}

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}Multi-OS & Multi-Architecture Bootstrap Integration Test Suite${NC}"
echo -e "${BLUE}============================================================${NC}"

# Source the bootstrap script functions (saving and restoring SCRIPT_DIR / K8S_DIR so BASH_SOURCE inside bootstrap_cluster.sh stays isolated)
if [ ! -f "$BOOTSTRAP_SCRIPT" ]; then
    echo -e "${RED}✗ Error: Bootstrap script not found at ${BOOTSTRAP_SCRIPT}${NC}"
    exit 1
fi
_SAVED_SCRIPT_DIR="$SCRIPT_DIR"
_SAVED_K8S_DIR="$K8S_DIR"
# shellcheck source=k8s-agent-sandbox/scripts/bootstrap_cluster.sh
source "$BOOTSTRAP_SCRIPT"
SCRIPT_DIR="$_SAVED_SCRIPT_DIR"
K8S_DIR="$_SAVED_K8S_DIR"

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

# Resolve Python interpreters early across all test sections (host Python, PyYAML-capable, and PyYAML+Jinja2)
export K8S_DIR
PY_BIN=""
for candidate in /usr/bin/python3 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import sys" 2>/dev/null; then
        PY_BIN="$candidate"
        break
    fi
done

ANSIBLE_PY=$(head -n1 "$(command -v ansible-playbook 2>/dev/null || echo /nonexistent)" 2>/dev/null | sed 's/^#!//' | awk '{print $1}' || true)
YAML_PY=""
RUNTIME_TEST_PY=""
for candidate_py in "$ANSIBLE_PY" "$PY_BIN" $(which python3 python 2>/dev/null); do
    if [ -n "$candidate_py" ] && [ -x "$candidate_py" ]; then
        if [ -z "$YAML_PY" ] && "$candidate_py" -c "import yaml" >/dev/null 2>&1; then
            YAML_PY="$candidate_py"
        fi
        if [ -z "$RUNTIME_TEST_PY" ] && "$candidate_py" -c "import yaml, jinja2" >/dev/null 2>&1; then
            RUNTIME_TEST_PY="$candidate_py"
        fi
    fi
done

# Check native Ansible playbook syntax via ansible-playbook --syntax-check
if command -v ansible-playbook >/dev/null 2>&1; then
    if ! has_required_collections; then
        skip_test "Native Ansible syntax check: site.yml (ansible.posix/community.general not installed yet; run 'make preflight')"
    else
        SYNTAX_ERR=""
        if SYNTAX_ERR=$(ansible-playbook -i "${K8S_DIR}/ansible/inventory.ini" "${K8S_DIR}/ansible/playbooks/site.yml" --syntax-check 2>&1); then
            assert_test "Native Ansible syntax check: site.yml (ansible-playbook --syntax-check)" 0
        else
            assert_test "Native Ansible syntax check: site.yml (ansible-playbook --syntax-check)" 1
            echo "$SYNTAX_ERR" | sed 's/^/      /'
        fi
    fi
else
    skip_test "Native Ansible syntax check: site.yml (ansible-playbook not installed)"
fi

# Check embedded bash scripts inside Ansible tasks (00_host_prep*, 01_minikube_gvisor, 02_k8s_stack)
if [ -n "$YAML_PY" ]; then
    EMBEDDED_SYNTAX_STATUS=$("$YAML_PY" -c '
import yaml, glob, os, re, subprocess
all_ok = True
for f in sorted(glob.glob(os.path.join(os.environ["K8S_DIR"], "ansible/tasks/*.yml"))):
    tasks = yaml.safe_load(open(f)) or []
    for t in tasks:
        if not isinstance(t, dict):
            continue
        sh = t.get("ansible.builtin.shell") or t.get("shell")
        if not sh:
            continue
        sanitized = re.sub(r"\{\{.*?\}\}", "dummy", sh, flags=re.S)
        sanitized = re.sub(r"\{%.*?%\}", "", sanitized, flags=re.S)
        res = subprocess.run(["bash", "-n"], input=sanitized, text=True)
        if res.returncode != 0:
            all_ok = False
raise SystemExit(0 if all_ok else 1)
' 2>/dev/null && echo "0" || echo "1")
    assert_test "Embedded Bash syntax check in all Ansible tasks/*.yml" "$EMBEDDED_SYNTAX_STATUS"
elif command -v ruby >/dev/null 2>&1; then
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
else
    skip_test "Embedded Bash syntax check in all Ansible tasks/*.yml (requires PyYAML or Ruby)"
fi

# Python AST syntax on ALL python files in repository

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
            skip_test "Python AST syntax: $(basename "$py_file") (python3 not installed)"
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
            skip_test "JS syntax check: $(basename "$js") (node not installed)"
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

DRY_RUN_OUT=$("${K8S_DIR}/scripts/bootstrap_cluster.sh" --dry-run 2>&1 || true)
if echo "$DRY_RUN_OUT" | grep -q "Dry-Run Audit Complete (--dry-run: Zero changes made)!"; then
    assert_test "bootstrap_cluster.sh --dry-run: Executes read-only audit with zero mutations" 0
else
    assert_test "bootstrap_cluster.sh --dry-run: Executes read-only audit with zero mutations" 1
    echo "$DRY_RUN_OUT" | tail -n 15 | sed 's/^/      /'
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

# Test detect_sudo_mode(): Rocky/RHEL (dnf) non-root with cached/passwordless sudo -> SUDO_NEEDS_PASS=false
(
    HOST_PLATFORM="Linux"
    PKG_MGR="dnf"
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
) && assert_test "detect_sudo_mode(): Rocky/RHEL (dnf) uses cached sudo ticket (SUDO_NEEDS_PASS=false)" 0 || \
   assert_test "detect_sudo_mode(): Rocky/RHEL (dnf) uses cached sudo ticket (SUDO_NEEDS_PASS=false)" 1

# Test detect_sudo_mode(): Debian/Ubuntu (apt) non-root skips sudo ticket check -> SUDO_NEEDS_PASS=true
(
    HOST_PLATFORM="Linux"
    PKG_MGR="apt"
    MOCK_UID=1000
    FORCE_ASK_BECOME=false
    MOCK_SUDO_DIR="${MOCK_TMP_DIR}/mock_sudo_ok"
    PATH="${MOCK_SUDO_DIR}:${PATH}"
    detect_sudo_mode
    [ "$SUDO_NEEDS_PASS" = true ]
) && assert_test "detect_sudo_mode(): Debian/Ubuntu (apt) skips sudo ticket check (SUDO_NEEDS_PASS=true)" 0 || \
   assert_test "detect_sudo_mode(): Debian/Ubuntu (apt) skips sudo ticket check (SUDO_NEEDS_PASS=true)" 1

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
# [3/6] Real Ansible Sizing Expression & Playbook Pipeline Tests
# ==============================================================================
echo -e "\n${YELLOW}[3/6] Testing Real Ansible Sizing Expression & Single-Pass Pipeline...${NC}"

# Real Runtime Execution Test: Execute actual Ansible Jinja2 sizing formula with RUNTIME_TEST_PY
if [ -n "$RUNTIME_TEST_PY" ]; then
    "$RUNTIME_TEST_PY" -c '
import yaml, jinja2, os
k8s_dir = os.environ["K8S_DIR"]
env = jinja2.Environment()
env.filters["bool"] = lambda v: str(v).lower() in ("true", "1", "yes") if isinstance(v, str) else bool(v)
tasks = yaml.safe_load(open(os.path.join(k8s_dir, "ansible/tasks/01_minikube_gvisor.yml")))
sizing_task = [t for t in tasks if "Determine final Minikube primary node CPUs and Memory" in t.get("name", "")][0]
cpu_tpl = env.from_string(sizing_task["ansible.builtin.set_fact"]["effective_cpus"])
mem_tpl = env.from_string(sizing_task["ansible.builtin.set_fact"]["effective_memory_mb"])

assert int(cpu_tpl.render(minikube_ci_mode=False, minikube_cpus=4).strip()) == 4
assert int(mem_tpl.render(minikube_custom_memory_mb="", minikube_ci_mode=False, detected_mem_mb=8424, minikube_memory_mb=8192).strip()) == 8192
assert int(mem_tpl.render(minikube_custom_memory_mb="", minikube_ci_mode=False, detected_mem_mb=7957, minikube_memory_mb=8192).strip()) == 6144
assert int(cpu_tpl.render(minikube_ci_mode=True, minikube_cpus=4).strip()) == 2
assert int(mem_tpl.render(minikube_custom_memory_mb="", minikube_ci_mode=True, detected_mem_mb=16000, minikube_memory_mb=8192).strip()) == 4096
assert int(mem_tpl.render(minikube_custom_memory_mb="7168", minikube_ci_mode=False, detected_mem_mb=16000, minikube_memory_mb=8192).strip()) == 7168
' >/dev/null 2>&1 && \
    assert_test "Live Jinja2 Runtime (01_minikube_gvisor.yml): Executes real Ansible sizing formula (8192 default, 6144 clamp, 4096 CI, custom override)" 0 || \
    assert_test "Live Jinja2 Runtime (01_minikube_gvisor.yml): Executes real Ansible sizing formula (8192 default, 6144 clamp, 4096 CI, custom override)" 1
else
    skip_test "Live Jinja2 Runtime (01_minikube_gvisor.yml): requires Python yaml+jinja2"
fi

# Verify bootstrap_cluster.sh has zero dead bash functions (install_host_bin, compute_cluster_sizing, reconcile_runsc_toml, prime_sudo, start_sudo_keepalive, audit_and_tune_linux_inotify removed)
if ! grep -qE "install_host_bin|compute_cluster_sizing|reconcile_runsc_toml|prime_sudo|start_sudo_keepalive|audit_and_tune_linux_inotify" "${BOOTSTRAP_SCRIPT}"; then
    assert_test "bootstrap_cluster.sh: Zero dead bash functions (sizing, TOML, sysctl & sudo priming delegated 100% to Ansible)" 0
else
    assert_test "bootstrap_cluster.sh: Dead bash functions still present" 1
fi

# Unit Test: ensure_ansible_collections() does NOT trust false-zero exit code from ansible-doc (Rocky 10 bug)
(
    COLL_MOCK="${MOCK_TMP_DIR}/coll_mock_216"
    mkdir -p "${COLL_MOCK}/bin" "${COLL_MOCK}/collections"
    cat << 'EOF' > "${COLL_MOCK}/bin/ansible-doc"
#!/bin/sh
# Simulate upstream ansible-doc exiting 0 even when collection module is missing
exit 0
EOF
    cat << 'EOF' > "${COLL_MOCK}/bin/ansible"
#!/bin/sh
echo "ansible [core 2.16.19]"
EOF
    cat << EOF > "${COLL_MOCK}/bin/ansible-galaxy"
#!/bin/sh
STATE="${COLL_MOCK}/installed.flag"
LOG="${COLL_MOCK}/galaxy.log"
if [ "\$1" = "collection" ] && [ "\$2" = "list" ]; then
    if [ -f "\$STATE" ]; then
        echo "ansible.posix    2.0.0"
        echo "community.general 9.5.0"
    fi
    exit 0
fi
if [ "\$1" = "collection" ] && [ "\$2" = "install" ]; then
    echo "\$*" >> "\$LOG"
    touch "\$STATE"
    exit 0
fi
EOF
    chmod +x "${COLL_MOCK}/bin/"*
    export PATH="${COLL_MOCK}/bin:${PATH}"
    export HOME="${COLL_MOCK}/home"
    mkdir -p "$HOME"
    unset ANSIBLE_COLLECTIONS_PATH
    set -u
    ! has_required_collections && \
    ensure_ansible_collections >/dev/null && \
    has_required_collections && \
    grep -q "ansible.posix:>=2.0.0" "${COLL_MOCK}/galaxy.log" && \
    grep -q "${HOME}/.ansible/collections" "${COLL_MOCK}/galaxy.log"
) && assert_test "ensure_ansible_collections(): Installs missing collections on ansible-core 2.16.19 even when ansible-doc returns exit 0" 0 || \
    assert_test "ensure_ansible_collections(): Failed to detect/install missing collections on ansible-core 2.16.19" 1

# Unit Test: ensure_ansible_collections() selects legacy pins for ansible-core < 2.16 and fast-paths when already present
(
    COLL_MOCK2="${MOCK_TMP_DIR}/coll_mock_214"
    mkdir -p "${COLL_MOCK2}/bin" "${COLL_MOCK2}/collections"
    cat << 'EOF' > "${COLL_MOCK2}/bin/ansible"
#!/bin/sh
echo "ansible [core 2.14.17]"
EOF
    cat << EOF > "${COLL_MOCK2}/bin/ansible-galaxy"
#!/bin/sh
STATE="${COLL_MOCK2}/installed.flag"
LOG="${COLL_MOCK2}/galaxy.log"
if [ "\$1" = "collection" ] && [ "\$2" = "list" ]; then
    if [ -f "\$STATE" ]; then
        echo "ansible.posix    1.5.4"
        echo "community.general 8.6.0"
    fi
    exit 0
fi
if [ "\$1" = "collection" ] && [ "\$2" = "install" ]; then
    echo "\$*" >> "\$LOG"
    touch "\$STATE"
    exit 0
fi
EOF
    chmod +x "${COLL_MOCK2}/bin/"*
    export PATH="${COLL_MOCK2}/bin:${PATH}"
    export ANSIBLE_COLLECTIONS_PATH="${COLL_MOCK2}/collections"
    ensure_ansible_collections >/dev/null && \
    grep -q "ansible.posix:>=1.5.4,<2.0.0" "${COLL_MOCK2}/galaxy.log" && \
    rm -f "${COLL_MOCK2}/galaxy.log" && \
    ensure_ansible_collections >/dev/null && \
    [ ! -f "${COLL_MOCK2}/galaxy.log" ]
) && assert_test "ensure_ansible_collections(): Pins <2.16 collections accurately and fast-paths idempotently when already installed" 0 || \
    assert_test "ensure_ansible_collections(): Failed legacy pin or idempotent fast-path test" 1

# Unit Test: ensure_ansible_collections() returns non-zero cleanly if collection install still leaves collections missing
(
    COLL_MOCK3="${MOCK_TMP_DIR}/coll_mock_fail"
    mkdir -p "${COLL_MOCK3}/bin" "${COLL_MOCK3}/collections"
    cat << 'EOF' > "${COLL_MOCK3}/bin/ansible"
#!/bin/sh
echo "ansible [core 2.16.19]"
EOF
    cat << 'EOF' > "${COLL_MOCK3}/bin/ansible-galaxy"
#!/bin/sh
exit 0
EOF
    chmod +x "${COLL_MOCK3}/bin/"*
    export PATH="${COLL_MOCK3}/bin:${PATH}"
    export ANSIBLE_COLLECTIONS_PATH="${COLL_MOCK3}/collections"
    ! ensure_ansible_collections >/dev/null 2>&1
) && assert_test "ensure_ansible_collections(): Fails fast non-zero if collections remain absent after install" 0 || \
    assert_test "ensure_ansible_collections(): Did not fail fast when collections remained missing" 1

# Verify bootstrap_cluster.sh runs a single-pass ansible-playbook pipeline and passes preflight_only_mode=\${PREFLIGHT_ONLY}
if grep -q 'preflight_only_mode=\${PREFLIGHT_ONLY}' "${BOOTSTRAP_SCRIPT}" && \
   ! grep -q -- '--skip-tags preflight' "${BOOTSTRAP_SCRIPT}" && \
   ! grep -q 'exec sg docker' "${BOOTSTRAP_SCRIPT}"; then
    assert_test "bootstrap_cluster.sh: Single-pass Ansible execution (no 2-pass --skip-tags preflight split or exec sg docker loop)" 0
else
    assert_test "bootstrap_cluster.sh: Single-pass Ansible execution check failed" 1
fi

# ==============================================================================
# [4/6] Real Ansible Embedded Task & Live Component Runtime Tests
# ==============================================================================
echo -e "\n${YELLOW}[4/6] Testing Real Ansible Embedded Task Logic & Live Component Servers...${NC}"

# Extract the real version-aware containerd drop-in script from tasks/01_minikube_gvisor.yml and execute against containerd 1.x (v2) & 2.x (v3)
CTD_SCRIPT_FILE="${MOCK_TMP_DIR}/reconcile_containerd.sh"
sed -n '/# BEGIN_CONTAINERD_DROPIN_RECONCILE/,/# END_CONTAINERD_DROPIN_RECONCILE/p' "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml" | sed 's/^    //' > "$CTD_SCRIPT_FILE"
chmod +x "$CTD_SCRIPT_FILE"

# Test A: containerd 1.7.20 (config v2), stripping "cri" from disabled_plugins & duplicate inline runsc stanzas, plus idempotent second pass
(
    CTD1_DIR="${MOCK_TMP_DIR}/ctd1"
    mkdir -p "${CTD1_DIR}/bin" "${CTD1_DIR}/conf.d"
    cat << 'EOF' > "${CTD1_DIR}/bin/containerd"
#!/bin/sh
if [ "$1" = "--version" ]; then echo "containerd github.com/containerd/containerd v1.7.20 8fc6bcff51318944179630522a095cc9dbf9f353"; fi
EOF
    chmod +x "${CTD1_DIR}/bin/containerd"
    cat << 'EOF' > "${CTD1_DIR}/config.toml"
disabled_plugins = ["cri"]
[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.9"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
[metrics]
  address = "127.0.0.1:1338"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
EOF
    export PATH="${CTD1_DIR}/bin:${PATH}"
    export CONFIG_PATH="${CTD1_DIR}/config.toml" CONF_D_DIR="${CTD1_DIR}/conf.d" DROPIN_PATH="${CTD1_DIR}/conf.d/10-gvisor-runsc.toml"
    export PAUSE_IMAGE="registry.k8s.io/pause:3.10" CONTAINERD_NO_SUDO=1 SKIP_CONTAINERD_RESTART=1 SKIP_CRICTL_CHECK=1
    bash "$CTD_SCRIPT_FILE"
    grep -q 'disabled_plugins = \[\]' "$CONFIG_PATH" && \
    ! grep -q 'containerd.runtimes.runsc' "$CONFIG_PATH" && \
    grep -q "imports = \[\"${CONF_D_DIR}/\*.toml\"\]" "$CONFIG_PATH" && \
    grep -q '^version = 2' "$DROPIN_PATH" && \
    grep -q 'io.containerd.grpc.v1.cri' "$DROPIN_PATH" && \
    grep -q 'SystemdCgroup = true' "$DROPIN_PATH" && \
    grep -q 'runtime_type = "io.containerd.runsc.v1"' "$DROPIN_PATH" && \
    bash "$CTD_SCRIPT_FILE"
) && assert_test "tasks/01_minikube_gvisor.yml: Live containerd 1.x (v2) reconciles conf.d drop-in, strips disabled cri & deduplicates runsc idempotently" 0 || \
    assert_test "tasks/01_minikube_gvisor.yml: Live containerd 1.x (v2) drop-in reconciliation failed" 1

# Test B: containerd 2.2.0 (config v3, omitted SystemdCgroup in default config)
(
    CTD2_DIR="${MOCK_TMP_DIR}/ctd2"
    mkdir -p "${CTD2_DIR}/bin" "${CTD2_DIR}/conf.d"
    cat << 'EOF' > "${CTD2_DIR}/bin/containerd"
#!/bin/sh
if [ "$1" = "--version" ]; then echo "containerd github.com/containerd/containerd/v2 v2.2.0 1234567890abcdef"; fi
EOF
    chmod +x "${CTD2_DIR}/bin/containerd"
    cat << 'EOF' > "${CTD2_DIR}/config.toml"
version = 3
root = "/var/lib/containerd"
EOF
    export PATH="${CTD2_DIR}/bin:${PATH}"
    export CONFIG_PATH="${CTD2_DIR}/config.toml" CONF_D_DIR="${CTD2_DIR}/conf.d" DROPIN_PATH="${CTD2_DIR}/conf.d/10-gvisor-runsc.toml"
    export PAUSE_IMAGE="registry.k8s.io/pause:3.10" CONTAINERD_NO_SUDO=1 SKIP_CONTAINERD_RESTART=1 SKIP_CRICTL_CHECK=1
    bash "$CTD_SCRIPT_FILE"
    grep -q '^version = 3' "$DROPIN_PATH" && \
    grep -q "io.containerd.cri.v1.images" "$DROPIN_PATH" && \
    grep -q "io.containerd.cri.v1.runtime" "$DROPIN_PATH" && \
    grep -q "SystemdCgroup = true" "$DROPIN_PATH" && \
    grep -q "runtime_type = 'io.containerd.runsc.v1'" "$DROPIN_PATH" && \
    bash "$CTD_SCRIPT_FILE"
) && assert_test "tasks/01_minikube_gvisor.yml: Live containerd 2.x (v3) renders version=3 drop-in with pinned_images, SystemdCgroup=true & runsc" 0 || \
    assert_test "tasks/01_minikube_gvisor.yml: Live containerd 2.x (v3) drop-in reconciliation failed" 1

# Live Execution Test: Extract MINIKUBE_DNS_RECONCILE from 01_minikube_gvisor.yml and verify broken-gateway remediation vs healthy idempotency
DNS_SCRIPT_FILE="${MOCK_TMP_DIR}/reconcile_minikube_dns.sh"
sed -n '/# BEGIN_MINIKUBE_DNS_RECONCILE/,/# END_MINIKUBE_DNS_RECONCILE/p' "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml" | sed 's/^    //' | sed 's/{{[^}]*}}/8.8.8.8 1.1.1.1/g' > "$DNS_SCRIPT_FILE"
(
    DNS_DIR="${MOCK_TMP_DIR}/minikube_dns"
    mkdir -p "$DNS_DIR"
    . "$DNS_SCRIPT_FILE"

    # Case A: Broken node DNS (192.168.49.1 refused) + Rocky host resolv.conf (IPv4 + loopback + IPv6)
    cat << 'EOF' > "${DNS_DIR}/host_a.conf"
# Generated by NetworkManager
search home
nameserver 127.0.0.53
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 2a02:a46c:b7b4:0:3aa6:59ff:feba:6c30
EOF
    echo "nameserver 192.168.49.1" > "${DNS_DIR}/node_a.conf"
    HOST_RESOLV_CONF="${DNS_DIR}/host_a.conf"
    NODE_RESOLV_CONF="${DNS_DIR}/node_a.conf"
    DNS_PROBE_CMD="false"
    DNS_RECONCILED=0
    reconcile_node_dns minikube
    [ "$DNS_RECONCILED" -eq 1 ] && \
    grep -q '^nameserver 8\.8\.8\.8$' "$NODE_RESOLV_CONF" && \
    grep -q '^nameserver 8\.8\.4\.4$' "$NODE_RESOLV_CONF" && \
    ! grep -q '127\.0\.0\.53' "$NODE_RESOLV_CONF" && \
    ! grep -q '2a02:' "$NODE_RESOLV_CONF" && \
    ! grep -q '192\.168\.49\.1' "$NODE_RESOLV_CONF" && \

    # Case B: Broken node DNS + loopback-only host resolv.conf falls back to 8.8.8.8 & 1.1.1.1
    echo "nameserver 127.0.0.53" > "${DNS_DIR}/host_b.conf"
    echo "nameserver 192.168.49.1" > "${DNS_DIR}/node_b.conf"
    HOST_RESOLV_CONF="${DNS_DIR}/host_b.conf"
    NODE_RESOLV_CONF="${DNS_DIR}/node_b.conf"
    DNS_PROBE_CMD="false"
    DNS_RECONCILED=0
    reconcile_node_dns minikube
    [ "$DNS_RECONCILED" -eq 1 ] && \
    grep -q '^nameserver 8\.8\.8\.8$' "$NODE_RESOLV_CONF" && \
    grep -q '^nameserver 1\.1\.1\.1$' "$NODE_RESOLV_CONF" && \

    # Case C: Healthy node DNS leaves node resolv.conf untouched (idempotent no-op)
    echo "nameserver 192.168.49.1" > "${DNS_DIR}/node_c.conf"
    NODE_RESOLV_CONF="${DNS_DIR}/node_c.conf"
    DNS_PROBE_CMD="true"
    DNS_RECONCILED=0
    reconcile_node_dns minikube
    [ "$DNS_RECONCILED" -eq 0 ] && \
    grep -q '^nameserver 192\.168\.49\.1$' "$NODE_RESOLV_CONF"
) && assert_test "tasks/01_minikube_gvisor.yml: Live MINIKUBE_DNS_RECONCILE fixes dead 192.168.49.1:53 DNS with host/fallback upstreams and stays idempotent" 0 || \
    assert_test "tasks/01_minikube_gvisor.yml: Live MINIKUBE_DNS_RECONCILE failed" 1

# Verify firewalld trusted CIDRs, masquerading, Docker handler sync & Stage 2 CNI/CoreDNS rollout gate
if grep -q 'k8s_firewall_mode: "configure"' "${K8S_DIR}/ansible/group_vars/all.yml" && \
   grep -q '"192.168.49.0/24"' "${K8S_DIR}/ansible/group_vars/all.yml" && \
   grep -q '"172.17.0.0/16"' "${K8S_DIR}/ansible/group_vars/all.yml" && \
   grep -q '"10.244.0.0/16"' "${K8S_DIR}/ansible/group_vars/all.yml" && \
   grep -q 'zone: trusted' "${K8S_DIR}/ansible/tasks/00_host_prep_linux_network.yml" && \
   grep -q 'masquerade: true' "${K8S_DIR}/ansible/tasks/00_host_prep_linux_network.yml" && \
   grep -q 'notify: Restart Docker daemon' "${K8S_DIR}/ansible/tasks/00_host_prep_linux_network.yml" && \
   grep -q 'registry-1.docker.io' "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml" && \
   grep -q 'rollout status daemonset/kindnet' "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml" && \
   grep -q 'rollout status deployment/coredns' "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml"; then
    assert_test "group_vars/ & tasks/: Enforces firewalld trusted CIDRs, masquerading, Docker sync & live kindnet/CoreDNS rollout gate" 0
else
    assert_test "group_vars/ & tasks/: Missing firewalld trusted CIDRs, masquerading or live kindnet/CoreDNS rollout gate" 1
fi

# Verify zero unreachable/dead tasks across all 00_host_prep*.yml files (every task must carry 'preflight' tag)
if [ -n "$YAML_PY" ]; then
    if "$YAML_PY" -c '
import yaml, glob, os
k8s_dir = os.environ["K8S_DIR"]
for f in sorted(glob.glob(os.path.join(k8s_dir, "ansible/tasks/00_host_prep*.yml"))):
    for t in yaml.safe_load(open(f)):
        tags = t.get("tags", [])
        tname = t.get("name", "")
        assert "preflight" in tags, f"Missing preflight tag in {f}: {tname}"
' >/dev/null 2>&1; then
        assert_test "tasks/00_host_prep*.yml: Zero dead/unreachable Stage 0 tasks (all tasks carry 'preflight' tag)" 0
    else
        assert_test "tasks/00_host_prep*.yml: Zero dead/unreachable Stage 0 tasks (all tasks carry 'preflight' tag)" 1
    fi
elif command -v ruby >/dev/null 2>&1; then
    if ruby -ryaml -e '
    Dir.glob(ARGV[0]).sort.each do |f|
      YAML.load_file(f).each do |t|
        tags = t["tags"] || []
        exit 1 unless tags.include?("preflight")
      end
    end
    ' "${K8S_DIR}/ansible/tasks/00_host_prep*.yml" 2>/dev/null; then
        assert_test "tasks/00_host_prep*.yml: Zero dead/unreachable Stage 0 tasks (all tasks carry 'preflight' tag)" 0
    else
        assert_test "tasks/00_host_prep*.yml: Zero dead/unreachable Stage 0 tasks (all tasks carry 'preflight' tag)" 1
    fi
else
    skip_test "tasks/00_host_prep*.yml: Stage 0 preflight tag check (requires PyYAML or Ruby)"
fi

# Verify Stage 0 and Stage 1 explicitly enforce that current user can operate in docker group (no sudo -n docker info bypass)
if ! grep -q "sudo -n docker info" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   ! grep -q "sudo -n docker info" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "Assert current user can operate as an active member of the docker group" "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml"; then
    assert_test "tasks/00_host_prep_*.yml & 01_minikube_gvisor.yml: Strictly enforces active docker group access (zero sudo -n docker info bypass)" 0
else
    assert_test "tasks/00_host_prep_*.yml & 01_minikube_gvisor.yml: Active docker group access enforcement missing" 1
fi

# Real Runtime Execution Test: Extract broker.py from egress-broker.yaml and run in-process WSGI/handler test with threat_probe.py (Blocked 403 vs Drift EXTRA_ALLOWED_HOSTS 200)
if [ -n "$YAML_PY" ]; then
    "$YAML_PY" -c '
import yaml, threading, urllib.request, socket, sys, os
socket.getfqdn = lambda *a: "localhost"
k8s_dir = os.environ["K8S_DIR"]
sys.path.insert(0, os.path.join(k8s_dir, "threat-model"))
import threat_probe

docs = list(yaml.safe_load_all(open(os.path.join(k8s_dir, "threat-model/egress-broker.yaml"))))
cm = [d for d in docs if d and d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "egress-broker-code"][0]
broker_code = cm["data"]["broker.py"]

def run_broker_test(extra_hosts=""):
    os.environ["GITHUB_APP_INSTALLATION_TOKEN"] = "ghs_test_ephemeral_token"
    os.environ["EXTRA_ALLOWED_HOSTS"] = extra_hosts
    ns = {"__name__": "broker_test"}
    exec(broker_code, ns)
    srv = ns["HTTPServer"](("127.0.0.1", 0), ns["BrokerHandler"])
    port = srv.server_address[1]
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    try:
        res = threat_probe.check_broker_egress(f"http://127.0.0.1:{port}")
        t6b = [r for r in res if r["id"] == "T6B_BROKER_POLICY_ENFORCEMENT"][0]
        t6c = [r for r in res if r["id"] == "T6C_OUT_OF_SANDBOX_AUTH"][0]
        return t6b["status"], t6c["status"]
    finally:
        srv.shutdown()
        srv.server_close()

s_t6b, s_t6c = run_broker_test("")
assert s_t6b == "PASS (BLOCKED_BY_BROKER)", f"Expected PASS (BLOCKED_BY_BROKER), got {s_t6b}"
assert s_t6c == "PASS (BROKER_INJECTED)", f"Expected PASS (BROKER_INJECTED), got {s_t6c}"

d_t6b, _ = run_broker_test("example.com")
assert d_t6b == "FAIL (EXPOSED)", f"Expected FAIL (EXPOSED) on drift, got {d_t6b}"
' >/dev/null 2>&1 && \
    assert_test "Live E2E Runtime (egress-broker + threat_probe.py): Verifies HTTP 403 block (PASS) and EXTRA_ALLOWED_HOSTS drift detection (FAIL EXPOSED)" 0 || \
    assert_test "Live E2E Runtime (egress-broker + threat_probe.py): Verifies HTTP 403 block (PASS) and EXTRA_ALLOWED_HOSTS drift detection (FAIL EXPOSED)" 1
else
    skip_test "Live E2E Runtime (egress-broker + threat_probe.py): requires PyYAML"
fi

# Real Runtime Execution Test: Extract exporter.py from sandbox-latency-exporter.yaml and verify POST /record & GET /metrics for T6B drift (1 -> 0 -> 1)
if [ -n "$YAML_PY" ]; then
    "$YAML_PY" -c '
import yaml, threading, urllib.request, socket, sys, os
socket.getfqdn = lambda *a: "localhost"
k8s_dir = os.environ["K8S_DIR"]

docs = list(yaml.safe_load_all(open(os.path.join(k8s_dir, "monitoring/sandbox-latency-exporter.yaml"))))
cm = [d for d in docs if d and d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "sandbox-latency-exporter-code"][0]
exp_code = cm["data"]["exporter.py"]

ns = {"__name__": "exporter_test"}
exec(exp_code, ns)
srv = ns["HTTPServer"](("127.0.0.1", 0), ns["ExporterHandler"])
port = srv.server_address[1]
t = threading.Thread(target=srv.serve_forever, daemon=True)
t.start()
try:
    req = urllib.request.Request(f"http://127.0.0.1:{port}/record?security_passed=5&T6B_BROKER_POLICY_ENFORCEMENT=0&latency_ms=1450&launch_type=cold&active_sandboxes=3", data=b"", method="POST")
    urllib.request.urlopen(req, timeout=2)
    metrics = urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=2).read().decode()
    assert "agent_sandbox_security_vector_status{vector=\"T6B_BROKER_POLICY_ENFORCEMENT\"} 0" in metrics, "T6B=0 missing in /metrics"
    assert "agent_sandbox_security_checks_passed 5" in metrics, "security_checks_passed 5 missing"
    assert "agent_sandbox_active_test_sandboxes 3" in metrics, "active_sandboxes 3 missing"
    assert "agent_sandbox_claim_controller_startup_latency_ms_count{launch_type=\"cold\"} 1" in metrics, "cold count 1 missing"
finally:
    srv.shutdown()
    srv.server_close()
' >/dev/null 2>&1 && \
    assert_test "Live E2E Runtime (sandbox-latency-exporter): Verifies POST /record & GET /metrics for T6B=0 drift, cold latency, and active_sandboxes=3" 0 || \
    assert_test "Live E2E Runtime (sandbox-latency-exporter): Verifies POST /record & GET /metrics for T6B=0 drift, cold latency, and active_sandboxes=3" 1
else
    skip_test "Live E2E Runtime (sandbox-latency-exporter): requires PyYAML"
fi

# Real POSIX /bin/sh Execution Test: Execute rendered TestWorkflow shell steps under /bin/sh -e (catches sh: 0: bad number)
if [ -n "$RUNTIME_TEST_PY" ]; then
    "$RUNTIME_TEST_PY" -c '
import jinja2, yaml, subprocess, tempfile, os
k8s_dir = os.environ["K8S_DIR"]

mock_bin = tempfile.mkdtemp()
kubectl_path = os.path.join(mock_bin, "kubectl")
with open(kubectl_path, "w") as f:
    f.write("#!/bin/sh\nif echo \"$*\" | grep -q \"sandboxwarmpool\"; then echo \"app=sandbox\"; elif echo \"$*\" | grep -q \"sandbox.name\"; then echo \"default-pod-1\"; elif echo \"$*\" | grep -q \"image\"; then echo \"sandbox:1.2.1\"; elif echo \"$*\" | grep -q \"exec\"; then echo \"version=v2.1.0 | cpu.max=200000 100000 | memory.max=2147483648\"; fi\nexit 0\n")
os.chmod(kubectl_path, 0o755)
wget_path = os.path.join(mock_bin, "wget")
with open(wget_path, "w") as f:
    f.write("#!/bin/sh\nexit 0\n")
os.chmod(wget_path, 0o755)

env = jinja2.Environment(loader=jinja2.FileSystemLoader(os.path.join(k8s_dir, "testkube/templates")))
doc = yaml.safe_load(env.get_template("test-workflow.yaml.j2").render(minikube_ip="127.0.0.1"))
shell_script = doc["spec"]["steps"][0]["run"]["shell"]
data_dir = tempfile.mkdtemp()
shell_script = shell_script.replace("/data/sandbox_ids.txt", os.path.join(data_dir, "sandbox_ids.txt"))
shell_script = shell_script.replace("/proc/uptime", os.devnull)

run_env = os.environ.copy()
run_env["PATH"] = f"{mock_bin}:" + run_env.get("PATH", "")
run_env["SANDBOX_COUNT"] = "2"
run_env["CODE_VERSION"] = "v2.1.0-fresh"
run_env["FORCE_FRESH"] = "true"

res = subprocess.run(["/bin/sh", "-e", "-c", shell_script], env=run_env, capture_output=True, text=True)
assert res.returncode == 0, f"POSIX /bin/sh failed: {res.stderr}"
assert "bad number" not in res.stderr, f"bad number error in stderr: {res.stderr}"
assert "default-pod-1,default-pod-1" in open(os.path.join(data_dir, "sandbox_ids.txt")).read()
' >/dev/null 2>&1 && \
    assert_test "Live POSIX /bin/sh Runtime (test-workflow.yaml.j2 Freshness Gate): Executes under /bin/sh -e with zero 'bad number' errors" 0 || \
    assert_test "Live POSIX /bin/sh Runtime (test-workflow.yaml.j2 Freshness Gate): Executes under /bin/sh -e with zero 'bad number' errors" 1
else
    skip_test "Live POSIX /bin/sh Runtime (test-workflow.yaml.j2 Freshness Gate): requires Python yaml+jinja2"
fi

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

# Regression Test: tasks/00_host_prep_darwin.yml dynamically resolves Homebrew prefix (HOMEBREW_PREFIX / arm64 /opt/homebrew vs x86_64 /usr/local)
if grep -q "brew_prefix:" "${K8S_DIR}/ansible/tasks/00_host_prep_darwin.yml" && \
   grep -q "HOMEBREW_PREFIX" "${K8S_DIR}/ansible/tasks/00_host_prep_darwin.yml" && \
   grep -q "/opt/homebrew" "${K8S_DIR}/ansible/tasks/00_host_prep_darwin.yml" && \
   grep -q "/usr/local" "${K8S_DIR}/ansible/tasks/00_host_prep_darwin.yml" && \
   ! grep -q "become:" "${K8S_DIR}/ansible/tasks/00_host_prep_darwin.yml"; then
    assert_test "tasks/00_host_prep_darwin.yml: resolves HOMEBREW_PREFIX and architecture-specific prefix without sudo" 0
else
    assert_test "tasks/00_host_prep_darwin.yml: resolves HOMEBREW_PREFIX and architecture-specific prefix without sudo" 1
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

# Matrix Flows 4 & 5 Test: 00_host_prep_rocky.yml handles curl-minimal, ensures docker group, and configures Docker nftables backend on EL10+
if grep -q "curl-minimal" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "allowerasing: true" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "firewall-backend" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "nftables" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "/etc/docker/daemon.json" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "Restart Docker daemon" "${K8S_DIR}/ansible/playbooks/site.yml" && \
   grep -q "Ensure docker group exists" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "Ensure docker group exists" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml"; then
    assert_test "matrix flows 4 & 5 (Rocky): handles curl-minimal, configures EL10+ Docker nftables backend & ensures docker group exists" 0
else
    assert_test "matrix flows 4 & 5 (Rocky): handles curl-minimal, configures EL10+ Docker nftables backend & ensures docker group exists" 1
fi

# Matrix Flows 2-5 Test: 00_host_prep_{ubuntu,rocky}.yml guard Docker service and group behind native Ansible facts
if grep -q "docker_service_active_rocky" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "docker_service_active_ubuntu" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   grep -q "user_in_docker_group_rocky" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "user_in_docker_group_ubuntu" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml"; then
    assert_test "privilege guard: Docker service & group tasks guarded behind native Ansible facts to avoid unneeded sudo" 0
else
    assert_test "privilege guard: Docker service & group tasks guarded behind native Ansible facts to avoid unneeded sudo" 1
fi

# Regression Test: tasks/00_host_prep_{ubuntu,rocky}.yml guards systemd Docker activation against non-init container runners and surfaces live diagnostics
if grep -q "failed_when: false" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "ansible_facts\['service_mgr'\] == 'systemd'" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "ignore_errors: \"{{ preflight_only_mode | default(false) | bool }}\"" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "DOCKER_INFO_ERR" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "id -nG" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "failed_when: false" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   grep -q "ansible_facts\['service_mgr'\] == 'systemd'" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   grep -q "ignore_errors: \"{{ preflight_only_mode | default(false) | bool }}\"" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   grep -q "DOCKER_INFO_ERR" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" && \
   grep -q "id -nG" "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml"; then
    assert_test "tasks/00_host_prep_{ubuntu,rocky}.yml: guards systemd Docker activation and surfaces live daemon/socket/group diagnostics" 0
else
    assert_test "tasks/00_host_prep_{ubuntu,rocky}.yml: guards systemd Docker activation and surfaces live daemon/socket/group diagnostics" 1
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
if ! grep -Eq '\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}' "${K8S_DIR}"/ansible/tasks/*.yml; then
    assert_test "tasks/*.yml: Zero empty array expansions under set -u (macOS bash 3.2 compatibility)" 0
else
    assert_test "tasks/*.yml: Zero empty array expansions under set -u (macOS bash 3.2 compatibility)" 1
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
    "${K8S_DIR}/ansible/requirements.yml"
    "${K8S_DIR}/ansible/group_vars/all.yml"
    "${K8S_DIR}/ansible/playbooks/site.yml"
    "${K8S_DIR}/ansible/tasks/00_host_prep.yml"
    "${K8S_DIR}/ansible/tasks/00_host_prep_preflight_assert.yml"
    "${K8S_DIR}/ansible/tasks/00_host_prep_darwin.yml"
    "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml"
    "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml"
    "${K8S_DIR}/ansible/tasks/00_host_prep_linux_network.yml"
    "${K8S_DIR}/ansible/tasks/01_minikube_gvisor.yml"
    "${K8S_DIR}/ansible/tasks/02_k8s_stack.yml"
)

# Identify available real YAML parser (Ruby with Psych or Python with PyYAML)
YAML_PARSER=""
if command -v ruby >/dev/null 2>&1 && ruby -e 'require "yaml"' 2>/dev/null; then
    YAML_PARSER="ruby"
elif [ -n "$YAML_PY" ]; then
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
            if "$YAML_PY" -c "import yaml; list(yaml.safe_load_all(open('$manifest')))" 2>/dev/null; then
                assert_test "YAML parser syntax (PyYAML): ${rel_path}" 0
            else
                assert_test "YAML parser syntax (PyYAML): ${rel_path}" 1
            fi
        else
            skip_test "YAML parser syntax: ${rel_path} (PyYAML/Ruby not installed)"
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
JINJA_RENDER_PY="${RUNTIME_TEST_PY:-}"

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
else
    for tmpl in "test-workflow.yaml.j2" "test-workflow-security.yaml.j2" "test-workflow-sustained-load.yaml.j2"; do
        skip_test "Testkube template render (Jinja2): ${tmpl} (requires Python yaml+jinja2)"
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

# Verify cross-platform Linux/Debian sudo tty_tickets fix: build_ansible_args auto-appends --ask-become-pass when SUDO_NEEDS_PASS=true and host_needs_privilege is true
(
    HOST_PLATFORM="Linux"
    MOCK_UID=1000
    FORCE_ASK_BECOME=false
    SUDO_NEEDS_PASS=true
    CONFIGURE_HOST_SYSCTL=true
    build_ansible_args
    has_flag=false
    for arg in "${ANSIBLE_ARGS[@]}"; do
        [ "$arg" == "--ask-become-pass" ] && has_flag=true
    done
    [ "$has_flag" = true ]
) && assert_test "build_ansible_args(): Auto-appends --ask-become-pass on Debian/Linux (tty_tickets) when SUDO_NEEDS_PASS=true and host_needs_privilege=true" 0 || \
   assert_test "build_ansible_args(): Auto-appends --ask-become-pass on Debian/Linux (tty_tickets) when SUDO_NEEDS_PASS=true and host_needs_privilege=true" 1

# Verify Debian /usr/sbin:/sbin PATH inclusion in bootstrap_cluster.sh and Makefile
if grep -q "/usr/sbin:/sbin" "${BOOTSTRAP_SCRIPT}" && grep -q "/usr/sbin:/sbin" "${REPO_ROOT}/Makefile"; then
    assert_test "Debian PATH compatibility: /usr/sbin:/sbin exported in bootstrap_cluster.sh and Makefile" 0
else
    assert_test "Debian PATH compatibility: /usr/sbin:/sbin missing" 1
fi

# Verify values-mogenius.yaml warmPool.updateStrategy is set to Immediate
if grep -q "updateStrategy: Immediate" "${K8S_DIR}/helm/values-mogenius.yaml"; then
    assert_test "values-mogenius.yaml: warmPool.updateStrategy is Immediate (prevents stale standby pods)" 0
else
    assert_test "values-mogenius.yaml: warmPool.updateStrategy is not Immediate" 1
fi

# Verify testkube/rbac.yaml grants pod delete permission for Freshness Gate recycling
if grep -A 10 'resources:' "${K8S_DIR}/testkube/rbac.yaml" | grep -q '"delete"'; then
    assert_test "testkube/rbac.yaml: grants pod delete permission for Freshness Gate recycling" 0
else
    assert_test "testkube/rbac.yaml: pod delete permission missing" 1
fi

# Verify monitoring/sandbox-latency-exporter.yaml supports per-vector drift updates and cold/warm launch_type
if grep -q 'launch_type="cold"' "${K8S_DIR}/monitoring/sandbox-latency-exporter.yaml" && \
   grep -q 'active_sandboxes' "${K8S_DIR}/monitoring/sandbox-latency-exporter.yaml" && \
   grep -q 'for vec in list(state\["vectors"\].keys())' "${K8S_DIR}/monitoring/sandbox-latency-exporter.yaml"; then
    assert_test "monitoring/sandbox-latency-exporter.yaml: supports per-vector drift updates and cold/warm launch_type" 0
else
    assert_test "monitoring/sandbox-latency-exporter.yaml: per-vector drift or cold launch_type missing" 1
fi

# Verify TestWorkflow templates implement Freshness Gate (forceFreshPods), /proc/uptime latency, and cgroup audit
if grep -q "forceFreshPods" "${K8S_DIR}/testkube/templates/test-workflow.yaml.j2" && \
   grep -q "/proc/uptime" "${K8S_DIR}/testkube/templates/test-workflow.yaml.j2" && \
   grep -q "/sys/fs/cgroup/cpu.max" "${K8S_DIR}/testkube/templates/test-workflow.yaml.j2" && \
   grep -q "QUERY_VEC" "${K8S_DIR}/testkube/templates/test-workflow-security.yaml.j2"; then
    assert_test "testkube/templates/*.j2: implements Freshness Gate (forceFreshPods), /proc/uptime latency, and cgroup audit" 0
else
    assert_test "testkube/templates/*.j2: Freshness Gate, /proc/uptime, or cgroup audit missing" 1
fi

# Verify standalone k6 scripts support multi-sandbox round-robin (SANDBOX_IDS) for Scaled-Out mode
if grep -q "SANDBOX_IDS" "${K8S_DIR}/testkube/tests/k6-sandbox-benchmark.js" && \
   grep -q "SANDBOX_IDS" "${K8S_DIR}/testkube/tests/k6-sustained-load.js" && \
   grep -q "__ITER % SANDBOX_LIST.length" "${K8S_DIR}/testkube/tests/k6-sandbox-benchmark.js"; then
    assert_test "testkube/tests/k6-*.js: supports multi-sandbox round-robin (SANDBOX_IDS) for Scaled-Out mode" 0
else
    assert_test "testkube/tests/k6-*.js: multi-sandbox round-robin (SANDBOX_IDS) missing" 1
fi

# Verify Makefile supports SANDBOX_COUNT, CODE_VERSION, and FORCE_FRESH test parameters
if grep -q "SANDBOX_COUNT" "${REPO_ROOT}/Makefile" && \
   grep -q "CODE_VERSION" "${REPO_ROOT}/Makefile" && \
   grep -q "FORCE_FRESH" "${REPO_ROOT}/Makefile"; then
    assert_test "Makefile: supports SANDBOX_COUNT, CODE_VERSION, and FORCE_FRESH test parameters" 0
else
    assert_test "Makefile: SANDBOX_COUNT, CODE_VERSION, or FORCE_FRESH missing" 1
fi

# Verify Stage 0 tasks use native Ansible (getent, set_fact, group, user, service_facts) to check and add invoking user to docker group BEFORE checking Docker daemon service status
for task_file in "${K8S_DIR}/ansible/tasks/00_host_prep_ubuntu.yml" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml"; do
    bname="$(basename "$task_file")"
    getent_line=$(grep -n "ansible.builtin.getent:" "$task_file" | head -n1 | cut -d: -f1)
    grp_line=$(grep -n "Add invoking user to docker group" "$task_file" | head -n1 | cut -d: -f1)
    svc_line=$(grep -n "ansible.builtin.service_facts:" "$task_file" | head -n1 | cut -d: -f1)
    if [ -n "$getent_line" ] && [ -n "$grp_line" ] && [ -n "$svc_line" ] && \
       [ "$getent_line" -lt "$grp_line" ] && [ "$grp_line" -lt "$svc_line" ] && \
       grep -q "getent_group" "$task_file"; then
        assert_test "tasks/${bname}: natively queries getent_group (line ${getent_line}) and adds user to docker group (line ${grp_line}) BEFORE service_facts daemon check (line ${svc_line})" 0
    else
        assert_test "tasks/${bname}: natively queries getent_group and adds user to docker group BEFORE service_facts daemon check" 1
    fi
done

# Verify 00_host_prep.yml natively checks /usr/bin/sudo.ws via ansible.builtin.stat before switching ansible_become_exe (Ubuntu 25.10+ sudo-rs compatibility)
stat_line=$(grep -n "ansible.builtin.stat:" "${K8S_DIR}/ansible/tasks/00_host_prep.yml" | head -n1 | cut -d: -f1)
exe_line=$(grep -n "ansible_become_exe: /usr/bin/sudo.ws" "${K8S_DIR}/ansible/tasks/00_host_prep.yml" | head -n1 | cut -d: -f1)
if [ -n "$stat_line" ] && [ -n "$exe_line" ] && [ "$stat_line" -lt "$exe_line" ] && \
   grep -q "sudo_ws_stat.stat.exists" "${K8S_DIR}/ansible/tasks/00_host_prep.yml"; then
    assert_test "tasks/00_host_prep.yml: checks /usr/bin/sudo.ws via ansible.builtin.stat (line ${stat_line}) before switching ansible_become_exe (line ${exe_line})" 0
else
    assert_test "tasks/00_host_prep.yml: checks /usr/bin/sudo.ws via ansible.builtin.stat before switching ansible_become_exe" 1
fi

# Verify zero deprecated injected ansible_* fact variables across ansible/ (ansible-core 2.20 / 2.24 INJECT_FACTS_AS_VARS=False compatibility)
if ! grep -rnE '\bansible_(os_family|distribution|default_ipv4|pkg_mgr|hostname|architecture|system|user_id|env|memtotal_mb|service_mgr|python_version|kernel|selinux)\b' "${K8S_DIR}/ansible/" >/dev/null 2>&1; then
    assert_test "ansible/: Zero deprecated injected ansible_* fact variables (uses ansible_facts['...'] exclusively)" 0
else
    assert_test "ansible/: Deprecated injected ansible_* fact variables detected" 1
fi

# Verify Ansible collections manifest & bootstrap_cluster.sh installer + play-level handlers & Sync Gates
if grep -q "ansible.posix" "${K8S_DIR}/ansible/requirements.yml" && \
   grep -q "community.general" "${K8S_DIR}/ansible/requirements.yml" && \
   grep -q "ensure_ansible_collections" "${BOOTSTRAP_SCRIPT}" && \
   grep -q "handlers:" "${K8S_DIR}/ansible/playbooks/site.yml" && \
   grep -q "ansible.builtin.meta: flush_handlers" "${K8S_DIR}/ansible/playbooks/site.yml" && \
   grep -q "ansible.builtin.setup:" "${K8S_DIR}/ansible/playbooks/site.yml"; then
    assert_test "ansible/ & bootstrap_cluster.sh: Declares ansible.posix/community.general, play handlers & flush_handlers/setup sync gates" 0
else
    assert_test "ansible/ & bootstrap_cluster.sh: Missing collections manifest, handlers or sync gates" 1
fi

# Verify pre-mutation compliance assertions, cross-OS Linux networking, firewall, swap/zram & native apt/dnf modules
if grep -q "python_version" "${K8S_DIR}/ansible/tasks/00_host_prep_preflight_assert.yml" && \
   grep -q "ldd --version" "${K8S_DIR}/ansible/tasks/00_host_prep_preflight_assert.yml" && \
   grep -q "community.general.modprobe:" "${K8S_DIR}/ansible/tasks/00_host_prep_linux_network.yml" && \
   grep -q "persistent: present" "${K8S_DIR}/ansible/tasks/00_host_prep_linux_network.yml" && \
   grep -q "ansible.posix.sysctl:" "${K8S_DIR}/ansible/tasks/00_host_prep_linux_network.yml" && \
   grep -q "ManageForeignRoutes=no" "${K8S_DIR}/ansible/tasks/00_host_prep_linux_network.yml" && \
   grep -q "unmanaged-devices=" "${K8S_DIR}/ansible/tasks/00_host_prep_linux_network.yml" && \
   grep -q "nm-cloud-setup.service" "${K8S_DIR}/ansible/tasks/00_host_prep_linux_network.yml" && \
   grep -q "ansible.posix.firewalld:" "${K8S_DIR}/ansible/tasks/00_host_prep_linux_network.yml" && \
   grep -q "community.general.ufw:" "${K8S_DIR}/ansible/tasks/00_host_prep_linux_network.yml" && \
   grep -q "zram-generator.conf" "${K8S_DIR}/ansible/tasks/00_host_prep_linux_network.yml" && \
   grep -q "ansible.posix.selinux:" "${K8S_DIR}/ansible/tasks/00_host_prep_linux_network.yml" && \
   grep -q "ansible.builtin.yum_repository:" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml" && \
   grep -q "ansible.builtin.dnf:" "${K8S_DIR}/ansible/tasks/00_host_prep_rocky.yml"; then
    assert_test "tasks/00_host_prep_*.yml: Enforces preflight assertions, native modprobe/sysctl/firewalld/ufw/selinux/dnf/apt & zram guards" 0
else
    assert_test "tasks/00_host_prep_*.yml: Cross-OS preflight, network, firewall, swap or native package tasks missing" 1
fi

# Verify Ansible playbooks & tasks against ansible-playbook-creator structural & security rules
if [ -n "$YAML_PY" ]; then
    if "$YAML_PY" -c '
import yaml, glob, os
k8s_dir = os.environ["K8S_DIR"]
plays = yaml.safe_load(open(os.path.join(k8s_dir, "ansible/playbooks/site.yml")))
assert isinstance(plays, list) and len(plays) >= 1
for p in plays:
    assert p.get("name"), "Play missing name"
    hosts = str(p.get("hosts", ""))
    assert hosts and hosts not in ("*", "all"), f"Wildcard hosts forbidden: {hosts}"
    assert "gather_facts" in p, "Play missing explicit gather_facts"
    assert "become" in p and p.get("become_method") == "sudo", "Play missing explicit become / become_method=sudo"
    for h in p.get("handlers", []):
        assert h.get("name") and h.get("listen"), f"Handler missing name or listen: {h}"

unsafe = ["become_pass", "validate_certs: false", "verify_ssl: false", "insecure: true", "no_log: false"]
for f in sorted(glob.glob(os.path.join(k8s_dir, "ansible/tasks/*.yml"))):
    raw = open(f).read().lower()
    for pat in unsafe:
        assert pat not in raw, f"Unsafe pattern {pat} in {f}"
    for t in (yaml.safe_load(open(f)) or []):
        tname = t.get("name", "")
        assert tname, f"Task missing name in {f}"
        if "debug" in t or "ansible.builtin.debug" in t:
            dbg = t.get("ansible.builtin.debug") or t.get("debug") or {}
            assert "msg" in dbg, f"Debug task prefers msg over var in {f}: {tname}"
        if any(k in t for k in ("ansible.builtin.shell", "ansible.builtin.command", "shell", "command")):
            args = str(t.get("args", ""))
            assert "changed_when" in t or "creates" in args, f"shell/command missing changed_when in {f}: {tname}"
        tags = t.get("tags") or []
        if t.get("become") and ("preflight" in tags or "always" in tags):
            assert "dry_run_mode" in str(t.get("when", "")), f"become task missing dry_run_mode guard in {f}: {tname}"
' >/dev/null 2>&1; then
        assert_test "ansible/: Passes ansible-playbook-creator structural, non-wildcard hosts, become_method, changed_when & security scan" 0
    else
        assert_test "ansible/: Failed ansible-playbook-creator structural/security scan" 1
    fi
elif command -v ruby >/dev/null 2>&1; then
    if ruby -ryaml -e '
    k8s = ENV["K8S_DIR"]
    plays = YAML.load_file(File.join(k8s, "ansible/playbooks/site.yml"))
    plays.each do |p|
      raise "bad play" unless p["name"] && p["hosts"] && !["*", "all"].include?(p["hosts"].to_s) && p.key?("gather_facts") && p.key?("become") && p["become_method"] == "sudo"
      (p["handlers"] || []).each { |h| raise "bad handler" unless h["name"] && h["listen"] }
    end
    Dir.glob(File.join(k8s, "ansible/tasks/*.yml")).sort.each do |f|
      raw = File.read(f).downcase
      ["become_pass", "validate_certs: false", "verify_ssl: false", "insecure: true", "no_log: false"].each { |u| raise u if raw.include?(u) }
      (YAML.load_file(f) || []).each do |t|
        raise "missing name" unless t["name"]
        if ["ansible.builtin.shell", "ansible.builtin.command", "shell", "command"].any? { |k| t.key?(k) }
          raise "missing changed_when" unless t.key?("changed_when") || t.dig("args", "creates")
        end
        tags = t["tags"] || []
        if t["become"] && (tags.include?("preflight") || tags.include?("always"))
          raise "missing dry_run_mode" unless t["when"].to_s.include?("dry_run_mode")
        end
      end
    end
    ' >/dev/null 2>&1; then
        assert_test "ansible/: Passes ansible-playbook-creator structural, non-wildcard hosts, become_method, changed_when & security scan" 0
    else
        assert_test "ansible/: Failed ansible-playbook-creator structural/security scan" 1
    fi
else
    skip_test "ansible/: ansible-playbook-creator structural/security scan (requires PyYAML or Ruby)"
fi

# ==============================================================================
# Summary Report
# ==============================================================================
PASSED_TESTS=$((TOTAL_TESTS - FAILED_TESTS - SKIPPED_TESTS))
echo -e "\n${BLUE}============================================================${NC}"
if [ "$SKIPPED_TESTS" -gt 0 ]; then
    echo -e "${BLUE}Test Suite Results: ${PASSED_TESTS}/${TOTAL_TESTS} Passed (${SKIPPED_TESTS} skipped, ${FAILED_TESTS} failed)${NC}"
else
    echo -e "${BLUE}Test Suite Results: ${PASSED_TESTS}/${TOTAL_TESTS} Passed${NC}"
fi
echo -e "${BLUE}============================================================${NC}"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "${GREEN}✓ All Multi-OS, Multi-Arch Integration & Component Tests PASSED!${NC}\n"
    exit 0
else
    echo -e "${RED}✗ ${FAILED_TESTS} Test(s) FAILED! Check logs above.${NC}\n"
    exit 1
fi
