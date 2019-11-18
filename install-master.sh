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


function prepareHetznerCloudControllerManager {
  mkdir -p /etc/systemd/system/kubelet.service.d
  cat > /etc/systemd/system/kubelet.service.d/20-hetzner-cloud.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--cloud-provider=external"
EOF
}


function setupHetznerCloudControllerManager {
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: hcloud
  namespace: kube-system
stringData:
  token: "$HCLOUD_TOKEN"
EOF

  kubectl apply -f https://raw.githubusercontent.com/hetznercloud/hcloud-cloud-controller-manager/master/deploy/v1.5.0.yaml
}


function installAndRunKubeadm {
  #prepareHetznerCloudControllerManager

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
  sudo kubeadm init --kubernetes-version=v1.16.1 --pod-network-cidr=10.244.0.0/16 --apiserver-cert-extra-sans="$PUBLIC_IP"

  # Then prepare the use of kubectl
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

  # Now we need to install a pod network and choose flannel:
  kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/2140ac876ef134e0ed5af15c65e414cf26827915/Documentation/kube-flannel.yml

  # # As Kubernetes with the external cloud provider flag activated will add a taint to uninitialized nodes, 
  # # the cluster critical pods need to be patched to tolerate these
  # kubectl -n kube-system patch daemonset kube-flannel-ds-amd64 --type json -p '[{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"node.cloudprovider.kubernetes.io/uninitialized","value":"true","effect":"NoSchedule"}}]'
  # kubectl -n kube-system patch deployment coredns --type json -p '[{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"node.cloudprovider.kubernetes.io/uninitialized","value":"true","effect":"NoSchedule"}}]'

  # setupHetznerCloudControllerManager

  # For a single node setup we need to make sure that pods are allowed to be scheduled on the master node.
  kubectl taint nodes --all node-role.kubernetes.io/master-
}


function installDashboard {
  # Install dashboard (see https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/)
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.0-beta6/aio/deploy/recommended.yaml

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


function setupHetznerCloudContainerStorageInterface {
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: hcloud-csi
  namespace: kube-system
stringData:
  token: "$HCLOUD_TOKEN"
EOF

  kubectl apply -f https://raw.githubusercontent.com/kubernetes/csi-api/release-1.14/pkg/crd/manifests/csidriver.yaml
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/csi-api/release-1.14/pkg/crd/manifests/csinodeinfo.yaml
  kubectl apply -f https://raw.githubusercontent.com/hetznercloud/csi-driver/master/deploy/kubernetes/hcloud-csi.yml
}


function installHelm {
  curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get > install-helm.sh
  chmod u+x install-helm.sh
  ./install-helm.sh

  kubectl -n kube-system create serviceaccount tiller
  kubectl create clusterrolebinding tiller --clusterrole cluster-admin --serviceaccount=kube-system:tiller
  helm init --service-account tiller
  kubectl wait --for=condition=available deployment/tiller-deploy -n kube-system --timeout=300s
  kubectl wait --for=condition=Ready pod --all -n kube-system --timeout=300s
}


function installNginxIngressControllerAndCertManager {
  # Install nginx ingress controller
  helm install --name ingress --namespace ingress --set rbac.create=true,controller.kind=DaemonSet,controller.service.type=ClusterIP,controller.hostNetwork=true stable/nginx-ingress

  # Create a namespace to run cert-manager in
  kubectl create namespace cert-manager

  # Install the CustomResourceDefinitions and cert-manager itself
  kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v0.11.0/cert-manager.yaml
  kubectl wait --for=condition=Ready pod --all -n cert-manager --timeout=300s
  kubectl wait --for=condition=Ready pod --all -n kube-system --timeout=300s
  
  # Cluster issuer for staging (higher rate limits)
  cat << EOF > ClusterIssuerStaging.yml
apiVersion: cert-manager.io/v1alpha2
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    email: $EMAIL
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

  while ! (kubectl apply -f ClusterIssuerStaging.yml)
  do
    sleep 1;
  done  
  rm ClusterIssuerStaging.yml

  # Cluster issuer for production (strict rate limits)
  cat << EOF | kubectl create -f -
apiVersion: cert-manager.io/v1alpha2
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $EMAIL
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
}


# exit when any command fails
set -e

if [[ $# -ne 3 ]]; then
    echo "usage: bash install-master <public ip> <hcloud token> <email>"
    exit 1
fi

PUBLIC_IP=$1
HCLOUD_TOKEN=$2
EMAIL=$3

# Print every command
set -x

stopAptService

installDocker

installAndRunKubeadm

setupHetznerCloudContainerStorageInterface

installDashboard

installHelm

installNginxIngressControllerAndCertManager
