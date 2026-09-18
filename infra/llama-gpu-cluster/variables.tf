variable "cluster_id" {
  description = "ID of the Kubernetes cluster (cloud/provider-specific)"
  type        = string
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
  default     = "llama-gpu-cluster"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "namespace" {
  description = "Kubernetes namespace for LLaMA deployment"
  type        = string
  default     = "llama-api"
}

variable "docker_registry" {
  description = "Docker registry for LLaMA images"
  type        = string
  default     = "docker.io"
}

variable "docker_username" {
  description = "Docker registry username"
  type        = string
  sensitive   = true
}

variable "docker_password" {
  description = "Docker registry password"
  type        = string
  sensitive   = true
}

variable "gpu_instance_type" {
  description = "GPU instance type for nodes (cloud-specific; intent only in this module)"
  type        = string
  default     = "nvidia-a100-gpu"
}

variable "gpu_node_count" {
  description = "Intended number of GPU nodes"
  type        = number
  default     = 3
}

variable "cpu_instance_type" {
  description = "CPU instance type for nodes (cloud-specific; intent only in this module)"
  type        = string
  default     = "general-purpose"
}

variable "cpu_node_count" {
  description = "Intended number of CPU nodes"
  type        = number
  default     = 2
}

variable "argocd_admin_password" {
  description = "ArgoCD admin password (plaintext). Leave empty to auto-generate via random_password. Supply via TF_VAR_argocd_admin_password."
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_admin_password" {
  description = "Grafana admin password (plaintext). Leave empty to auto-generate via random_password. Supply via TF_VAR_grafana_admin_password."
  type        = string
  sensitive   = true
  default     = ""
}

variable "argocd_repo_url" {
  description = "Git repo URL for the ArgoCD Application (llama-api Helm chart path)"
  type        = string
  default     = "https://github.com/mindtdilly/Phoenix-orchestrator.git"
}

variable "solana_usdc_receive_address" {
  description = "Operator Solana USDC receive address (USDC on Solana only)"
  type        = string
  default     = "BH15GjnnDcXKWuVnxP9Gxrp2wDiEN7peGxPFGomTfv6u"
}
