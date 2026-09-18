provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

# ---------------------------------------------------------------------------
# Secrets: no hardcoded ArgoCD bcrypt / Grafana plaintext
# Supply TF_VAR_argocd_admin_password / TF_VAR_grafana_admin_password, or
# leave empty to auto-generate (see sensitive outputs).
# ---------------------------------------------------------------------------

resource "random_password" "argocd_admin" {
  length           = 32
  special          = true
  override_special = "!@#%^&*()-_=+[]{}"
}

resource "random_password" "grafana_admin" {
  length           = 32
  special          = true
  override_special = "!@#%^&*()-_=+[]{}"
}

locals {
  argocd_admin_password  = var.argocd_admin_password != "" ? var.argocd_admin_password : random_password.argocd_admin.result
  grafana_admin_password = var.grafana_admin_password != "" ? var.grafana_admin_password : random_password.grafana_admin.result
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

  # Admin password is NOT hardcoded. Chart creates argocd-initial-admin-secret
  # on first install. After apply, rotate to the sensitive output:
  #   terraform output -raw argocd_admin_password
  #   argocd account update-password
  # Or pre-hash with htpasswd and set configs.secret via a future overlay.
  values = [
    yamlencode({
      server = {
        service = {
          type = "LoadBalancer"
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

  values = [
    yamlencode({
      grafana = {
        service = {
          type = "LoadBalancer"
        }
        adminPassword = local.grafana_admin_password
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
  set {
    name  = "env.SOLANA_USDC_RECEIVE_ADDRESS"
    value = var.solana_usdc_receive_address
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
        repoURL        = var.argocd_repo_url
        targetRevision = "HEAD"
        path           = "infra/llama-gpu-cluster/helm/llama-api"
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
