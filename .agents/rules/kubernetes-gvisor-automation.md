# Kubernetes, Minikube, gVisor & Local Ansible Automation Guardrails

## 1. No False-Positive Deployment Verification
- **Workload-Specific Verification is Mandatory**: When deploying a custom runtime (e.g. `RuntimeClass: gvisor`), NEVER claim the cluster or deployment is healthy by checking only auxiliary platform services (Ingress, Prometheus, Grafana). Platform services use standard `runc` and can succeed while the target runtime is broken.
- **Active Canary Probe**: Every bootstrap or reconciliation suite MUST spin up a live canary pod utilizing the target runtime (`runtimeClassName: gvisor`), assert `condition=Ready`, and verify workload warm-pool pods before declaring convergence.
- **Explicit Test Boundaries**: Never tell the user that an orchestration workflow is "tested" or "ready to merge" if testing only covered shell syntax (`bash -n`), argument parsing, or mocked unit tests. Explicitly state whether the test was a mock unit test or an end-to-end live cluster run.

## 2. Guest vs. Host Environment Separation (Minikube / kicbase)
- **Zero Guest-Tool Assumptions**: Never assume guest nodes/containers (`kicbase`, Docker-in-Docker, or remote VMs) inherit host tools (`bzip2`, `zstd`, `python3`).
- **Host Unpack & Transfer Pattern**: Download and decompress archives on the host (where decompression tools and Python are verified), then copy raw ELF binaries and companion directories into the guest using `minikube cp` or `crictl`.
- **gVisor Companion Directory Invariant**: Google gVisor (`runsc`) requires its companion directory `/usr/bin/gvisor-bin/` containing `gvisor_sentry` located next to `runsc`. Always deploy `/usr/bin/runsc`, `/usr/bin/containerd-shim-runsc-v1`, and `/usr/bin/gvisor-bin/` together with `chmod -R a+rx`.

## 3. Local Ansible Privilege Escalation Guardrails
- **Guard `become` Behind Audits**: Never run `become: true` tasks unconditionally on localhost. Check if tools, packages, or configuration files are already present before invoking package managers or modifying `/etc/`.
- **Sudo Credential Priming**: CLI wrappers invoking `ansible-playbook` on local hosts must check `sudo -n true` and execute `sudo -v` in the interactive terminal before Ansible runs, preventing non-interactive `sudo: a password is required` failures.
