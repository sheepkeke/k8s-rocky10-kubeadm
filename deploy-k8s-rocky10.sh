#!/usr/bin/env bash
# One-control-plane / two-worker kubeadm setup for Rocky Linux 10.
# Run from a Linux/macOS/WSL management host with SSH access and sudo on all nodes.
set -Eeuo pipefail

MASTER="${MASTER:-192.168.79.10}"
WORKERS=("${WORKER1:-192.168.79.20}" "${WORKER2:-192.168.79.30}")
SSH_USER="${SSH_USER:-root}"
SSH_PASSWORD="${SSH_PASSWORD:?请先设置 SSH_PASSWORD 环境变量，例如 SSH_PASSWORD=1}"
K8S_MINOR="${K8S_MINOR:-v1.36}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SSH_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)

if ! command -v ssh >/dev/null || ! command -v base64 >/dev/null || ! command -v sshpass >/dev/null; then
  echo "管理机需要安装 ssh、base64 和 sshpass。" >&2; exit 1
fi

remote() { SSHPASS="$SSH_PASSWORD" sshpass -e ssh "${SSH_OPTS[@]}" "${SSH_USER}@$1" "${@:2}"; }

# This payload runs as root on each target host.
read -r -d '' REMOTE_SETUP <<'REMOTE_EOF' || true
set -Eeuo pipefail
NODE_IP="$1"
K8S_MINOR="$2"
ROLE="$3"
POD_CIDR="$4"

if [[ "$(. /etc/os-release; echo "$ID")" != "rocky" ]] || [[ "$(. /etc/os-release; echo "${VERSION_ID%%.*}")" != "10" ]]; then
  echo "预期 Rocky Linux 10；检测到：$(. /etc/os-release; echo "$PRETTY_NAME")" >&2; exit 1
fi

# Give each node a stable, readable hostname.
case "$ROLE" in
  master) HOSTNAME_WANT=k8s-master ;;
  worker1) HOSTNAME_WANT=k8s-node1 ;;
  worker2) HOSTNAME_WANT=k8s-node2 ;;
esac
hostnamectl set-hostname "$HOSTNAME_WANT"

# Resolve peers consistently even when the lab has no DNS.
grep -vE '(^|[[:space:]])(k8s-master|k8s-node1|k8s-node2)([[:space:]]|$)' /etc/hosts > /tmp/hosts.k8s
cat >>/tmp/hosts.k8s <<'HOSTS_EOF'
192.168.79.10 k8s-master
192.168.79.20 k8s-node1
192.168.79.30 k8s-node2
HOSTS_EOF
cat /tmp/hosts.k8s >/etc/hosts

# Kubernetes requires swap off. Persist this across reboot.
swapoff -a
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

modprobe overlay
modprobe br_netfilter
cat >/etc/modules-load.d/k8s.conf <<'MODULES_EOF'
overlay
br_netfilter
MODULES_EOF
cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'SYSCTL_EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
SYSCTL_EOF
sysctl --system >/dev/null

# Keep firewalld enabled and allow the required control-plane / Flannel traffic.
dnf install -y dnf-plugins-core >/dev/null
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >/dev/null
dnf install -y containerd.io curl >/dev/null
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl enable --now containerd

cat >/etc/yum.repos.d/kubernetes.repo <<REPO_EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
REPO_EOF
dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
systemctl enable --now kubelet

if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=10250/tcp >/dev/null
  firewall-cmd --permanent --add-port=8472/udp >/dev/null
  firewall-cmd --permanent --add-port=30000-32767/tcp >/dev/null
  firewall-cmd --permanent --add-port=30000-32767/udp >/dev/null
  if [[ "$ROLE" == master ]]; then
    firewall-cmd --permanent --add-port=6443/tcp >/dev/null
    firewall-cmd --permanent --add-port=2379-2380/tcp >/dev/null
    firewall-cmd --permanent --add-port=10257/tcp >/dev/null
    firewall-cmd --permanent --add-port=10259/tcp >/dev/null
  fi
  firewall-cmd --reload >/dev/null
fi

if [[ "$ROLE" == master && ! -f /etc/kubernetes/admin.conf ]]; then
  VERSION="$(kubeadm version -o short)"
  kubeadm config images pull --kubernetes-version "$VERSION" --cri-socket unix:///run/containerd/containerd.sock
  kubeadm init \
    --apiserver-advertise-address="$NODE_IP" \
    --control-plane-endpoint="$NODE_IP:6443" \
    --pod-network-cidr="$POD_CIDR" \
    --cri-socket=unix:///run/containerd/containerd.sock \
    --kubernetes-version="$VERSION"
fi
REMOTE_EOF

encode() { printf '%s' "$1" | base64 | tr -d '\n'; }
setup_node() {
  local ip="$1" role="$2" payload
  payload="$(encode "$REMOTE_SETUP")"
  remote "$ip" "printf '%s' '$payload' | base64 -d | bash -s -- '$ip' '$K8S_MINOR' '$role' '$POD_CIDR'"
}

for ip in "$MASTER" "${WORKERS[@]}"; do
  echo "==> 检查 SSH：$SSH_USER@$ip"
  remote "$ip" 'id -u' >/dev/null 2>&1 || {
    echo "无法通过 SSH 登录 $SSH_USER@$ip，请确认 root 密码登录已开启。" >&2; exit 1;
  }
done

setup_node "$MASTER" master

# Install Flannel once the API server is ready.
remote "$MASTER" "bash -lc 'mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config && chmod 600 /root/.kube/config && kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml'"

JOIN_CMD="$(remote "$MASTER" "kubeadm token create --print-join-command --ttl 2h")"
JOIN_CMD="${JOIN_CMD//$'\r'/}"
for i in 0 1; do
  ip="${WORKERS[$i]}"
  role="worker$((i+1))"
  setup_node "$ip" "$role"
  printf '%s\n' "$JOIN_CMD" | SSHPASS="$SSH_PASSWORD" sshpass -e ssh "${SSH_OPTS[@]}" "${SSH_USER}@$ip" 'bash -s'
done

echo "==> 集群已初始化。节点状态："
remote "$MASTER" "bash -lc 'kubectl get nodes -o wide'"
echo "管理机拷贝 kubeconfig 的命令："
echo "  SSH_PASSWORD=1 sshpass -e scp -o PreferredAuthentications=password -o PubkeyAuthentication=no ${SSH_USER}@${MASTER}:/etc/kubernetes/admin.conf ./kubeconfig"
echo "版本仓库默认使用 ${K8S_MINOR}；如需指定其他受支持 minor，可运行：K8S_MINOR=v1.xx bash $0"