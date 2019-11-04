#!/bin/bash

function stopAptService {
  systemctl stop apt-daily.service
  systemctl kill --kill-who=all apt-daily.service

  # wait until `apt-get updated` has been killed
  while ! (systemctl list-units --all apt-daily.service | egrep -q '(dead|failed)')
  do
    sleep 1;
  done
}


# Install docker according to instructions in https://kubernetes.io/docs/setup/production-environment/container-runtimes/
function installDocker {
  # Install Docker CE
  ## Set up the repository:
  ### Install packages to allow apt to use a repository over HTTPS
  apt-get update && apt-get install -y apt-transport-https ca-certificates curl software-properties-common

  ### Add Docker’s official GPG key
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -

  ### Add Docker apt repository.
  add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) \
    stable"

  ## Install Docker CE.
  apt-get update && apt-get install -y docker-ce=18.06.2~ce~3-0~ubuntu

  # Setup daemon.
  cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

  mkdir -p /etc/systemd/system/docker.service.d

  # Restart docker.
  systemctl daemon-reload
  systemctl restart docker
}

function installAndRunKubeadm {
  # Installing kubeadm, kubelet and kubectl
  sudo apt-get update
  sudo apt-get install -y apt-transport-https curl
  curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
  cat <<EOF >kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
  sudo mv kubernetes.list /etc/apt/sources.list.d/
  sudo apt-get update
  sudo apt-get install -y kubelet kubeadm kubectl
  sudo apt-mark hold kubelet kubeadm kubectl

  # Creating a single control-plane cluster with kubeadm
  # see https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
  sudo sysctl net.bridge.bridge-nf-call-iptables=1
  # sudo kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-cert-extra-sans="$1"
  sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-cert-extra-sans="$1"

  # Then prepare the use of kubectl
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

  # Now we need to install a pod network and choose flannel:
  kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/2140ac876ef134e0ed5af15c65e414cf26827915/Documentation/kube-flannel.yml

  # For a single node setup we need to make sure that pods are allowed to be scheduled on the master node.
  kubectl taint nodes --all node-role.kubernetes.io/master-
}


function installDashboard {
  # Install dashboard (see https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/)
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-beta4/aio/deploy/recommended.yaml

  # On local machine start a proxy with 'kubectl proxy'
  # Now you can access the dashboard on
  # http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/

  # Now we need to create a user and token as described in https://github.com/kubernetes/dashboard/blob/master/docs/user/access-control/creating-sample-user.md:
  cat <<EOF >dashboard-adminuser.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF
  kubectl apply -f dashboard-adminuser.yaml

  # Get the token
  kubectl -n kubernetes-dashboard describe secret $(kubectl -n kubernetes-dashboard get secret | grep admin-user | awk '{print $1}')
}

# exit when any command fails
set -e

if [ -z "$1" ]
  then
    echo "usage: bash install-master <public ip>"
    exit 1
fi

# Print every command
set -x

stopAptService

installDocker

installAndRunKubeadm

installDashboard


