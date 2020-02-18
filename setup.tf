# Set the variable value in *.tfvars file
# or using -var="hcloud_token=..." CLI option
variable "hcloud_token" {}

variable "master-node-name" {
  type    = "string"
  default = "k8s-master"
}

variable "email" {}

variable "ssh_keys" {
  type = list(string)
}

variable "private_ssh_key_path" {}


# Configure the Hetzner Cloud Provider
provider "hcloud" {
  version = "~> 1.14"
  token = "${var.hcloud_token}"
}

resource "hcloud_network" "k8s-network" {
  name = "k8s-network"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "k8s-subnet" {
  network_id = "${hcloud_network.k8s-network.id}"
  type = "server"
  network_zone = "eu-central"
  ip_range   = "10.0.1.0/24"
}

resource "hcloud_server" "k8s-master" {
  name = "${var.master-node-name}"
  image = "ubuntu-18.04"
  server_type = "cx21"
  ssh_keys = "${var.ssh_keys}"
}

resource "hcloud_server_network" "k8s-server-network" {
  server_id = "${hcloud_server.k8s-master.id}"
  network_id = "${hcloud_network.k8s-network.id}"

  connection {
    host = "${hcloud_server.k8s-master.ipv4_address}"
    user = "root"
    private_key = "${file("${var.private_ssh_key_path}")}"
  }

  provisioner "file" {
    source      = "install-master.sh"
    destination = "/root/install-master.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "bash install-master.sh ${hcloud_server.k8s-master.ipv4_address} ${var.hcloud_token} ${var.email} ${hcloud_server_network.k8s-server-network.ip} ${hcloud_network.k8s-network.id}"
    ]
  }

  provisioner "local-exec" {
    command = <<EOT
      export TARGET=$HOME/.kube/config-${hcloud_server.k8s-master.ipv4_address}
      scp -o StrictHostKeyChecking=no root@${hcloud_server.k8s-master.ipv4_address}:.kube/config $TARGET
      kubectl config --kubeconfig=$TARGET set-cluster kubernetes --server=https://${hcloud_server.k8s-master.ipv4_address}:6443
      sed -i 's/kubernetes-admin@kubernetes/k8s@${hcloud_server.k8s-master.ipv4_address}/g' $TARGET
      echo "Use 'kubectl --kubeconfig=$TARGET' or 'export KUBECONFIG=$TARGET'"
    EOT
  }
}

output "ip" {
  value = "${hcloud_server.k8s-master.ipv4_address}"
}

output "private_ip" {
  value = "${hcloud_server_network.k8s-server-network.ip}"
}