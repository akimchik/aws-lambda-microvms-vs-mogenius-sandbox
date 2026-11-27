# Multi-OS & Multi-Architecture Setup Guide: macOS, Linux & Windows (WSL 2)

This guide provides end-to-end instructions for provisioning and running the **2-node Kubernetes Agent Sandbox platform (`mogenius` + Google gVisor + Testkube OSS)** across **macOS**, **Linux**, and **Windows (WSL 2)**, covering both **`aarch64` (ARM64)** and **`x86_64` (AMD64)** CPU architectures.

---

## 🏗️ Architecture & OS Compatibility Matrix

| Environment | Host CPU Architecture | Container Engine | gVisor (`runsc`) Mode | Networking Model |
| :--- | :--- | :--- | :--- | :--- |
| **macOS (Apple Silicon)** | `aarch64` / `arm64` (M1–M4) | Docker Desktop / OrbStack | Native ARM64 `runsc` (`ptrace`) | Docker VM bridge (requires `minikube tunnel` or port-forward for Ingress) |
| **macOS (Intel)** | `x86_64` / `amd64` | Docker Desktop / OrbStack | Native AMD64 `runsc` (`ptrace`) | Docker VM bridge (requires `minikube tunnel` or port-forward for Ingress) |
| **Linux (Ubuntu / Debian / RHEL)** | `x86_64` / `amd64` or `aarch64` | Native Docker Engine (CE) | Native `runsc` (`ptrace` / KVM) | Native Linux Docker bridge (`minikube ip` directly routable) |
| **Windows 10 / 11 (WSL 2)** | `x86_64` / `amd64` or `aarch64` | Native Docker CE inside Ubuntu | Native `runsc` inside WSL 2 kernel | WSL 2 virtual bridge (forwarded to Windows `localhost`) |

### Multi-Architecture Notes (`aarch64` vs `x86_64`)
* **We initially built and validated this platform on `aarch64`** (Apple Silicon M-series).
* **100% Multi-Arch Image Support:** All container images in the stack (`ghcr.io/mogenius/agent-sandbox-chart/sandbox-default:1.2.1`, `bitnami/mongodb`, `grafana/grafana`, `ingress-nginx/controller`, `prometheus/prometheus`, `kubeshop/testkube-api-server`, `grafana/k6`) provide native multi-architecture manifests supporting both `linux/amd64` and `linux/arm64`.
* **Self-Contained gVisor Binary Installation:** In `k8s-agent-sandbox/ansible/tasks/01_minikube_gvisor.yml`, Stage 1 (`[3/8]`) downloads the official Google gVisor release archive (`gvisor.tar.bz2`, containing `runsc`, `containerd-shim-runsc-v1`, and `gvisor-bin/gvisor_sentry`) matching the detected CPU architecture (`x86_64` or `aarch64`) directly from Google Cloud Storage (`storage.googleapis.com/gvisor/releases/release/latest/${ARCH}`). This avoids reliance on APT package managers, third-party OpenSUSE/Kubic repositories, or expired GPG keys inside the Minikube node.

---

## 🔐 Privilege Escalation, Sudo Lifecycle & Security Model

To ensure secure, non-destructive execution across local developer workstations and shared CI/CD runners, the bootstrapper ([`k8s-agent-sandbox/scripts/bootstrap_cluster.sh`](../k8s-agent-sandbox/scripts/bootstrap_cluster.sh)) and Ansible reconciler ([`k8s-agent-sandbox/ansible/playbooks/site.yml`](../k8s-agent-sandbox/ansible/playbooks/site.yml)) operate under a strict **least-privilege boundary**:

### 1. The Least-Privilege Boundary (Stages 1–8 User Space vs. Stage 0 Host Prep)
* **No Sudo for Kubernetes (Stages 1–8):** Minikube (Docker driver), Helm charts, mogenius controller, gVisor sandboxes, and Testkube all execute entirely within unprivileged user space. Stages 1–8 **never** require root privileges or Ansible `become: true`.
* **When Stage 0 (`[0/8]`) Requires `sudo` (`BECOME password:`):** On a clean Linux machine where CLI tools (`kubectl`, `minikube`, `helm`, `testkube`), Docker Engine, or the invoking user's `docker` group membership (`/etc/group`) are not yet configured, Stage 0 requires `sudo` (`become: true`) once to provision those host prerequisites. Once tools are installed and the user is in the `docker` group with `docker.service` running, subsequent runs execute **100% as the unprivileged user** with zero sudo calls and zero password prompts.

