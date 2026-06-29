---
title : "Deploy Multiple Models with Isolated Data Access"
weight : 730
# hidden : true
---

## Overview

In this section you will deploy **two different AI models** in separate Kubernetes namespaces, each with access to only its designated data volume. This demonstrates enterprise-grade data segregation where:

- **Model A (Mistral-7B)** — Deployed in namespace `model-finance`, can only access the `finance_data` volume
- **Model B (Phi-2)** — Deployed in namespace `model-healthcare`, can only access the `health_data` volume

Neither model can access the other's data, enforced at both the Kubernetes layer (namespace isolation, RBAC) and the storage layer (ONTAP export policies).

---

##### Step 1: Create Isolated Namespaces

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Create isolated namespaces for each model
kubectl create namespace model-finance
kubectl create namespace model-healthcare

# Label namespaces for identification
kubectl label namespace model-finance purpose=finance-model data-domain=finance
kubectl label namespace model-healthcare purpose=healthcare-model data-domain=healthcare
:::

##### Step 2: Create RBAC Policies for Namespace Isolation

We'll create RBAC rules that prevent cross-namespace resource access. This ensures that pods in `model-finance` cannot reference PVCs or secrets in `model-healthcare`, and vice versa.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/data-segregation
cat rbac-isolation.yaml
:::

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
# rbac-isolation.yaml
---
# ServiceAccount for finance model - restricted to model-finance namespace
apiVersion: v1
kind: ServiceAccount
metadata:
  name: finance-model-sa
  namespace: model-finance
---
# ServiceAccount for healthcare model - restricted to model-healthcare namespace
apiVersion: v1
kind: ServiceAccount
metadata:
  name: healthcare-model-sa
  namespace: model-healthcare
---
# Role: finance model can only access PVCs in its own namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: finance-data-access
  namespace: model-finance
rules:
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: finance-data-access-binding
  namespace: model-finance
subjects:
- kind: ServiceAccount
  name: finance-model-sa
  namespace: model-finance
roleRef:
  kind: Role
  name: finance-data-access
  apiGroup: rbac.authorization.k8s.io
---
# Role: healthcare model can only access PVCs in its own namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: healthcare-data-access
  namespace: model-healthcare
rules:
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: healthcare-data-access-binding
  namespace: model-healthcare
subjects:
- kind: ServiceAccount
  name: healthcare-model-sa
  namespace: model-healthcare
roleRef:
  kind: Role
  name: healthcare-data-access
  apiGroup: rbac.authorization.k8s.io
:::

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl apply -f rbac-isolation.yaml
:::

##### Step 3: Create Isolated PVCs for Each Model

Each model gets its own PVC backed by its designated replicated volume. The StorageClass uses Trident to mount the specific ONTAP volume.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cat finance-pvc.yaml
:::

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
# finance-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: finance-data-claim
  namespace: model-finance
spec:
  accessModes:
    - ReadOnlyMany
  storageClassName: ontap-nas-segregated
  resources:
    requests:
      storage: 50Gi
  selector:
    matchLabels:
      data-domain: finance
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cat healthcare-pvc.yaml
:::

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
# healthcare-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: healthcare-data-claim
  namespace: model-healthcare
spec:
  accessModes:
    - ReadOnlyMany
  storageClassName: ontap-nas-segregated
  resources:
    requests:
      storage: 50Gi
  selector:
    matchLabels:
      data-domain: healthcare
:::

Create the segregated StorageClass and PVCs:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Apply the segregated storage class (uses export policy restrictions)
kubectl apply -f ontap-storage-class-segregated.yaml

# Create PVs that point to the specific replicated volumes
kubectl apply -f finance-pv.yaml
kubectl apply -f healthcare-pv.yaml

# Create the PVCs
kubectl apply -f finance-pvc.yaml
kubectl apply -f healthcare-pvc.yaml
:::

