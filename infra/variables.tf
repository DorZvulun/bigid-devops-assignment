variable "image_repository" {
  type    = string
  default = "ghcr.io/dorzvulun/whatsmyip"
}

variable "image_tag" {
  type = string
}

variable "kubeconfig" {
  type    = string
  default = "~/.kube/config"
}

variable "kube_context" {
  type    = string
  default = "k3d-bigid"
}

variable "namespace" {
  type    = string
  default = "staging"
}