### 2. Privilege Need Detection (`host_needs_privilege`) & When a `sudo` Password Is Required
Root privileges (`BECOME password:` / `sudo`) are strictly confined to **Stage 0 (`[0/8]`) machine-level prerequisites**:
1. **Toolchain & Docker Engine bootstrap:** Installing `ansible-core`, base utilities (`curl`, `jq`, `tar`, `bzip2`, `openssl`), missing CLI binaries (`kubectl`, `minikube`, `helm`, `testkube`) into `/usr/local/bin` when not writable by the current user, or installing the `docker` package via `apt` / `dnf`.
2. **Docker group membership (`ansible.builtin.getent`, `ansible.builtin.group` & `ansible.builtin.user`):** Stage 0 natively queries `/etc/group` via `ansible.builtin.getent` (`ansible_facts['getent_group']['docker']`). If the current user does not yet belong to the `docker` system group, Ansible **requires `sudo` (`become: true`)** to ensure the `docker` group exists and append the user to `/etc/group` **before** evaluating `ansible.builtin.service_facts` or verifying the Docker daemon. Without membership in the `docker` group, `/var/run/docker.sock` (`root:docker`, `0660`) rejects unprivileged connections and Minikube (`--driver=docker`) cannot run in user space.
3. **Docker systemd service activation (`ansible.builtin.systemd`):** If `docker.service` is stopped or disabled on a Linux `systemd` host, `sudo` is required to start and enable the unit.
4. **Kernel sysctl (`--configure-host-sysctl`):** Applying persistent high-concurrency open file descriptor and inotify limits (`/etc/sysctl.d`, `/etc/security/limits.d`).

If all CLI tools are present in `$PATH`, the `docker` daemon is active, the user is already a member of the `docker` group, and `--configure-host-sysctl` is not passed, `host_needs_privilege` evaluates to `false` and privilege escalation is completely bypassed.

### 3. Sudo Lifecycle Flowchart
```
                [ ./bootstrap_cluster.sh ]
                            │
                            ▼
                  host_needs_privilege()?
                    ├── Base tools or Docker missing? (curl, jq, tar, openssl, docker)
                    ├── CLIs missing & /usr/local/bin read-only?
                    ├── User not in 'docker' group or docker.service inactive?
                    └── --configure-host-sysctl passed?
                            │
               ┌────────────┴────────────┐
               ▼                         ▼
         [ FALSE ]                   [ TRUE ]
       (Tools & group ready)       (Setup required)
               │                         │
               ▼                         ├── PKG_MGR == "apt" (Debian/Ubuntu tty_tickets)?
       Zero Sudo Invocations             │    ├── YES ──► Always pass --ask-become-pass
       Zero BECOME Prompts               │    └── NO (Rocky/RHEL dnf) ──► Check sudo -n true
       Ansible runs as USER              │         ├── Cached ──► Continue without prompt
                                         │         └── No Ticket ──► Pass --ask-become-pass
                                         ▼
                               Single-Pass Ansible Playbook (site.yml)
                                 • Stage 0 ([0/8] tasks with become: true):
                                   - Ubuntu 25.10+: auto-switches to /usr/bin/sudo.ws via stat
                                   - Installs missing tools/Docker to /usr/local/bin
                                   - Adds user to 'docker' group BEFORE checking daemon
                                   - Starts docker.service if inactive
                                 • Stages 1-8 ([1/8]-[8/8] tasks with zero become):
                                   - Runs 100% in unprivileged user space
```

### 4. Automatic `BECOME password:` Prompting Across Debian 13 (`tty_tickets`), Ubuntu 25.10+ (`sudo-rs`), and Rocky Linux
Different Linux distributions enforce different `sudo` session and prompt behaviors:
* **Debian 12/13 & Ubuntu (`PKG_MGR == "apt"` with `tty_tickets`):** Because `sudo` isolates timestamp tickets per pseudo-terminal (`Defaults tty_tickets`), a cached ticket in the parent shell does not transfer across Ansible's Python PTY subprocesses. Therefore, `detect_sudo_mode()` skips `sudo -n true` on `apt` systems and always sets `SUDO_NEEDS_PASS=true`, ensuring `build_ansible_args()` passes `--ask-become-pass` whenever `host_needs_privilege` is `true` so Ansible prompts cleanly for `BECOME password:` once at the start of the single-pass playbook run.
* **Ubuntu 25.10+ (`sudo-rs` vs. `/usr/bin/sudo.ws`):** Ubuntu 25.10 migrated `/usr/bin/sudo` to Rust `sudo-rs`, which wraps custom `-p` prompts in `[sudo: ...] Password:` and breaks Ansible's prompt matching. Stage 0 (`k8s-agent-sandbox/ansible/tasks/00_host_prep.yml`) natively checks `/usr/bin/sudo.ws` via `ansible.builtin.stat` and sets `ansible_become_exe: /usr/bin/sudo.ws` when present.
* **Rocky Linux 9/10 & RHEL (`PKG_MGR == "dnf"`):** `detect_sudo_mode()` checks `sudo -n true`; if a ticket is already cached, Ansible proceeds without prompting, otherwise `--ask-become-pass` is appended.

