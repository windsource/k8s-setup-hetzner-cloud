# Install Kubernetes on a Hetzner cloud server

This setup uses terraform to create a single instance Hetzner cloud server and
installs Kubernetes using kubeadm on it.

## Features

* Dashboard
* Creation of local kubectl config '~/.kube/config-<master ip>`

## Setup

Create a file `terraform.tfvars` with

```text
hcloud_token = "<your Hetzner API token>"
ssh_keys = ["<your Hetzner cloud ssh key to use for the server>"]
private_ssh_key_path = "<path to local ssh key>"
```

Then call 

```bash
terraform init
```

## Deploy

```bash
terraform apply
```

## Destroy

```bash
terraform destroy
```

