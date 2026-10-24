# Rocky Linux 10 Kubernetes 一键部署脚本

使用 `kubeadm + containerd + Flannel`，在 3 台 Rocky Linux 10 虚拟机上部署一个单控制平面、两个工作节点的 Kubernetes 集群。脚本从 master 执行，通过 SSH 安装和配置三台机器。

> 适用于学习和本地实验环境。该方案只有一个 control plane，不具备控制平面高可用能力。

## 环境要求

- 三台全新 Rocky Linux 10 x86_64 虚拟机，网络互通：
  - `192.168.79.10`：master
  - `192.168.79.20`：node1
  - `192.168.79.30`：node2
- 三台机器均可通过 SSH 以 `root` 登录；示例密码为 `1`。
- 在 master 上运行脚本，并预先安装 `openssh-clients`、`coreutils`、`sshpass`。
- 三台机器都能访问 Rocky Linux、Docker CE、Kubernetes 软件源，以及 Kubernetes 镜像仓库。
- 建议每台至少 2 CPU、2 GiB 内存，并确保虚拟机有足够磁盘空间。

## 部署

将 `deploy-k8s-rocky10.sh` 放到 master 的 `/root` 目录，然后在 master 上运行：

```bash
dnf install -y openssh-clients coreutils
# sshpass 在部分 Rocky 仓库中需要 EPEL：
dnf install -y epel-release
dnf install -y sshpass

chmod +x /root/deploy-k8s-rocky10.sh
SSH_PASSWORD='1' /root/deploy-k8s-rocky10.sh
```

脚本默认使用以上三台 IP、Kubernetes `v1.36`、Pod 网段 `10.244.0.0/16`。运行时会关闭 swap、配置内核网络参数、安装并启动 containerd 和 Kubernetes 组件、配置 firewalld、初始化 master、安装 Flannel，并将两个 worker 加入集群。

可通过环境变量调整配置，例如：

```bash
SSH_PASSWORD='1' K8S_MINOR=v1.36 POD_CIDR=10.244.0.0/16 \
  /root/deploy-k8s-rocky10.sh
```

## 验证

部署结束后，在 master 上运行：

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

等待三个节点都显示 `Ready`，系统 Pod 进入 `Running`。新加入的节点可能需要一两分钟才会变为 `Ready`。

## 安全提醒

- 示例密码 `1` 非常弱，只应在隔离的本地虚拟网络中使用；不要将 SSH 暴露到公网。
- 不要把密码、`admin.conf`/kubeconfig、SSH 私钥、join token 或其他凭据提交到 GitHub。
- 脚本通过 SSH 密码登录。长期使用建议改为 SSH 公钥认证，并移除脚本中的密码输入方式。
- 上传前检查仓库文件，确保没有加入 `kubeconfig`、密钥或日志等敏感文件。

## 常见问题

### `sshpass: command not found`

在 master 安装 `sshpass`。Rocky Linux 上可先安装并启用 EPEL，再安装 `sshpass`。

### `POD_CIDR: 未绑定的变量`

请确认使用的是最新版本脚本；旧版本没有把 Pod 网段传入远程安装步骤。

### 节点暂时是 `NotReady`

新节点刚加入时可等待一两分钟，再运行：

```bash
kubectl get nodes -w
kubectl -n kube-flannel get pods -o wide
```

如果仍未恢复，检查 `kubectl describe node <节点名>` 和对应节点上的 kubelet/containerd 状态。

## 组件与版本

- Kubernetes：`pkgs.k8s.io` 的指定 stable minor 仓库，默认 `v1.36`
- 容器运行时：containerd（不安装 Docker Engine）
- Pod 网络：Flannel
- 初始化工具：kubeadm

脚本会安装所选 minor 仓库中当前可用的补丁版本。部署前请查看 Kubernetes 官方文档和版本支持策略。