variable "hcloud_token" {
  type        = string
  description = "Hetzner Cloud API token"
}

variable "cluster_name" {
  type    = string
  default = "test-vault"
}

variable "region" {
  type    = string
  default = "hel1"
}

variable "datacenter_name" {
  type    = string
  default = "hel1-dc2"
}

