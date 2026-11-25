#!/usr/bin/env bash
# ==============================================================================
# Thin CLI Wrapper & Ansible Bootstrapper for Minikube + gVisor + Testkube
#
# Delegates all 8 architecture reconciliation layers to the declarative
# ansible-core playbook at k8s-agent-sandbox/ansible/playbooks/site.yml.
#
# USAGE MODES:
#   • Full Cluster Reconcile  : ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh
#   • Force Helm Upgrades     : ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --upgrade-helm
#   • Custom Memory Allocation: ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --memory 6144
#   • CI Mode (Lower Sizing)  : ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --ci
#   • Preflight Host Install  : ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --preflight-only
#   • Read-Only Dry-Run Audit : ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --dry-run
# ==============================================================================
set -euo pipefail
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/sbin:${PATH:-/usr/bin:/bin}"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ANSIBLE_DIR="${K8S_DIR}/ansible"
export ANSIBLE_CONFIG="${ANSIBLE_DIR}/ansible.cfg"

FORCE_HELM=false
PREFLIGHT_ONLY=false
DRY_RUN=false
CI_MODE=false
FORCE_ASK_BECOME=false
CONFIGURE_HOST_SYSCTL=false
CUSTOM_MEM="${MINIKUBE_MEMORY:-}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Thin CLI wrapper around k8s-agent-sandbox/ansible/playbooks/site.yml.

Options:
  --upgrade-helm          Force upgrade of existing Helm releases (monitoring, mogenius, testkube)
  --preflight-only        Provision/verify host OS toolchains ([0/8]) and exit before cluster changes
  --dry-run               Strictly read-only audit (zero host installs, runs ansible-playbook --check)
  --ci                    CI mode: size Minikube cluster for 2 vCPUs and 4096 MB RAM
  --memory <MB>           Set custom Minikube memory in MB (e.g. --memory 6144, min: 2048)
  --configure-host-sysctl Configure host Linux kernel sysctl and limits (/etc/sysctl.d, /etc/security/limits.d)
  -K, --ask-become-pass   Prompt for privilege escalation (sudo) password for ansible tasks
  -h, --help              Show this help message and exit
EOF
}

run_priv() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; elif command -v sudo >/dev/null 2>&1; then sudo "$@"; else
        echo -e "${RED}✗ Error: Root privileges required for '$*' but 'sudo' is not installed.${NC}" >&2; exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --upgrade-helm) FORCE_HELM=true; shift ;;
            --preflight-only) PREFLIGHT_ONLY=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --ci) CI_MODE=true; shift ;;
            --configure-host-sysctl) CONFIGURE_HOST_SYSCTL=true; shift ;;
            -K|--ask-become-pass) FORCE_ASK_BECOME=true; shift ;;
            --memory)
                if [[ $# -lt 2 ]] || [[ -z "$2" ]] || [[ "$2" == --* ]]; then
                    echo -e "${RED}✗ Error: --memory requires an integer >= 2048 MB.${NC}" >&2; exit 1
                fi
                CUSTOM_MEM="$2"; shift 2 ;;
            --memory=*) CUSTOM_MEM="${1#*=}"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) echo -e "${RED}✗ Error: Unrecognized option '$1'.${NC}" >&2; usage >&2; exit 1 ;;
        esac
    done
    if [ -n "$CUSTOM_MEM" ] && { ! [[ "$CUSTOM_MEM" =~ ^[0-9]+$ ]] || [ "$CUSTOM_MEM" -lt 2048 ]; }; then
        echo -e "${RED}✗ Error: Invalid memory '${CUSTOM_MEM}'. Must be >= 2048 MB.${NC}" >&2; exit 1
    fi
}

detect_platform() {
    OS_NAME="$(uname -s)"; RAW_ARCH="$(uname -m)"
    case "${RAW_ARCH}" in
        x86_64|amd64) ARCH_CLI="amd64"; ARCH_RUNSC="x86_64" ;;
        arm64|aarch64) ARCH_CLI="arm64"; ARCH_RUNSC="aarch64" ;;
        *) echo -e "${RED}✗ Unsupported CPU architecture: ${RAW_ARCH}${NC}" >&2; return 1 ;;
    esac
    if [ "${OS_NAME}" == "Darwin" ]; then HOST_PLATFORM="macOS"; PKG_MGR="brew"
    elif [ "${OS_NAME}" == "Linux" ]; then
        HOST_PLATFORM="Linux"
        if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
        elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
        elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
        else PKG_MGR="generic"; fi
    else echo -e "${RED}✗ Unsupported OS: ${OS_NAME}${NC}" >&2; return 1; fi
}

ensure_ansible() {
    command -v ansible-playbook >/dev/null 2>&1 && return 0
    echo -e "  ${CYAN}[>]${NC} Installing 'ansible-core' via ${PKG_MGR}..."
    if [ "$PKG_MGR" == "brew" ]; then brew install ansible
    elif [ "$PKG_MGR" == "apt" ]; then run_priv apt-get update -qq && run_priv apt-get install -y -qq ansible-core || run_priv apt-get install -y -qq ansible
    elif [ "$PKG_MGR" == "dnf" ]; then
        run_priv dnf install -y ansible-core 2>/dev/null || { run_priv dnf install -y epel-release 2>/dev/null || true; run_priv dnf install -y ansible-core; } || run_priv dnf install -y ansible
    elif [ "$PKG_MGR" == "yum" ]; then
        run_priv yum install -y ansible-core 2>/dev/null || { run_priv yum install -y epel-release 2>/dev/null || true; run_priv yum install -y ansible-core; } || run_priv yum install -y ansible
    else echo -e "${RED}✗ Please install ansible-core (ansible-playbook).${NC}" >&2; exit 1; fi
}

