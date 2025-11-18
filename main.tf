module "talos" {
  source  = "hcloud-talos/talos/hcloud"
  version = "2.20.2"

  # обязательные входы
  hcloud_token            = var.hcloud_token
  cluster_name            = var.cluster_name
  datacenter_name         = var.datacenter_name
  cilium_version          = "1.16.2"
  firewall_use_current_ip = true
  hcloud_ccm_version      = "1.28.0"

  talos_version      = "v1.11.0"
  kubernetes_version = "1.30.3"
  disable_arm        = true

  control_plane_count          = 1
  control_plane_server_type    = "cx23"
  control_plane_allow_schedule = true
  # worker_nodes = [
  #     {
  #       type  = "cx23"
  #       labels = {
  #         "node.kubernetes.io/instance-type" = "cx22"
  #       }
  #     }
  #   ]
}

output "talosconfig" {
  value     = module.talos.talosconfig
  sensitive = true
}

output "kubeconfig" {
  value     = module.talos.kubeconfig
  sensitive = true
}
