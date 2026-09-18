# LLaMA GPU Kubernetes cluster (Terraform sketch)

Source: operator paste into Hashing chat (2026-09-18). **Do not `terraform apply` as-is.**

## Known issues
- `kubernetes_node_pool` is **not** a standard `hashicorp/kubernetes` resource. Node pools must come from your cloud/provider module (or beopen.ai provider), not this file as written.
- ArgoCD values embed a bcrypt hash for password `admin`; Grafana `adminPassword` was plaintext in the paste — this sketch uses `CHANGE_ME`.
- ArgoCD Application `repoURL` is a placeholder: `https://github.com/your-org/llama-api-mesh.git`.
- Chart path `./helm/llama-api` must exist beside this module.
- Docker registry credentials are Terraform variables (`sensitive = true`) — supply via env/CI, never commit.

## Intended stack
Namespaces + Helm: NVIDIA GPU Operator, Istio, ArgoCD, Tekton, kube-prometheus-stack, llama-api (GPU-tolerated).
