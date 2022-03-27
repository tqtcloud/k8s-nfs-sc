#/bin/bash
dir=/data/nfs_pro
network=192.168.8.0/24
#检查kube-apiserver 1.20 版本以上需要关闭 selfLink，修改支持kubeadm安装的kubernetes集群
grep feature-gates=RemoveSelfLink=false /etc/kubernetes/manifests/kube-apiserver.yaml &> /dev/null
statusid=`echo $?`
if [ "$statusid" -eq 0 ];then
   echo "kube-apiserver OK"
else
   sed -i '/\- kube-apiserver/a  - --feature-gates=RemoveSelfLink=false' /etc/kubernetes/manifests/kube-apiserver.yaml &&
   sed -i '/\- \-\-feature-gates=RemoveSelfLink=false/c\    - --feature-gates=RemoveSelfLink=false' /etc/kubernetes/manifests/kube-apiserver.yaml && 
   echo "kube-apiserver 10s updada" && 
   sleep 10 && 
   kubectl apply -f /etc/kubernetes/manifests/kube-apiserver.yaml &> /dev/null && 
   sleep 120 &&  kubectl delete pod -n kube-system `kubectl get pod -n kube-system  | grep -w  "kube-apiserver" | head -1 | awk '{print $1}'` --force  --grace-period=0
#   kubectl delete pod -n kube-system `kubectl get pod -n kube-system -o wide | grep  CrashLoopBackOff | awk  '{print $1}'` --force --grace-period=0
fi

rpm -ql nfs-utils &> /dev/null
id=`echo $?`
if [ "$id" -eq 0 ];  then
   echo "nfs-utils install OK!!!"
else
   yum install -y nfs-utils && systemctl enable  nfs &> /dev/null && systemctl start nfs
fi

mkdir -p $dir  &> /dev/null
echo  "$dir $network(rw,no_root_squash)" >> /etc/exports
exportfs -avr &> /dev/null && systemctl restart nfs

#配置NFS供应商
mkdir $HOME/nfs && cd $HOME/nfs
cat >> nfs-sc.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-provisioner
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: nfs-provisioner-runner
rules:
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "update"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "update", "patch"]
  - apiGroups: [""]
    resources: ["services", "endpoints"]
    verbs: ["get"]
  - apiGroups: ["extensions"]
    resources: ["podsecuritypolicies"]
    resourceNames: ["nfs-provisioner"]
    verbs: ["use"]


---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: run-nfs-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-provisioner
    namespace: default
roleRef:
  kind: ClusterRole
  name: nfs-provisioner-runner
  apiGroup: rbac.authorization.k8s.io
---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-nfs-provisioner
rules:
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-nfs-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-provisioner
    namespace: default
roleRef:
  kind: Role
  name: leader-locking-nfs-provisioner
  apiGroup: rbac.authorization.k8s.io
---
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: nfs
provisioner: example.com/nfs
---
kind: Deployment
apiVersion: apps/v1
metadata:
  name: nfs-provisioner
spec:
  selector:
    matchLabels:
       app: nfs-provisioner
  replicas: 1
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: nfs-provisioner
    spec:
      serviceAccount: nfs-provisioner
      containers:
        - name: nfs-provisioner
          image: tqtcloud/nfs-client-provisioner:v1
          volumeMounts:
            - name: nfs-client-root
              mountPath: /persistentvolumes
          env:
            - name: PROVISIONER_NAME
              value: example.com/nfs
            - name: NFS_SERVER
              value: 192.168.8.10
            - name: NFS_PATH
              value: /data/nfs_pro/
      volumes:
        - name: nfs-client-root
          nfs:
            server: 192.168.8.10
            path: /data/nfs_pro/ 
EOF

echo "nfs-cs.yaml OK!" && sleep 5

kubectl apply -f nfs-sc.yaml &> /dev/null  && sleep 60 && kubectl get pod -o wide -l app=nfs-provisioner
#配置NFS为默认供应商
kubectl patch storageclass nfs -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' &> /dev/null
