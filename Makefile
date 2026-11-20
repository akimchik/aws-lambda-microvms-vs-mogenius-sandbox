# ==============================================================================
# Makefile: Developer Test Tiers & Cluster Automation
#
# Provides fast static checks (zero VM spin-up) vs. full cluster reconciliation.
# ==============================================================================

export PATH := /usr/local/bin:/usr/local/sbin:$(PATH)

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

# Fast verification: syntax, YAML schemas, and unit tests (Zero VM spinup)
test check:
	@echo "==> Running Fast Integration & Unit Test Suite (Zero VM spin-up)..."
	@./k8s-agent-sandbox/scripts/test_multios_bootstrap.sh

# Read-only dry-run audit (validates Ansible syntax, host tools, and sizing without mutations)
dry-run:
	@echo "==> Running Read-Only Dry-Run Audit (--dry-run)..."
	@./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --dry-run

# Host toolchain discovery & preflight check only
preflight:
	@echo "==> Running Host Toolchain Preflight Discovery (--preflight-only)..."
	@./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --preflight-only

# Full cluster bringup and 8-stage reconciliation (HEAVY: spins up Minikube nodes & containers)
cluster bootstrap:
	@echo "==> Running Full 8-Stage Cluster Reconciler..."
	@./k8s-agent-sandbox/scripts/bootstrap_cluster.sh

# Inspect cluster health and pods
status:
	@echo "==> Minikube Nodes:"
	@kubectl get nodes -o wide || minikube status -p minikube
	@echo "\n==> Workload Pods:"
	@kubectl get pods -A

# Testkube test execution targets
test-security:
	@echo "==> Triggering Testkube Security & Red-Team Audit Workflow..."
	@testkube run tw agent-sandbox-security-audit -f

test-benchmark:
	@echo "==> Triggering Testkube Benchmark Workflow..."
	@testkube run tw agent-sandbox-benchmark -f

test-load:
	@echo "==> Triggering Testkube Sustained Load Workflow..."
	@testkube run tw agent-sandbox-sustained-load -f

# Teardown local cluster
clean:
	@echo "==> Deleting Minikube cluster nodes..."
	@minikube delete -p minikube || true