### 5. Linux Kernel Tweaks, Cross-OS Network Guards & Optional Hardening Controls
Stage 0 (`00_host_prep_preflight_assert.yml` and `00_host_prep_linux_network.yml`) enforces read-only host compliance checks (`Python >= 3.9`, `RAM >= 2 GB`, `CPUs >= 2`, `kernel >= 5.2`, `glibc`) on every run, while keeping invasive host OS mutations safe for developer laptops unless explicitly enabled:
* **In-Node Minikube Tuning (Automatic, Zero Host Root):** Stage 1 (`01_minikube_gvisor.yml`) automatically tunes `fs.inotify.max_user_watches=1048576`, `fs.inotify.max_user_instances=8192`, `fs.file-max=2097152`, `vm.max_map_count=262144`, `net.bridge.bridge-nf-call-iptables=1`, and `rp_filter=2` inside every Minikube node, and renders a version-aware `/etc/containerd/conf.d/10-gvisor-runsc.toml` drop-in supporting both **containerd 1.x (config v2)** and **containerd 2.x (config v3)** with explicit `SystemdCgroup = true`.
* **Host Kernel, Module & Network Daemon Hardening (`--configure-host-sysctl`):** `bootstrap_cluster.sh` passes `-e configure_linux_sysctl=false` by default unless `--configure-host-sysctl` is specified. When enabled, Ansible loads/persists `overlay` & `br_netfilter` via `community.general.modprobe` (`persistent: present`), applies `/etc/sysctl.d/99-kubernetes-cri.conf` via `ansible.posix.sysctl` (with uniform `k8s_rp_filter_mode: "2"` across `all`, `default`, and active interfaces), protects `systemd-networkd` (`ManageForeignRoutes=no`) and `NetworkManager` (`unmanaged-devices`), disables `nm-cloud-setup`, and scopes `ansible.posix.selinux` strictly to RedHat-family hosts.
  ```bash
  # Explicitly enable host-level kernel, module & network daemon hardening
  ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --configure-host-sysctl

  # Optional Ansible extra-vars for dedicated Kubernetes VMs:
  # -e k8s_firewall_mode=configure   (or 'disable' on RHEL/Rocky 10+)
  # -e k8s_disable_swap=true         (swapoff -a + /etc/fstab + systemd-zram-generator neutralization)
  ```

### 6. Explicit Ansible Privilege Escalation (`-K` / `--ask-become-pass`)
When all tools and `docker` group membership are already configured, Ansible never prompts for `BECOME password:`. You can also force a `BECOME password:` prompt at any time by passing `-K`:
```bash
./k8s-agent-sandbox/scripts/bootstrap_cluster.sh -K
```

---

## 🛠️ Reconciler CLI Reference & Execution Modes

To avoid having to type long nested script paths or memorize CLI flags, the root [`Makefile`](../Makefile) provides standardized shortcuts across all developer workflows:

### ⚡ Developer Makefile Cheatsheet vs. Direct Scripts

| Goal / Stage | Make Target (Recommended) | Direct Script Command | Profile / Sizing | Privilege (`sudo` / `BECOME`) Required |
| :--- | :--- | :--- | :--- | :--- |
| **Fast Verification** | `make check` *(or `make test`)* | `./k8s-agent-sandbox/scripts/test_multios_bootstrap.sh` | **Zero VM (~15s)**: 150 unit, live HTTP/containerd runtime, POSIX `/bin/sh` & security tests | ❌ No |
| **Read-Only Audit** | `make dry-run` | `./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --dry-run` | **Zero VM (~5s)**: Ansible `--check --diff`, sizing audit | ❌ No |
| **Tool Preflight** | `make preflight` | `./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --preflight-only` | Host CLI discovery, Docker install & `docker` group setup (`[0/8]`) | ⚠️ **Yes (`sudo` on Linux) if tools/Docker missing, `docker.service` stopped, or user not in `docker` group**; ❌ No once configured |
| **Reconcile Cluster**| `make cluster` | `./k8s-agent-sandbox/scripts/bootstrap_cluster.sh` | Full 8-layer deployment (Stage 0 preflight + Stages 1–8 user-space K8s) | ⚠️ **Yes (`sudo` in Stage 0) if tools/Docker missing, `docker.service` stopped, or user not in `docker` group**; ❌ No (100% user space) once configured |
| **Cluster Status** | `make status` | `kubectl get nodes -o wide && kubectl get pods -A` | Prints status of Minikube nodes and workload pods | ❌ No |
| **Teardown** | `make clean` | `minikube delete && rm -f k8s-agent-sandbox/testkube/test-workflow*.yaml` | Deletes local Minikube cluster nodes & rendered workflows | ❌ No |
| **Security Audit** | `make test-security` | `testkube run tw agent-sandbox-security-audit -f` | In-guest threat probe + k6 fuzzing (`DURATION=1m QPS=20 FORCE_FRESH=true`) | ❌ No |
| **Performance Benchmark** | `make test-benchmark` | `testkube run tw agent-sandbox-benchmark -f` | 60 QPS concurrency & cold/warm benchmark (`DURATION=30s QPS=60 SANDBOX_COUNT=1 CODE_VERSION=v1.2.1 FORCE_FRESH=true`) | ❌ No |
| **Sustained Load** | `make test-load` | `testkube run tw agent-sandbox-sustained-load -f` | Sustained 70 RPS multi-sandbox load test (`DURATION=2m QPS=100 SANDBOX_COUNT=3`) | ❌ No |

