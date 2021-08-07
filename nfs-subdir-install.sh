#/bin/bash
dir=/data/nfs_pro
network=192.168.8.0/24
nfs_server=192.168.8.10
namespace=sc

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

kubectl create  namespace  sc

#配置NFS供应商
mkdir $HOME/nfs && cd $HOME/nfs
cat >> nfs-sc.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-provisioner
  namespace: $namespace
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: nfs-provisioner-runner
  namespace: $namespace
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
  namespace: $namespace
subjects:
  - kind: ServiceAccount
    name: nfs-provisioner
    namespace: $namespace
roleRef:
  kind: ClusterRole
  name: nfs-provisioner-runner
  apiGroup: rbac.authorization.k8s.io
---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-nfs-provisioner
  namespace: $namespace
rules:
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-nfs-provisioner
  namespace: $namespace
subjects:
  - kind: ServiceAccount
    name: nfs-provisioner
    namespace: $namespace
roleRef:
  kind: Role
  name: leader-locking-nfs-provisioner
  apiGroup: rbac.authorization.k8s.io
---
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: nfs
  namespace: $namespace
  annotations:
    storageclass.kubernetes.io/is-default-class: "true" 
provisioner: example.com/nfs
reclaimPolicy: Retain
---
kind: Deployment
apiVersion: apps/v1
metadata:
  name: nfs-provisioner
  namespace: $namespace
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
          image: tqtcloud/nfs-subdir-external-provisioner:v4.0.0
#	      image: registry.cn-beijing.aliyuncs.com/mydlq/nfs-subdir-external-provisioner:v4.0.0
          imagePullPolicy: IfNotPresent
          volumeMounts:
            - name: nfs-client-root
              mountPath: /persistentvolumes
          env:
            - name: PROVISIONER_NAME
              value: example.com/nfs
            - name: NFS_SERVER
              value: $nfs_server
            - name: NFS_PATH
              value: /data/nfs_pro
      volumes:
        - name: nfs-client-root
          nfs:
            server: $nfs_server
            path: /data/nfs_pro
EOF

echo "nfs-cs.yaml OK!" && sleep 5

kubectl apply -f nfs-sc.yaml &> /dev/null  && sleep 60 && kubectl -n sc get pod -o wide -l app=nfs-provisioner
