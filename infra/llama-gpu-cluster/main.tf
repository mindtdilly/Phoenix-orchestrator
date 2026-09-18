# Terraform sketch: Kubernetes + GPU LLaMA stack (beopen.ai oriented)
# WARNING: See README.md — not apply-ready. kubernetes_node_pool is non-standard.

terraform {
  required_version = ">= 1.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.20"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.10"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

variable "cluster_id" {
  description = "ID of the Kubernetes cluster on beopen.ai"
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
  description = "GPU instance type for nodes"
  type        = string
  default     = "nvidia-a100-gpu"
}

variable "gpu_node_count" {
  description = "Number of GPU nodes in the cluster"
  type        = number
  default     = 3
}

variable "cpu_node_count" {
  description = "Number of CPU nodes in the cluster"
  type        = number
  default     = 2
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

resource "random_id" "cluster_suffix" {
  byte_length = 4
}

resource "kubernetes_namespace" "llama_namespace" {
  metadata {
    name = var.namespace
    labels = {
      environment = var.environment
      app         = "llama-api"
    }
  }
}

resource "kubernetes_namespace" "istio_system" {
  metadata {
    name = "istio-system"
    labels = {
      istio-injection = "disabled"
    }
  }
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "kubernetes_namespace" "tekton_pipelines" {
  metadata {
    name = "tekton-pipelines"
  }
}

# NOTE: kubernetes_node_pool is NOT provided by hashicorp/kubernetes.
# Left as documentation of intent; replace with your cloud node-pool resource.
#
# resource "kubernetes_node_pool" "gpu_pool" { ... }
# resource "kubernetes_node_pool" "cpu_pool" { ... }

resource "kubernetes_secret" "docker_registry" {
  metadata {
    name      = "docker-registry-secret"
    namespace = kubernetes_namespace.llama_namespace.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (var.docker_registry) = {
          username = var.docker_username
          password = var.docker_password
          auth     = base64encode("${var.docker_username}:${var.docker_password}")
        }
      }
    })
  }
}

resource "helm_release" "nvidia_gpu_operator" {
  name             = "nvidia-gpu-operator"
  repository       = "https://nvidia.github.io/gpu-operator"
  chart            = "gpu-operator"
  version          = "23.9.0"
  namespace        = "gpu-operator"
  create_namespace = true

  set {
    name  = "driver.enabled"
    value = "true"
  }
  set {
    name  = "toolkit.enabled"
    value = "true"
  }
  set {
    name  = "devicePlugin.enabled"
    value = "true"
  }
}

resource "helm_release" "istio_base" {
  name       = "istio-base"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  version    = "1.21.0"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name

  set {
    name  = "global.istioNamespace"
    value = "istio-system"
  }
}

resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = "1.21.0"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  depends_on = [helm_release.istio_base]

  set {
    name  = "global.istioNamespace"
    value = "istio-system"
  }
}

resource "helm_release" "istio_gateway" {
  name       = "istio-gateway"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = "1.21.0"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  depends_on = [helm_release.istiod]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "5.51.6"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  # SECURITY: replace admin password before real use
  values = [
    yamlencode({
      server = {
        service = {
          type = "LoadBalancer"
        }
      }
      configs = {
        secret = {
          # bcrypt for "admin" — REPLACE
          argocdServerAdminPassword = "$2a$10$rRyBsGSHK6.uc8fntPwVIuLVHgsAhAX7TcdrqW/XfUQtaodWiIbKi"
        }
      }
    })
  ]
}

resource "helm_release" "tekton_pipelines" {
  name       = "tekton-pipelines"
  repository = "https://storage.googleapis.com/tekton-releases/charts"
  chart      = "tekton-pipelines"
  version    = "0.56.0"
  namespace  = kubernetes_namespace.tekton_pipelines.metadata[0].name
}

resource "helm_release" "prometheus" {
  name             = "prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "57.0.0"
  namespace        = "monitoring"
  create_namespace = true

  # SECURITY: grafana adminPassword is placeholder
  values = [
    yamlencode({
      grafana = {
        service = {
          type = "LoadBalancer"
        }
        adminPassword = "CHANGE_ME"
      }
      prometheus = {
        prometheusSpec = {
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                resources = {
                  requests = {
                    storage = "100Gi"
                  }
                }
              }
            }
          }
        }
      }
    })
  ]
}