### 🔧 CLI Flag Reference (`bootstrap_cluster.sh`)

The CLI wrapper `bootstrap_cluster.sh` delegates all 8 reconciliation layers to `ansible-playbook`. It supports several operational modes:

| Flag | Mode | Description | Privilege (`sudo` / `BECOME`) Required |
| :--- | :--- | :--- | :--- |
| *(default)* | Full Reconcile | Converges all 8 layers: Stage 0 host prep (`[0/8]`) followed by Stages 1–8 (2-node cluster, gVisor, Ingress, monitoring, mogenius, Testkube, verification). | ⚠️ **Yes (`sudo` in Stage 0) if tools/Docker missing, `docker.service` inactive, or user not in `docker` group**; ❌ No (user space) once configured |
| `--dry-run` | Read-Only Audit | Runs `ansible-playbook --check --diff --tags preflight`. Evaluates host tools and sizing with **0 mutations**. | ❌ No (Read-only) |
| `--preflight-only` | Preflight Discovery | Audits and configures missing host OS toolchains, Docker service, and `docker` group membership (`[0/8]`), then exits before Minikube. | ⚠️ **Yes (`sudo` on Linux) if tools/Docker missing, `docker.service` inactive, or user not in `docker` group**; ❌ No once configured |
| `--upgrade-helm` | Force Helm Upgrade | Upgrades existing Helm releases (`monitoring`, `mogenius`, `testkube`) even if versions match. | ⚠️ Only if Stage 0 prerequisites are missing; ❌ No (user space) otherwise |
| `--configure-host-sysctl` | Host Kernel Tuning | Applies kernel inotify and open file descriptor limits to `/etc/sysctl.d` and PAM. | 🔑 **Yes (`sudo` always required)** |
| `--ci` | Low-Resource CI Mode | Sizes Minikube cluster for 2 vCPUs and 4,096 MB RAM (for GitHub Actions runners). | ⚠️ Only if Stage 0 prerequisites are missing; ❌ No otherwise |
| `--memory <MB>` | Custom Sizing | Sets custom primary node memory ceiling in MB (e.g. `--memory 6144`, min: 2048). | ⚠️ Only if Stage 0 prerequisites are missing; ❌ No otherwise |
| `-K`, `--ask-become-pass` | Ansible Become Pass | Explicitly forces Ansible `BECOME password:` prompt at launch (auto-enabled on Linux when `sudo` requires a password and `host_needs_privilege` is true). | 🔑 **Yes (`BECOME password:` prompt)** |
| `-h`, `--help` | Help Menu | Displays CLI options and usage examples. | ❌ No |

---

## 💻 Hardware & Sizing Requirements (All Systems)

The cluster topology deploys a 2-node cluster (`minikube` + `minikube-m02`):
* **Node 1 (`minikube`):** 8,192 MB RAM — Control plane, NGINX Ingress, `mogenius` Agent Sandbox Controller, Warm Pool (gVisor runsc sandboxes), Egress Broker, and Prometheus + Grafana.
* **Node 2 (`minikube-m02`):** ~4,096 MB RAM (tainted `dedicated=testkube:NoSchedule`) — Testkube API Server, MongoDB, NATS, MinIO, and `k6` load generators.