host_needs_privilege() {
    [ "${CONFIGURE_HOST_SYSCTL:-false}" = true ] && return 0
    if [ "${HOST_PLATFORM:-}" == "Linux" ]; then
        for tool in curl tar jq bzip2 openssl; do
            command -v "$tool" >/dev/null 2>&1 || return 0
        done
        for tool in kubectl minikube helm testkube; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                [ ! -w "/usr/local/bin" ] && return 0
            fi
        done
        command -v docker >/dev/null 2>&1 || return 0
        # If systemd is managing services on this Linux host and docker daemon is inactive, Stage 0 requires privilege to start it
        if [ -d /run/systemd/system ] && ! docker info >/dev/null 2>&1; then
            return 0
        fi
        # Check if invoking user belongs to the docker group
        if command -v id >/dev/null 2>&1 && ! id -Gn 2>/dev/null | grep -qw docker; then
            return 0
        fi
    fi
    return 1
}

detect_sudo_mode() {
    SUDO_NEEDS_PASS=false
    local eff_uid="${MOCK_UID:-$(id -u)}"
    if [ "${HOST_PLATFORM}" == "Linux" ] && [ "$eff_uid" -ne 0 ]; then
        if [ "$FORCE_ASK_BECOME" = true ] || [ "${PKG_MGR:-}" == "apt" ] || ! sudo -n true 2>/dev/null; then
            SUDO_NEEDS_PASS=true
        fi
    fi
}

build_ansible_args() {
    local eff_uid="${MOCK_UID:-$(id -u)}"
    ANSIBLE_ARGS=(-i "${ANSIBLE_DIR}/inventory.ini" "${ANSIBLE_DIR}/playbooks/site.yml"
                  -e "force_helm_upgrade=${FORCE_HELM}"
                  -e "minikube_ci_mode=${CI_MODE}"
                  -e "minikube_custom_memory_mb=${CUSTOM_MEM}"
                  -e "configure_linux_sysctl=${CONFIGURE_HOST_SYSCTL}"
                  -e "preflight_only_mode=${PREFLIGHT_ONLY}")
    if [ "${HOST_PLATFORM}" == "Linux" ] && [ "$eff_uid" -ne 0 ]; then
        if [ "$FORCE_ASK_BECOME" = true ] || { [ "${SUDO_NEEDS_PASS:-false}" = true ] && host_needs_privilege; }; then
            ANSIBLE_ARGS+=(--ask-become-pass)
        fi
    fi
}

main() {
    parse_args "$@"
    detect_platform
    local target_cpus=4 target_mem="${CUSTOM_MEM:-8192}"
    [ "$CI_MODE" = true ] && { target_cpus=2; target_mem="${CUSTOM_MEM:-4096}"; }
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}Minikube Agent Sandbox & Testkube Ansible Reconciler${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo -e "Host: ${GREEN}${HOST_PLATFORM}${NC} | Arch: ${GREEN}${RAW_ARCH} (${ARCH_CLI})${NC} | Toolchain: ${GREEN}${PKG_MGR}${NC} | Sizing: ${GREEN}${target_cpus} CPUs / ${target_mem} MB${NC}"

    if [ "$DRY_RUN" = true ]; then
        if command -v ansible-playbook >/dev/null 2>&1; then
            ansible-playbook -i "${ANSIBLE_DIR}/inventory.ini" "${ANSIBLE_DIR}/playbooks/site.yml" \
                --check --diff --tags preflight -e "dry_run_mode=true" -e "minikube_ci_mode=${CI_MODE}" -e "minikube_custom_memory_mb=${CUSTOM_MEM}"
        else
            echo -e "  ${YELLOW}[i]${NC} ansible-playbook not present; auditing host CLI tools directly:"
            for tool in kubectl minikube helm testkube docker; do
                if command -v "$tool" >/dev/null 2>&1; then echo -e "    ${GREEN}✓${NC} $tool: $(command -v "$tool")"
                else echo -e "    ${YELLOW}✗${NC} $tool: MISSING"; fi
            done
        fi
        echo -e "${GREEN}Dry-Run Audit Complete (--dry-run: Zero changes made)!${NC}"
        exit 0
    fi

    ensure_ansible
    detect_sudo_mode
    build_ansible_args

    if [ "$PREFLIGHT_ONLY" = true ]; then
        ansible-playbook "${ANSIBLE_ARGS[@]}" --tags preflight
        echo -e "${GREEN}Preflight & Toolchain Discovery Successful (--preflight-only)!${NC}"
        exit 0
    fi

    # Full 8-Stage Reconciliation in a single Ansible execution (Stage 0 -> Stage 8)
    ansible-playbook "${ANSIBLE_ARGS[@]}"
    echo -e "${GREEN}Cluster is 100% CONVERGED, HEALTHY & READY!${NC}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