Verify PVCs are bound:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
kubectl get pvc -n model-finance
kubectl get pvc -n model-healthcare
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
NAME                 STATUS   VOLUME              CAPACITY   ACCESS MODES   STORAGECLASS
finance-data-claim   Bound    finance-data-pv     50Gi       ROX            ontap-nas-segregated

NAME                    STATUS   VOLUME                CAPACITY   ACCESS MODES   STORAGECLASS
healthcare-data-claim   Bound    healthcare-data-pv    50Gi       ROX            ontap-nas-segregated
:::

:::alert{header="ReadOnlyMany (ROX) access mode" type="info"}
Notice both PVCs use `ReadOnlyMany` access mode. Since these are SnapMirror destination volumes (DP type), they are inherently read-only at the ONTAP level. This is perfect for inference workloads — the models read the data but cannot modify it. The source of truth remains on-prem.
:::

##### Step 4: Deploy Model A — Mistral-7B (Finance Domain)

Deploy the Mistral-7B model in the `model-finance` namespace with access only to the finance data volume.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cat model-a-finance-deployment.yaml
:::

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
# model-a-finance-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: model-a-mistral-finance
  namespace: model-finance
  labels:
    app: model-a-finance
    data-domain: finance
spec:
  replicas: 1
  selector:
    matchLabels:
      app: model-a-finance
  template:
    metadata:
      labels:
        app: model-a-finance
        data-domain: finance
    spec:
      serviceAccountName: finance-model-sa
      nodeSelector:
        node.kubernetes.io/instance-type: inf2.xlarge
      tolerations:
      - key: "aws.amazon.com/neuron"
        operator: "Exists"
        effect: "NoSchedule"
      containers:
      - name: inference-server
        image: public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.9.1-neuronx-py311-sdk2.26.1-ubuntu22.04
        command: ["vllm", "serve"]
        args:
        - /model-dir/Mistral-7B-Instruct-v0.3
        - --served-model-name=mistral-7b-finance
        - --tensor-parallel-size=2
        - --max-model-len=4096
        - --max-num-seqs=4
        - --device=neuron
        resources:
          requests:
            cpu: "2"
            memory: 8Gi
            aws.amazon.com/neuroncore: 2
          limits:
            aws.amazon.com/neuroncore: 2
        env:
        - name: NEURON_COMPILED_ARTIFACTS
          value: /model-dir/Mistral-7B-Instruct-v0.3
        volumeMounts:
        - name: model-storage
          mountPath: "/model-dir"
          readOnly: true
        - name: domain-data
          mountPath: "/data"               # <<<< Finance data ONLY
          readOnly: true
        ports:
        - containerPort: 8000
          name: http
      volumes:
      - name: model-storage
        persistentVolumeClaim:
          claimName: ontap-model-claim     # Existing model PVC from Module 2
      - name: domain-data
        persistentVolumeClaim:
          claimName: finance-data-claim    # <<<< ONLY finance data
---
apiVersion: v1
kind: Service
metadata:
  name: model-a-finance-svc
  namespace: model-finance
spec:
  selector:
    app: model-a-finance
  ports:
  - port: 8000
    targetPort: 8000
    name: http
  type: ClusterIP
:::

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl apply -f model-a-finance-deployment.yaml
:::

##### Step 5: Deploy Model B — Phi-2 (Healthcare Domain)

Deploy a different model (Phi-2) in the `model-healthcare` namespace with access only to the healthcare data volume.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cat model-b-healthcare-deployment.yaml
:::

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
# model-b-healthcare-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: model-b-phi2-healthcare
  namespace: model-healthcare
  labels:
    app: model-b-healthcare
    data-domain: healthcare