resource "helm_release" "llama_api" {
  name      = "llama-api"
  chart     = "./helm/llama-api"
  namespace = kubernetes_namespace.llama_namespace.metadata[0].name

  depends_on = [
    kubernetes_secret.docker_registry,
    helm_release.nvidia_gpu_operator,
    helm_release.istio_gateway
  ]

  set {
    name  = "replicaCount"
    value = "3"
  }
  set {
    name  = "image.repository"
    value = "${var.docker_registry}/${var.docker_username}/llama-api"
  }
  set {
    name  = "image.tag"
    value = "latest"
  }
  set {
    name  = "resources.limits.nvidia\\.com/gpu"
    value = "1"
  }
  set {
    name  = "resources.limits.memory"
    value = "32Gi"
  }
  set {
    name  = "resources.limits.cpu"
    value = "8"
  }
  set {
    name  = "resources.requests.memory"
    value = "16Gi"
  }
  set {
    name  = "resources.requests.cpu"
    value = "4"
  }
  set {
    name  = "nodeSelector.gpu"
    value = "true"
  }
  set {
    name  = "tolerations[0].key"
    value = "nvidia.com/gpu"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "tolerations[0].value"
    value = "true"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
  set {
    name  = "imagePullSecrets[0].name"
    value = kubernetes_secret.docker_registry.metadata[0].name
  }
  set {
    name  = "service.type"
    value = "ClusterIP"
  }
  set {
    name  = "service.port"
    value = "8000"
  }
  set {
    name  = "ingress.enabled"
    value = "true"
  }
  set {
    name  = "ingress.className"
    value = "istio"
  }
  set {
    name  = "autoscaling.enabled"
    value = "true"
  }
  set {
    name  = "autoscaling.minReplicas"
    value = "2"
  }
  set {
    name  = "autoscaling.maxReplicas"
    value = "10"
  }
  set {
    name  = "autoscaling.targetCPUUtilizationPercentage"
    value = "70"
  }
  set {
    name  = "environment"
    value = var.environment
  }
}

resource "kubernetes_manifest" "argocd_app" {
  depends_on = [helm_release.argocd]

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "llama-api-app"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/your-org/llama-api-mesh.git"
        targetRevision = "HEAD"
        path           = "helm/llama-api"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.namespace
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  }
}

resource "kubernetes_manifest" "tekton_pipeline" {
  depends_on = [helm_release.tekton_pipelines]

  manifest = {
    apiVersion = "tekton.dev/v1beta1"
    kind       = "Pipeline"
    metadata = {
      name      = "llama-api-pipeline"
      namespace = "tekton-pipelines"
    }
    spec = {
      params = [
        {
          name        = "repo-url"
          type        = "string"
          description = "Git repository URL"
        },
        {
          name        = "image-name"
          type        = "string"
          description = "Docker image name"
        }
      ]
      workspaces = [
        {
          name        = "shared-data"
          description = "Shared workspace for pipeline"
        }
      ]
      tasks = [
        {
          name = "fetch-source"
          taskRef = {
            name = "git-clone"
          }
          workspaces = [
            {
              name      = "output"
              workspace = "shared-data"
            }
          ]
          params = [
            {
              name  = "url"
              value = "$(params.repo-url)"
            }
          ]
        },
        {
          name = "build-push"
          taskRef = {
            name = "buildah"
          }
          workspaces = [
            {
              name      = "source"
              workspace = "shared-data"
            }
          ]
          params = [
            {
              name  = "IMAGE"
              value = "$(params.image-name)"
            }
          ]
        }
      ]
    }
  }
}

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
  description = "Service endpoints"
  value = {
    argocd_server = "kubectl get svc argocd-server -n argocd"
    grafana       = "kubectl get svc prometheus-grafana -n monitoring"
    llama_api     = "kubectl get svc llama-api -n ${var.namespace}"
  }
}

output "gpu_nodes" {
  description = "GPU node pool intent (resource not applied via this provider)"
  value = {
    intended_count = var.gpu_node_count
    instance_type  = var.gpu_instance_type
    note           = "Provision node pools via cloud/beopen provider — see README"
  }
}

output "monitoring_info" {
  description = "Monitoring stack information"
  value = {
    prometheus_url = "http://prometheus-server.monitoring.svc.cluster.local:9090"
    grafana_url    = "http://prometheus-grafana.monitoring.svc.cluster.local:3000"
    grafana_admin  = "set via values — do not use default admin"
  }
}
