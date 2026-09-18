# ---------------------------------------------------------------------------
# Node pool INTENT (cloud-agnostic documentation)
# ---------------------------------------------------------------------------
# hashicorp/kubernetes does NOT provide a kubernetes_node_pool resource.
# Do not invent a beopen provider here. Provision GPU/CPU pools with your
# cloud's Terraform resources (EKS managed node group, GKE node pool, AKS
# agent pool, etc.), then apply labels/taints to match the llama-api chart.
#
# Intended GPU pool:
#   - count:         var.gpu_node_count
#   - instance type: var.gpu_instance_type
#   - labels:        gpu = "true"
#   - taints:        nvidia.com/gpu=true:NoSchedule
#
# Intended CPU pool:
#   - count:         var.cpu_node_count
#   - instance type: var.cpu_instance_type
#   - labels:        (none required by this module)
#   - taints:        (none)
#
# Example (illustrative — replace with your cloud provider resources):
#
#   resource "SOME_CLOUD_node_pool" "gpu" {
#     cluster_id    = var.cluster_id
#     name          = "gpu-pool"
#     node_count    = var.gpu_node_count
#     instance_type = var.gpu_instance_type
#     labels        = { gpu = "true" }
#     taint {
#       key    = "nvidia.com/gpu"
#       value  = "true"
#       effect = "NoSchedule"
#     }
#   }
#
#   resource "SOME_CLOUD_node_pool" "cpu" {
#     cluster_id    = var.cluster_id
#     name          = "cpu-pool"
#     node_count    = var.cpu_node_count
#     instance_type = var.cpu_instance_type
#   }

locals {
  gpu_node_pool_intent = {
    count         = var.gpu_node_count
    instance_type = var.gpu_instance_type
    labels        = { gpu = "true" }
    taints = [
      {
        key    = "nvidia.com/gpu"
        value  = "true"
        effect = "NoSchedule"
      }
    ]
  }

  cpu_node_pool_intent = {
    count         = var.cpu_node_count
    instance_type = var.cpu_instance_type
    labels        = {}
    taints        = []
  }
}
