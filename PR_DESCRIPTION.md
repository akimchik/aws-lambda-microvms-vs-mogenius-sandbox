# Pull Request: Declarative Ansible Reconciler, Multi-OS Zero-Root Bootstrap, Root Makefile DX & Clean-OS Hardening

## 📌 Overview & Motivation

This PR completes the architectural migration of the **2-node Kubernetes Agent Sandbox platform (`mogenius` + Google gVisor + Testkube OSS)** reconciler across **macOS Darwin (Apple Silicon & Intel)**, **Ubuntu/Debian (`apt`)**, and **RHEL / Rocky Linux 9 & 10 (`dnf`/`yum`)**.

The monolithic, procedural shell logic has been replaced with a declarative, modular **`ansible-core`** orchestration engine running zero external `pip` packages or Galaxy collections. In addition, developer workflows, privilege boundaries, kernel resource limits, and minimal Linux preflight handling have been hardened.

---

## 🚀 Key Highlights & Architectural Changes

### 1. ⚡ Really Cool Developer Experience: Root `Makefile`
Eliminates typing long, nested script paths (`./k8s-agent-sandbox/scripts/...`) or memorizing complex CLI flags. The repository root now features a standardized [`Makefile`](Makefile):

| Target | Execution Profile | Purpose |
| :--- | :--- | :--- |
| `make check` *(or `make test`)* | ⚡ Fast (~15s, 0 VM) | Runs **98/98 unit & integration tests**: Shell, Python AST, k6 JS, and YAML manifests. |
| `make dry-run` | ⚡ Fast (~5s, 0 VM) | Read-only Ansible audit (`ansible-playbook --check --diff`). Validates host tools & sizing without mutations. |
| `make preflight` | ⚡ Fast (0 VM) | Audits and installs missing host OS toolchains (`[0/8]`) without touching Minikube. |
| `make cluster` | 🏗️ Heavy (VM spin-up) | Provisions & converges the entire 2-node cluster and all 8 layers. |
| `make status` | 🔍 Quick Check | Prints status of Minikube nodes and workload pods. |
| `make clean` | 🧹 Teardown | Deletes local Minikube cluster cleanly. |
| `make test-security` | 🧪 Live Cluster Test | Runs in-guest threat probe (`T1`–`T6`) + k6 security & tenant isolation audit. |
| `make test-benchmark` | 🧪 Live Cluster Test | Runs 60 QPS performance & concurrency benchmark. |
| `make test-load` | 🧪 Live Cluster Test | Runs sustained 70 RPS load test. |

---

### 2. 🔐 Least-Privilege Security Boundary & Zero-Host-Root
* **User-Space Kubernetes Execution:** Minikube (Docker driver), Helm charts, mogenius controller, gVisor sandboxes, and Testkube execute 100% in unprivileged user space. They **never** require root privileges or Ansible `become: true`.
* **Zero Unexpected Sudo Prompts:** Eliminated unexpected `BECOME password:` prompts and aborted Ansible runs.
* **Keepalive Loop for Host Tooling:** When installing missing binaries into `/usr/local/bin`, `bootstrap_cluster.sh` authenticates once in bash (`sudo -v`) and launches a lightweight 50-second keepalive loop to keep credentials fresh during long reconciliations.
* **Opt-in Host Kernel Changes:** Host `/etc/sysctl.d` and PAM file limit modifications are strictly opt-in via `--configure-host-sysctl`.

---

### 3. 📈 Inotify & Open File Exhaustion Fix (`fsnotify: too many open files`)
* **Root Cause:** Standard Linux distributions default to only `128` user inotify instances (`fs.inotify.max_user_instances=128`). Under concurrent load from kubelet, containerd, NGINX Ingress, Prometheus TSDB, mogenius controller, and Testkube workflow pod tailers (`testkube-tw-toolkit` uses Go's `fsnotify`), instances were rapidly exhausted during k6 fuzzing.
* **Solution:** Raised `fs.inotify.max_user_instances` to **`8192`** and `fs.inotify.max_user_watches` to **`1048576`**.
* **Zero Host Sudo Required:** During cluster reconciliation (`make cluster`), Ansible configures these parameters directly inside the `minikube` and `minikube-m02` node containers via `minikube ssh` using container-local root permissions—requiring zero host sudo.

---

### 4. 🍏 macOS Bash 3.2 Compatibility Hardening
* **Root Cause:** macOS ships with `/bin/bash` 3.2.57. Under `set -euo pipefail` (`set -u` / `nounset`), Bash 3.2 treats expanding an empty array (`"${VER_ARG[@]}"` when `VER_ARG=()`) as an unbound variable, throwing `/bin/bash: line 9: VER_ARG[@]: unbound variable`.
* **Solution:** Replaced empty array expansions with unquoted scalar arguments (`${EXTRA_HELM_ARG}`) that cleanly expand to zero tokens when empty under `set -u` across all Bash versions (3.2 through 5.3). Added defensive defaults (`default(...)`) to Ansible sizing facts.

---

### 5. 🐧 Clean Linux (Rocky Linux 10 / RHEL / Ubuntu) Zero-Toil Preflight
* **Openssl Prerequisite:** Minimal Rocky Linux 10 and RHEL images include `curl` and `tar`, but omit `/usr/bin/openssl`. When the official `get-helm-3` script was executed, it failed with `In order to verify checksum, openssl must first be installed`.
* **Solution:**
  - Added `openssl` and `procps-ng` to base utilities audit (`base_utils_check`) and native package manager install tasks.
  - Added `epel-release` fallback for RHEL/Rocky variants.
  - Implemented self-healing in Helm installer: attempts native package manager install of `openssl` if missing, and falls back to `VERIFY_CHECKSUM=false` so installation never halts.

---

### 6. 🧪 Expanded 98-Test Automated Verification Suite
[`test_multios_bootstrap.sh`](k8s-agent-sandbox/scripts/test_multios_bootstrap.sh) expanded from 34 to **98 passing tests**:
* **Embedded Ansible Task Syntax Check:** Dynamically parses and runs `bash -n` on all embedded shell tasks in `00_host_prep.yml`, `01_minikube_gvisor.yml`, and `02_k8s_stack.yml`.
* **Empty Array AST Audit:** Scans all Ansible task files for dangerous empty array expansions under `set -u`.
* **Execution Tests:** Validates helm chart upgrade logic, testkube upgrade logic, and warm pool selector wait targets under `/bin/bash` with `set -euo pipefail`.
* **Multi-Arch & Multi-OS Matrix:** Verifies URL reachability, platform detection, memory clamping, and YAML syntax across 21 components.

---

## 📋 Verification Checklist

- [x] `make check`: 98/98 unit & integration tests pass (~15s, 0 VM).
- [x] `make dry-run`: Read-only Ansible audit succeeds (`ok=10 changed=0 failed=0`, ~5s, 0 VM).
- [x] `make preflight`: Host toolchain discovery validates cleanly on macOS and Linux.
- [x] `make cluster`: Full 8-layer reconciliation succeeds on macOS.
- [x] Clean Rocky Linux 10 preflight toolchain resolution verified (`openssl`, `dnf`, `helm`).
- [x] Documentation updated in [`README.md`](README.md) and [`docs/MULTI_OS_SETUP_GUIDE.md`](docs/MULTI_OS_SETUP_GUIDE.md).