spec:
  replicas: 1
  selector:
    matchLabels:
      app: model-b-healthcare
  template:
    metadata:
      labels:
        app: model-b-healthcare
        data-domain: healthcare
    spec:
      serviceAccountName: healthcare-model-sa
      nodeSelector:
        node.kubernetes.io/instance-type: inf2.xlarge
      tolerations:
      - key: "aws.amazon.com/neuron"
        operator: "Exists"
        effect: "NoSchedule"
      containers:
      - name: inference-server
        image: public.ecr.aws/neuron/pytorch-inference-vllm-neuronx:0.9.1-neuronx-py311-sdk2.26.1-ubuntu22.04
        command: ["vllm", "serve"]
        args:
        - /model-dir/Phi-2
        - --served-model-name=phi2-healthcare
        - --tensor-parallel-size=2
        - --max-model-len=2048
        - --max-num-seqs=4
        - --device=neuron
        resources:
          requests:
            cpu: "2"
            memory: 8Gi
            aws.amazon.com/neuroncore: 2
          limits:
            aws.amazon.com/neuroncore: 2
        env:
        - name: NEURON_COMPILED_ARTIFACTS
          value: /model-dir/Phi-2
        volumeMounts:
        - name: model-storage
          mountPath: "/model-dir"
          readOnly: true
        - name: domain-data
          mountPath: "/data"               # <<<< Healthcare data ONLY
          readOnly: true
        ports:
        - containerPort: 8000
          name: http
      volumes:
      - name: model-storage
        persistentVolumeClaim:
          claimName: healthcare-model-claim  # Separate model PVC for Phi-2
      - name: domain-data
        persistentVolumeClaim:
          claimName: healthcare-data-claim   # <<<< ONLY healthcare data
---
apiVersion: v1
kind: Service
metadata:
  name: model-b-healthcare-svc
  namespace: model-healthcare
spec:
  selector:
    app: model-b-healthcare
  ports:
  - port: 8000
    targetPort: 8000
    name: http
  type: ClusterIP
:::

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl apply -f model-b-healthcare-deployment.yaml
:::

##### Step 6: Verify Both Models Are Running

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
echo "=== Finance Model (Mistral-7B) ==="
kubectl get pods -n model-finance

echo ""
echo "=== Healthcare Model (Phi-2) ==="
kubectl get pods -n model-healthcare
:::

Wait for both pods to reach `Running` status (this may take 5-7 minutes as Inferentia nodes scale up):

:::code{showCopyAction=false showLineNumbers=false language=bash}
=== Finance Model (Mistral-7B) ===
NAME                                       READY   STATUS    RESTARTS   AGE
model-a-mistral-finance-7b4d8f9c6-x2k9m   1/1     Running   0          5m

=== Healthcare Model (Phi-2) ===
NAME                                        READY   STATUS    RESTARTS   AGE
model-b-phi2-healthcare-5c8a7e3d1-p7n4w    1/1     Running   0          5m
:::

##### Step 7: Verify Data Access Within Each Model

Confirm that each model can access its designated data:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Verify Model A can see finance data
echo "=== Model A (Finance) - Data Access ==="
kubectl exec -n model-finance deployment/model-a-mistral-finance -- ls /data/
echo ""

# Verify Model B can see healthcare data
echo "=== Model B (Healthcare) - Data Access ==="
kubectl exec -n model-healthcare deployment/model-b-phi2-healthcare -- ls /data/
:::

Expected output:

:::code{showCopyAction=false showLineNumbers=false language=bash}
=== Model A (Finance) - Data Access ===
transactions
risk_models
compliance

=== Model B (Healthcare) - Data Access ===
patient_records
imaging
research
:::

:::alert{header="Key observation" type="info"}
Each model sees **only** its designated domain data:
- Model A sees `transactions`, `risk_models`, `compliance` (finance domain)
- Model B sees `patient_records`, `imaging`, `research` (healthcare domain)

Neither model has visibility into the other's data, and neither can see the retail data that remained on-prem.
:::

---

### Summary

You have deployed two different AI models (Mistral-7B and Phi-2) in isolated Kubernetes namespaces, each with access restricted to only its designated data volume. In the next section, you will **prove** this isolation by attempting cross-model data access and observing it being denied.