| Metric | Minimum Requirement | Recommended |
| :--- | :--- | :--- |
| **Host RAM** | **12 GB** free (16 GB total system RAM) | **16 GB – 32 GB** |
| **CPU Cores** | **4 vCPUs** | **6 – 8 vCPUs** |
| **Free Disk Space** | **40 GB** free | **60 GB+** (images take ~8.2 GB across both nodes) |

---

## 🍏 1. macOS Setup (Apple Silicon `arm64` & Intel `amd64`)

### A. Docker Desktop / OrbStack Configuration
Do **NOT** use default Docker Desktop settings (4 GB RAM / 2 CPUs), or Grafana and MongoDB will be `OOMKilled` (Exit Code 137).
1. Open **Docker Desktop Settings** -> **Resources**.
2. Set **CPUs:** `4+` cores.
3. Set **Memory:** `10 GB – 12 GB`.
4. Set **Virtual disk limit:** `40 GB+`.
5. Click **Apply & Restart**.

### B. Tooling Installation via Homebrew
```bash
# Install Minikube, Kubectl, Helm, Ansible, and Testkube CLI
brew install minikube kubectl helm ansible kubeshop/testkube/testkube
```

### C. Launch Cluster or Run Read-Only Dry-Run Audit
```bash
# 1. Non-mutating read-only audit (ansible-playbook --check --diff, 0 changes)
./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --dry-run

# 2. Host toolchain discovery & preflight check only
./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --preflight-only

# 3. Full declarative cluster reconciliation via Ansible
./k8s-agent-sandbox/scripts/bootstrap_cluster.sh
```

### D. Ingress Access on macOS
Because Docker Desktop on macOS runs inside a lightweight virtual machine, the Docker bridge network is not directly routable from your Mac's host browser. Use one of these methods:
* **Option 1 (Tunnel):** Run `minikube tunnel` in a separate terminal.
* **Option 2 (Port-Forward):**
  ```bash
  kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80
  ```
  Then access Grafana at `http://grafana.127.0.0.1.nip.io:8080` (or `http://localhost:8080`).

---

## 🐧 2. Linux Setup (Ubuntu / Debian / RHEL / Fedora)

Running natively on Linux provides the best performance because Docker interacts directly with the Linux kernel without virtualization overhead.

### A. Host Kernel Tweaks (`sysctl`) & Inotify Limits
Kubernetes multi-node clusters, containerd, Prometheus TSDB, and Testkube workflows (specifically `testkube-tw-toolkit` and k6 concurrency fuzzing) quickly exhaust default Linux inotify limits. On stock Linux installations, `fs.inotify.max_user_instances` defaults to only `128`, which causes Go's `fsnotify` file/log watchers to fail with `failed to create fsnotify watcher: too many open files`.

> [!NOTE]
> **Automatic In-Node Tuning (Zero Host Root Required):**
> You do **not** need root privileges on your host machine to run this platform. During cluster reconciliation (`make cluster`), Ansible automatically tunes `fs.inotify.max_user_instances=8192` and `fs.inotify.max_user_watches=1048576` directly inside the `minikube` and `minikube-m02` node containers.
>
> If you also want to permanently elevate your host system's kernel ceilings, apply:

```bash
# 1. Apply kernel parameters immediately
sudo sysctl -w fs.inotify.max_user_watches=1048576
sudo sysctl -w fs.inotify.max_user_instances=8192
sudo sysctl -w vm.max_map_count=262144
sudo sysctl -w net.ipv4.ip_forward=1

# 2. Persist across reboots
sudo tee /etc/sysctl.d/99-kubernetes-sandbox.conf <<EOF
fs.inotify.max_user_watches=1048576
fs.inotify.max_user_instances=8192
vm.max_map_count=262144
net.ipv4.ip_forward=1
EOF
sudo sysctl --system
```

### B. Base Prerequisites & Toolchains
To eliminate component installation toil on minimal or clean Linux distributions, ensure standard utilities (specifically `openssl` for Helm checksum validation, `jq`, `bzip2`, and `tar`) are installed. The bootstrapper (`make preflight`) checks and installs these automatically, but for manual preparation:

#### On Debian / Ubuntu:
```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates tar jq bzip2 openssl procps
```

#### On RHEL / Rocky Linux 9 & 10 / AlmaLinux / Fedora:
```bash
sudo dnf install -y epel-release 2>/dev/null || true
sudo dnf install -y --allowerasing curl ca-certificates tar jq bzip2 openssl procps-ng
```

### C. Install Docker Engine (Community Edition)

#### On Debian / Ubuntu (`apt` - `x86_64` & `aarch64`):
```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
```

