# LLaMA GPU Kubernetes cluster (Terraform sketch)

Source: operator paste into Hashing chat (2026-09-18), hardened 2026-09-18.
**Do not `terraform apply` until remaining blockers below are resolved.**

## Layout

| File | Purpose |
|------|---------|
| `versions.tf` | Terraform + provider requirements |
| `variables.tf` | Inputs (secrets sensitive; Solana USDC address) |
| `outputs.tf` | Cluster info, node-pool intent, sensitive passwords, Solana address |
| `node_pools.tf` | GPU/CPU pool **intent** (labels/taints) — no invalid resources |
| `main.tf` | Namespaces, secrets, Helm releases, ArgoCD/Tekton manifests |
| `helm/llama-api/` | Stub chart matching `helm_release.llama_api` settings |

## Fixed (was known issues)

- ~~`kubernetes_node_pool` invalid resource~~ — removed; intent documented in `node_pools.tf` + outputs (cloud-agnostic; no invented beopen provider).
- ~~Hardcoded ArgoCD bcrypt for password `admin`~~ — removed. Use `TF_VAR_argocd_admin_password` or auto `random_password` (sensitive output). Chart leaves initial admin secret; rotate post-apply with `argocd account update-password`.
- ~~Grafana plaintext `admin` / `CHANGE_ME`~~ — uses `TF_VAR_grafana_admin_password` or auto `random_password` (sensitive output), passed into Helm values.
- ~~Placeholder ArgoCD `repoURL` (`your-org/llama-api-mesh`)~~ — `var.argocd_repo_url` (default `https://github.com/mindtdilly/Phoenix-orchestrator.git`).
- ~~Missing `./helm/llama-api` chart~~ — stub chart added (Deployment, Service, HPA, Ingress; GPU resources, tolerations, imagePullSecrets, port 8000).

## Solana USDC receive address

Non-sensitive variable + output + Helm env:

```hcl
variable "solana_usdc_receive_address" {
  description = "Operator Solana USDC receive address (USDC on Solana only)"
  type        = string
  default     = "BH15GjnnDcXKWuVnxP9Gxrp2wDiEN7peGxPFGomTfv6u"
}
```

Wired into llama-api as env `SOLANA_USDC_RECEIVE_ADDRESS`.

**WARNING: Wrong network = lost funds.** This address is for **USDC on Solana only**. Do not send Ethereum/Base/other-chain USDC or SOL-native assets expecting USDC credit.

## Secrets / TF_VAR_*

Never commit real passwords or Docker credentials.

```bash
export TF_VAR_docker_username="..."
export TF_VAR_docker_password="..."
export TF_VAR_argocd_admin_password="..."   # optional; auto-generated if unset
export TF_VAR_grafana_admin_password="..."  # optional; auto-generated if unset
export TF_VAR_cluster_id="..."

terraform output -raw argocd_admin_password
terraform output -raw grafana_admin_password
```

Docker registry credentials remain `sensitive = true` variables only.

## Remaining apply blockers

1. **kubeconfig** — providers expect `~/.kube/config` pointed at a live cluster.
2. **Real cloud node pools** — GPU/CPU pools must be created with your cloud Terraform resources (EKS/GKE/AKS/etc.) matching labels `gpu=true` and taint `nvidia.com/gpu=true:NoSchedule`. This module only documents intent.
3. **Supply secrets** — set `TF_VAR_docker_*` (required) and optionally admin passwords before apply.
4. **ArgoCD admin bcrypt at install** — plaintext password is generated/output but not bcrypt-hashed into Helm; use initial secret then rotate, or overlay a bcrypt hash into `configs.secret.argocdServerAdminPassword`.
5. **Image exists** — `${docker_registry}/${docker_username}/llama-api:latest` must be pullable.
6. **CRDs timing** — `kubernetes_manifest` for ArgoCD Application / Tekton Pipeline needs those CRDs installed (Helm releases first; may need `-target` or two-phase apply).

## Intended stack

Namespaces + Helm: NVIDIA GPU Operator, Istio, ArgoCD, Tekton, kube-prometheus-stack, llama-api (GPU-tolerated, Solana USDC env).
