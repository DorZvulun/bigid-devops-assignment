provider "kubernetes" {
  config_path    = pathexpand(var.kubeconfig)
  config_context = var.kube_context
}

provider "helm" {
  kubernetes = {
    config_path    = pathexpand(var.kubeconfig)
    config_context = var.kube_context
  }
}

resource "kubernetes_namespace_v1" "ns" {
  metadata {
    name = var.namespace
  }
}

resource "helm_release" "whatsmyip" {
  name      = "whatsmyip"
  chart     = "${path.module}/../charts/whatsmyip"
  namespace = kubernetes_namespace_v1.ns.metadata[0].name
  atomic    = true
  wait      = true
  timeout   = 180

  set = [
    { name = "image.repository", value = var.image_repository },
    { name = "image.tag", value = var.image_tag },
  ]
}
