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
* **Self-Contained gVisor Binary Installation:** In `k8s-agent-sandbox/scripts/bootstrap_cluster.sh`, the script downloads the official Google gVisor release archive (`gvisor.tar.bz2`, containing `runsc` and `containerd-shim-runsc-v1`) matching the detected CPU architecture (`x86_64` or `aarch64`) directly from Google Cloud Storage (`storage.googleapis.com/gvisor/releases/release/latest/${ARCH}`). This avoids reliance on APT package managers, third-party OpenSUSE/Kubic repositories, or expired GPG keys inside the Minikube node.

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
# Install Minikube, Kubectl, Helm, and Testkube CLI
brew install minikube kubectl helm kubeshop/testkube/testkube
```

### C. Launch Cluster
```bash
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

### A. Host Kernel Tweaks (`sysctl`)
Kubernetes multi-node clusters and Prometheus file monitors quickly exhaust default Linux inotify limits. Apply these settings before starting:

```bash
# 1. Apply kernel parameters immediately
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=512
sudo sysctl -w vm.max_map_count=262144
sudo sysctl -w net.ipv4.ip_forward=1

# 2. Persist across reboots
sudo tee /etc/sysctl.d/99-kubernetes-sandbox.conf <<EOF
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
vm.max_map_count=262144
net.ipv4.ip_forward=1
EOF
sudo sysctl --system
```

### B. Install Docker Engine (Community Edition)

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
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || \
  sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
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

# 1. Minikube
curl -LO "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${ARCH}"
sudo install "minikube-linux-${ARCH}" /usr/local/bin/minikube && rm "minikube-linux-${ARCH}"

# 2. Kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

# 3. Helm v3
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# 4. Testkube CLI (Official Linux installer)
curl -sSLf https://get.testkube.io | bash
```

### D. Launch Cluster
```bash
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
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=512
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

Once `bootstrap_cluster.sh` finishes with `Cluster is 100% CONVERGED, HEALTHY & READY!`, trigger the automated benchmarks and security probes on worker node `minikube-m02`:

```bash
# 1. Run the 60 QPS Ingress & Warm-Pool Latency Benchmark
testkube run tw agent-sandbox-benchmark -f

# 2. Run the Continuous Red-Team Security Audit (gVisor T1-T6 Probe + k6 SSRF Fuzzer)
testkube run tw agent-sandbox-security-audit -f

# 3. Run the High-Throughput Sustained Load Benchmark (70 RPS / 10,500 requests)
testkube run tw agent-sandbox-sustained-load -f

# 4. View execution history
testkube get twe
```