#### On RHEL / Rocky Linux 9 / AlmaLinux 9 / Fedora (`dnf` / `yum` - `x86_64` & `aarch64`):
```bash
sudo dnf install -y dnf-plugins-core
# Docker CE repository natively supports both x86_64 and aarch64 (ARM64)
# On RHEL / CentOS / Rocky / Alma:
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || \
  sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo

# On Fedora (if using Fedora directly or DNF5):
# sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo

sudo dnf install -y --allowerasing docker-ce docker-ce-cli containerd.io
```

#### Post-Installation (All Linux Distros):
```bash
# Allow your user to run Docker without sudo
sudo usermod -aG docker $USER
newgrp docker
sudo systemctl enable --now docker
```

### C. Install CLIs (Architecture-Aware)

```bash
# Determine CPU architecture: 'amd64' or 'arm64'
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

# 1. Minikube (fail fast on HTTP errors with -fsSL)
curl -fsSLO "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${ARCH}"
sudo install "minikube-linux-${ARCH}" /usr/local/bin/minikube && rm "minikube-linux-${ARCH}"

# 2. Kubectl
K8S_RELEASE=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLO "https://dl.k8s.io/release/${K8S_RELEASE}/bin/linux/${ARCH}/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

# 3. Helm v3
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 4. Testkube CLI (Official Linux installer)
curl -sSLf https://get.testkube.io | bash

# 5. Ansible Core (auto-installed by bootstrap script if missing)
# Ubuntu/Debian: sudo apt-get install -y ansible-core
# RHEL/Rocky/Fedora: sudo dnf install -y ansible-core
```

### D. Launch Cluster or Run Read-Only Dry-Run Audit
```bash
# Non-mutating read-only audit (0 changes made)
./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --dry-run

# Host toolchain discovery & preflight check only
./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --preflight-only

# Full declarative cluster reconciliation
./k8s-agent-sandbox/scripts/bootstrap_cluster.sh
```

### E. Ingress Access on Linux
On Linux, Minikube networking operates differently from macOS:
* **Why `minikube tunnel` doesn't expose localhost on Linux:** On macOS, `minikube tunnel` contains a Darwin-specific loopback proxy that binds `127.0.0.1` to the VM. On Linux, `minikube tunnel` only routes ClusterIPs for `type: LoadBalancer` services. Because the Ingress controller uses `NodePort` / `hostPort`, `minikube tunnel` will show `services: []`.

Use one of these two methods to access Ingress on Linux:

#### Option 1: Port-Forward to `localhost` (Universal & matches macOS nip.io URLs)
Run this command in a separate terminal:
```bash
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80
```
Then access directly via `localhost`:
* **Grafana Dashboard:** `http://grafana.127.0.0.1.nip.io:8080` (user: `admin` | pass: `admin`)
* **Prometheus UI:** `http://prometheus.127.0.0.1.nip.io:8080`
* **Sandbox Ingress Router:** `http://sandbox.127.0.0.1.nip.io:8080`

*(Tip for VirtualBox / UTM: To access from your Mac host browser, add `--address 0.0.0.0` and set up VM Port Forwarding for port 8080).*

#### Option 2: Direct Minikube IP (Linux Native without port-forwarding)
The primary node IP is directly reachable on Linux's Docker bridge network:
```bash
MINIKUBE_IP=$(minikube ip)
echo "Minikube IP: ${MINIKUBE_IP}"
```
* **Grafana Dashboard:** `http://grafana.${MINIKUBE_IP}.nip.io` (user: `admin` | pass: `admin`)
* **Prometheus UI:** `http://prometheus.${MINIKUBE_IP}.nip.io`
* **Sandbox Ingress Router:** `http://sandbox.${MINIKUBE_IP}.nip.io`

### F. Performance Optimizations for Linux Virtual Machines (VirtualBox / UTM)
When running Linux inside a virtual machine on a macOS or Windows host, apply these proven engineering optimizations:

#### 1. Run Headless & Disable Graphical Desktop (`gdm3` / `lightdm`)
Desktop environments (GNOME Shell, lightdm, Wayland/X11, Mutter) consume **1.5 GB – 2 GB of RAM** and waste **15–30% of a CPU core** on display compositing. To maximize CPU & RAM for gVisor and k6 load tests:
```bash
# Isolate multi-user text console immediately:
sudo systemctl isolate multi-user.target

# Disable display manager service permanently across reboots:
sudo systemctl disable display-manager

# (If using lightdm):
sudo systemctl stop lightdm && sudo systemctl disable lightdm
```

#### 2. Prevent `NetworkManager-wait-online` Boot Hangs
If your VM hangs for 120 seconds during boot at *"A start job is running for Wait for Network to be Configured..."*, `disable` is insufficient because `network-online.target` pulls it back in. Mask both services to bypass the hang permanently:
```bash
sudo systemctl mask NetworkManager-wait-online.service
sudo systemctl mask systemd-networkd-wait-online.service
```

