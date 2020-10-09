# k8s中部署kata

## 安装containerd
```bash
./k8s/containerd/containerd.sh
```

## 安装kubeadm及kubernetes
```bash
./k8s/kubeadm/kubeadm.sh
```

## 部署kata-deploy
```bash
kubectl apply -k k8s/rbac/base/
kubectl apply -k k8s/main/overlays/k8s/
kubectl apply -f k8s/runtime/
```
