output "cluster_info" {
  description = "Cluster information"
  value = {
    cluster_id   = var.cluster_id
    cluster_name = var.cluster_name
    environment  = var.environment
    namespace    = kubernetes_namespace.llama_namespace.metadata[0].name
  }
}

output "service_endpoints" {
  description = "Service endpoints (kubectl hints)"
  value = {
    argocd_server = "kubectl get svc argocd-server -n argocd"
    grafana       = "kubectl get svc prometheus-grafana -n monitoring"
    llama_api     = "kubectl get svc llama-api -n ${var.namespace}"
  }
}

output "gpu_node_pool_intent" {
  description = "GPU node pool intent — provision via cloud provider, not hashicorp/kubernetes"
  value       = local.gpu_node_pool_intent
}

output "cpu_node_pool_intent" {
  description = "CPU node pool intent — provision via cloud provider, not hashicorp/kubernetes"
  value       = local.cpu_node_pool_intent
}

output "monitoring_info" {
  description = "Monitoring stack information"
  value = {
    prometheus_url = "http://prometheus-server.monitoring.svc.cluster.local:9090"
    grafana_url    = "http://prometheus-grafana.monitoring.svc.cluster.local:3000"
  }
}

output "argocd_admin_password" {
  description = "ArgoCD admin password (sensitive). Retrieve with: terraform output -raw argocd_admin_password"
  value       = local.argocd_admin_password
  sensitive   = true
}

output "grafana_admin_password" {
  description = "Grafana admin password (sensitive). Retrieve with: terraform output -raw grafana_admin_password"
  value       = local.grafana_admin_password
  sensitive   = true
}

output "solana_usdc_receive_address" {
  description = "Operator Solana USDC receive address wired into llama-api. WARNING: wrong network = lost funds (USDC on Solana only)."
  value       = var.solana_usdc_receive_address
}

output "argocd_repo_url" {
  description = "Git repo URL used by the ArgoCD Application"
  value       = var.argocd_repo_url
}