#### 3. Remote Ingress Access over Bridged / Local Wi-Fi Network
If your VM uses a **Bridged Adapter** on your local network:
1. Find your VM's LAN IP:
   ```bash
   hostname -I | awk '{print $1}'
   # Example: 192.168.1.75
   ```
2. Start the Ingress port-forward bound to `0.0.0.0`:
   ```bash
   # Unprivileged port 8080 (no sudo needed):
   kubectl -n ingress-nginx port-forward --address 0.0.0.0 svc/ingress-nginx-controller 8080:80

   # Or standard port 80 (explicitly passing user KUBECONFIG to sudo):
   sudo KUBECONFIG=$HOME/.kube/config kubectl -n ingress-nginx port-forward --address 0.0.0.0 svc/ingress-nginx-controller 80:80
   ```
3. On your host machine's `/etc/hosts` (`sudo nano /etc/hosts` on macOS/Linux), map the domains:
   ```text
   <VM-LAN-IP> grafana.local prometheus.local sandbox.local
   ```
4. Access directly from your host browser:
   * **Grafana:** `http://grafana.local:8080` (or `http://grafana.local` if on port 80)
   * **Prometheus:** `http://prometheus.local:8080`
   * **Sandbox Router:** `http://sandbox.local:8080`

#### 4. Satisfying the 8,192 MB Requirement & Fixing `RSRC_OVER_ALLOC_MEM`
If your Linux VM or host has 8 GB of assigned RAM, the Linux kernel reserves memory for BIOS and hardware page tables, leaving approximately ~7,957 MB total. If Minikube attempts to start requesting the full 8,192 MB, it aborts with:
```text
Exiting due to RSRC_OVER_ALLOC_MEM: Requested memory allocation 8192MB is more than your system limit 7957MB.
```

**Recommended: One-Liners to Add Memory to Satisfy the Full Requirement (10 GB – 12 GB):**
* **VirtualBox VM (run from your Mac / Host terminal):**
  Shut down the VM, then expand RAM to 10 GB (10,240 MB) or 12 GB (12,288 MB):
  ```bash
  VBoxManage modifyvm "<Your-VM-Name>" --memory 10240
  ```
  *(To find your exact VM name: `VBoxManage list vms`)*
* **Docker Desktop on macOS:**
  Set Docker VM memory to 10 GB or 12 GB via **Docker Desktop Settings -> Resources -> Memory**, or quit Docker Desktop and update settings:
  ```bash
  # Quit Docker Desktop first, then update settings (settings.json or settings-store.json):
  osascript -e 'quit app "Docker"' 2>/dev/null || true
  for cfg in "$HOME/Library/Group Containers/group.com.docker/settings-store.json" "$HOME/Library/Group Containers/group.com.docker/settings.json"; do
    [ -f "$cfg" ] && sed -i '' 's/"memoryMiB":[0-9]*/"memoryMiB":10240/' "$cfg" 2>/dev/null || true
  done
  open -a Docker
  ```
* **Windows WSL 2 (PowerShell):**
  Set WSL 2 memory limit to 12 GB:
  ```powershell
  Set-Content -Path $HOME\.wslconfig -Value "[wsl2]`nmemory=12GB" ; wsl --shutdown
  ```

**Alternative: If System RAM Cannot Be Increased on Host:**
* **Automatic Docker Daemon & Memory Clamping:** Stage 1 (`k8s-agent-sandbox/ansible/tasks/01_minikube_gvisor.yml`) inspects the Docker daemon's total memory ceiling directly (`docker info --format '{{.MemTotal}}'`) before falling back to host RAM (`ansible_facts['memtotal_mb']`), accurately detecting Docker Desktop VM ceilings on macOS as well as native Linux limits, and safely clamps primary node allocation (e.g. to `6144 MB`) whenever available memory is below 8,192 MB.
* **CLI Memory Flag:** You can pass `--memory <MB>` directly to the reconciler:
  ```bash
  ./k8s-agent-sandbox/scripts/bootstrap_cluster.sh --memory 6144
  ```
* **Pre-start Minikube Manually:**
  ```bash
  minikube start --driver=docker --container-runtime=containerd --cpus=4 --memory=6144
  ```
  *(Once running, `bootstrap_cluster.sh` will detect the active cluster and skip node recreation).*

---

## 🪟 3. Windows 10 / 11 Setup (via WSL 2 + Ubuntu)

You can run the entire Linux-based stack seamlessly on Windows using **Windows Subsystem for Linux 2 (WSL 2)** running **Ubuntu**.

### Step 1: Install WSL 2 & Ubuntu
Open **PowerShell as Administrator** and run:
```powershell
# Install WSL with Ubuntu
wsl --install -d Ubuntu

