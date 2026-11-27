# ==============================================================================
# Makefile: Developer Test Tiers & Cluster Automation
#
# Provides fast static checks (zero VM spin-up) vs. full cluster reconciliation.
# ==============================================================================

export PATH := /opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/sbin:$(PATH)

.PHONY: all help test check dry-run preflight cluster bootstrap clean status test-security test-benchmark test-load

# Default: Fast verification without spinning up VMs
all: check

help:
	@echo "Available Make targets:"
	@echo "  --- Fast Verification (Zero VM spin-up) ---"
	@echo "  make check           - Fast verification: syntax, manifests & unit tests (~15s)"
	@echo "  make dry-run         - Read-only Ansible audit: validates host tools & sizing (~5s)"
	@echo "  make preflight       - Toolchain discovery: validates [0/8] host tools only"
	@echo ""
	@echo "  --- Cluster Lifecycle & Reconciliation (Heavy VM) ---"
	@echo "  make cluster         - Full 8-stage reconciler: provisions 2-node Minikube cluster & workloads"
	@echo "  make status          - Print status of Minikube nodes and cluster pods"
	@echo "  make clean           - Teardown local Minikube cluster"
	@echo ""
	@echo "  --- Testkube Workflows (Requires Live Cluster) ---"
	@echo "  make test-security   - Run in-guest threat probe + k6 security & tenant isolation audit"
	@echo "  make test-benchmark  - Run 60 QPS performance & concurrency benchmark"
	@echo "  make test-load       - Run sustained 70 RPS load test"
	@echo ""
	@echo "Options:"
	@echo "  Pass ARGS='<flags>' to forward CLI options (e.g., make cluster ARGS='-K' or make preflight ARGS='--memory 4096')"
	@echo "  Pass DURATION='<time>' QPS='<rate>' SANDBOX_COUNT='<N>' CODE_VERSION='<ver>' FORCE_FRESH='<true|false>' to test targets"
	@echo "  Examples: make test-load DURATION=2m QPS=100 SANDBOX_COUNT=3 | make test-benchmark CODE_VERSION=v2.0 FORCE_FRESH=true"

# Fast verification: syntax, YAML schemas, and unit tests (Zero VM spinup)
test check:
	@echo "==> Running Fast Integration & Unit Test Suite (Zero VM spin-up)..."
	@./k8s-agent-sandbox/scripts/test_multios_bootstrap.sh

# Read-only dry-run audit (validates Ansible syntax, host tools, and sizing without mutations)
dry-run:
	@echo "==> Running Read-Only Dry-Run Audit (--dry-run)..."
	@./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --dry-run $(ARGS)

# Host toolchain discovery & preflight check only
preflight:
	@echo "==> Running Host Toolchain Preflight Discovery (--preflight-only)..."
	@./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --preflight-only $(ARGS)

# Full cluster bringup and 8-stage reconciliation (HEAVY: spins up Minikube nodes & containers)
cluster bootstrap:
	@echo "==> Running Full 8-Stage Cluster Reconciler..."
	@./k8s-agent-sandbox/scripts/bootstrap_cluster.sh $(ARGS)

# Inspect cluster health and pods
status:
	@echo "==> Minikube Nodes:"
	@kubectl get nodes -o wide 2>/dev/null || minikube status 2>/dev/null || echo "Cluster is not running"
	@echo ""
	@echo "==> Workload Pods:"
	@kubectl get pods -A 2>/dev/null || true

# Testkube test execution targets
DURATION ?=
QPS ?=
TARGET_URL ?=
SANDBOX_COUNT ?=
CODE_VERSION ?=
FORCE_FRESH ?=
TK_CFG = $(if $(DURATION),--config duration=$(DURATION)) \
         $(if $(QPS),--config qps=$(QPS)) \
         $(if $(TARGET_URL),--config targetUrl=$(TARGET_URL)) \
         $(if $(SANDBOX_COUNT),--config sandboxCount=$(SANDBOX_COUNT)) \
         $(if $(CODE_VERSION),--config codeVersion=$(CODE_VERSION)) \
         $(if $(FORCE_FRESH),--config forceFreshPods=$(FORCE_FRESH))

test-security:
	@echo "==> Triggering Testkube Security & Red-Team Audit Workflow..."
	@testkube run tw agent-sandbox-security-audit $(TK_CFG) $(ARGS) -f

test-benchmark:
	@echo "==> Triggering Testkube Benchmark Workflow..."
	@testkube run tw agent-sandbox-benchmark $(TK_CFG) $(ARGS) -f

test-load:
	@echo "==> Triggering Testkube Sustained Load Workflow..."
	@testkube run tw agent-sandbox-sustained-load $(TK_CFG) $(ARGS) -f

# Teardown local cluster
clean:
	@echo "==> Deleting Minikube cluster nodes..."
	@minikube delete 2>/dev/null || true
	@rm -f k8s-agent-sandbox/testkube/test-workflow*.yaml
