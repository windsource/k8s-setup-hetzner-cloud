# Set the variable value in *.tfvars file
# or using -var="hcloud_token=..." CLI option
variable "hcloud_token" {}

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

# Create a server
resource "hcloud_server" "k8s-master" {
  name = "k8s-master"
  image = "ubuntu-18.04"
  server_type = "cx21"
  ssh_keys = "${var.ssh_keys}"

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
      "bash install-master.sh ${hcloud_server.k8s-master.ipv4_address} ${var.hcloud_token} ${var.email}"
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