# If already installed, ensure WSL 2 is the default version
wsl --set-default-version 2
```
*Restart your computer if prompted by Windows.*

### Step 2: Configure WSL 2 Resources (`.wslconfig`)
By default, WSL 2 limits memory to 50% of system RAM. Configure sufficient resources for the 2-node cluster:
1. In Windows, open or create `C:\Users\<YourUsername>\.wslconfig` (or `%USERPROFILE%\.wslconfig`).
2. Add the following configuration:
   ```ini
   [wsl2]
   memory=12GB
   processors=4
   swap=4GB
   localhostForwarding=true
   ```
3. Restart WSL in PowerShell:
   ```powershell
   wsl --shutdown
   ```

### Step 3: Enable Systemd in Ubuntu WSL 2
Launch **Ubuntu** from the Windows Start menu or terminal, then enable `systemd`:
```bash
sudo tee /etc/wsl.conf <<EOF
[boot]
systemd=true
[network]
generateResolvConf=true
EOF
```
In PowerShell, restart WSL to activate systemd:
```powershell
wsl --shutdown
```
Reopen Ubuntu.

### Step 4: Install Native Docker Engine in Ubuntu WSL 2
Inside the Ubuntu WSL 2 shell:
```bash
# 1. Apply kernel sysctl tweaks
sudo sysctl -w fs.inotify.max_user_watches=1048576
sudo sysctl -w fs.inotify.max_user_instances=8192
sudo sysctl -w vm.max_map_count=262144
sudo sysctl -w net.ipv4.ip_forward=1

# 2. Install Docker CE
sudo apt-get update && sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# 3. Add user to docker group
sudo usermod -aG docker $USER
newgrp docker
sudo systemctl enable --now docker
```

*(Alternatively, if you use Docker Desktop for Windows, simply enable **"Use the WSL 2 based engine"** and turn on integration for your Ubuntu distribution under **Settings -> Resources -> WSL Integration**).*

### Step 5: Install CLIs in Ubuntu WSL 2
```bash
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

# Minikube
curl -LO "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${ARCH}"
sudo install "minikube-linux-${ARCH}" /usr/local/bin/minikube && rm "minikube-linux-${ARCH}"

# Kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

# Helm v3
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Testkube CLI
curl -sSLf https://get.testkube.io | bash

# Ansible Core (or auto-installed by bootstrap script)
sudo apt-get install -y ansible-core
```

### Step 6: Clone and Bootstrap
```bash
git clone https://github.com/akimchik/aws-lambda-microvms-workshop.git
cd aws-lambda-microvms-workshop
./k8s-agent-sandbox/scripts/bootstrap_cluster.sh
```

### Step 7: Access Dashboards from Windows Host Browser
WSL 2 automatically forwards networking to Windows:
* Retrieve the Minikube IP inside Ubuntu: `minikube ip`
* In your Windows Chrome or Edge browser, access:
  * **Grafana:** `http://grafana.<MINIKUBE_IP>.nip.io` (user: `admin` / pass: `admin`)
  * If using port-forwarding: run `kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80` inside WSL 2, and open `http://localhost:8080` in your Windows browser!

---

## 🧪 Validating the Platform (All Operating Systems)

Once `make cluster` (`bootstrap_cluster.sh`) finishes with `Cluster is 100% CONVERGED, HEALTHY & READY!` (having dynamically captured `minikube ip` and rendered the Testkube workflow templates in `k8s-agent-sandbox/testkube/templates/*.yaml.j2`), trigger the automated benchmarks and security probes on worker node `minikube-m02` via `make`:

```bash
# 1. Run the 60 QPS Ingress & Warm-Pool Latency Benchmark (with Freshness Gate, cgroup audit & multi-sandbox options)
make test-benchmark
# (Or override parameters: make test-benchmark DURATION=30s QPS=80 SANDBOX_COUNT=3 CODE_VERSION=v2.1.0 FORCE_FRESH=true)

# 2. Run the Continuous Red-Team Security Audit (gVisor T1-T6 Probe + k6 SSRF Fuzzer)
make test-security
# (Or override duration: make test-security DURATION=1m FORCE_FRESH=true)

# 3. Run the High-Throughput Sustained Load Benchmark (default 70 RPS / 150s, or multi-sandbox Scaled-Out run)
make test-load DURATION=2m QPS=100 SANDBOX_COUNT=3

# 4. View execution history
testkube get twe
```
