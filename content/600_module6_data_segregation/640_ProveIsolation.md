---
title : "Prove Data Isolation — Break It to Prove It"
weight : 640
---

## Overview

Security claims are only meaningful when tested. In this section you will attempt to **break** the data isolation from multiple angles and observe each attempt being denied. This "break it to prove it" approach demonstrates defense-in-depth:

1. **Kubernetes layer** — Try to access a PVC from a different namespace
2. **Storage layer** — Try to mount another model's volume directly via NFS
3. **Network layer** — Try to reach another model's data endpoint from within a pod

Each layer independently prevents unauthorized access, providing multiple safeguards.

---

##### Test 1: Attempt Cross-Namespace PVC Access (Kubernetes Layer)

Try to create a pod in the `model-finance` namespace that references the healthcare PVC. Kubernetes will deny this.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cd /home/participant/environment/eks/data-segregation

# Attempt to mount healthcare PVC from the finance namespace
cat <<'EOF' | kubectl apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: unauthorized-access-attempt
  namespace: model-finance
spec:
  containers:
  - name: attacker
    image: public.ecr.aws/amazonlinux/amazonlinux:2023
    command: ["sleep", "3600"]
    volumeMounts:
    - name: stolen-data
      mountPath: "/stolen"
  volumes:
  - name: stolen-data
    persistentVolumeClaim:
      claimName: healthcare-data-claim
EOF
:::

**Expected result — DENIED:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
Error from server (NotFound): persistentvolumeclaims "healthcare-data-claim" not found
:::

:::alert{header="Why it failed" type="info"}
PVCs are **namespace-scoped** resources in Kubernetes. The `healthcare-data-claim` PVC exists only in the `model-healthcare` namespace. A pod in `model-finance` cannot reference it — Kubernetes returns a "not found" error because the PVC simply doesn't exist in that namespace's scope.
:::

##### Test 2: Attempt Direct NFS Mount (Storage Layer)

Even if someone bypasses Kubernetes abstractions and tries to mount the NFS volume directly, ONTAP export policies block it.

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Get the NFS endpoint for the healthcare volume
HEALTH_NFS_PATH=$(kubectl get pv healthcare-data-pv -o jsonpath='{.spec.nfs.server}:{.spec.nfs.path}')
echo "Healthcare NFS path: $HEALTH_NFS_PATH"

# Attempt to mount healthcare data from within a finance namespace pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: direct-nfs-attempt
  namespace: model-finance
spec:
  containers:
  - name: attacker
    image: public.ecr.aws/amazonlinux/amazonlinux:2023
    command: ["sh", "-c", "mount -t nfs4 ${HEALTH_NFS_PATH} /mnt 2>&1; ls /mnt 2>&1; sleep 10"]
    securityContext:
      privileged: false
  restartPolicy: Never
EOF
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Wait for the pod to run and check the result
sleep 30
kubectl logs direct-nfs-attempt -n model-finance
:::

**Expected result — DENIED:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
mount.nfs4: access denied by server while mounting 198.19.x.x:/health_data
ls: cannot access '/mnt': No such file or directory
:::

:::alert{header="Why it failed" type="info"}
Even though the pod knows the NFS server IP and path, the **ONTAP export policy** on the `health_data` volume only allows access from pods in the `model-healthcare` namespace subnet. The export policy uses IP-based access rules that restrict NFS mounts to specific CIDR ranges matching each namespace's pod network.
:::

Clean up the test pod:

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl delete pod direct-nfs-attempt -n model-finance --ignore-not-found
:::

##### Test 3: Attempt Cross-Namespace Service Access (Network Layer)

Try to reach Model B's inference endpoint from Model A's namespace. With NetworkPolicies in place, this should be blocked.

First, let's apply NetworkPolicies that restrict cross-namespace traffic:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
cat network-policies.yaml
:::

:::code[]{language=yaml showLineNumbers=true showCopyAction=false}
# network-policies.yaml
---
# Deny all ingress to model-finance namespace except from within
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cross-namespace-ingress
  namespace: model-finance
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector: {}  # Only allow from same namespace
---
# Deny all ingress to model-healthcare namespace except from within
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cross-namespace-ingress
  namespace: model-healthcare
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector: {}  # Only allow from same namespace
---
# Deny egress from model-finance to model-healthcare
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cross-namespace-egress
  namespace: model-finance
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector: {}  # Allow within namespace
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system  # Allow DNS
    ports:
    - protocol: UDP
      port: 53
---
# Deny egress from model-healthcare to model-finance
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cross-namespace-egress
  namespace: model-healthcare
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector: {}  # Allow within namespace
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system  # Allow DNS
    ports:
    - protocol: UDP
      port: 53
:::

:::code[]{language=bash showLineNumbers=false showCopyAction=true}
kubectl apply -f network-policies.yaml
:::

Now attempt cross-namespace network access:

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# From a finance pod, try to reach the healthcare model's service
kubectl run network-test --rm -it --restart=Never \
  -n model-finance \
  --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \
  -- sh -c "curl -s --connect-timeout 5 http://model-b-healthcare-svc.model-healthcare.svc.cluster.local:8000/v1/models 2>&1 || echo 'CONNECTION BLOCKED'"
:::

**Expected result — BLOCKED:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
curl: (28) Connection timed out after 5000 milliseconds
CONNECTION BLOCKED
:::

:::alert{header="Why it failed" type="info"}
The **NetworkPolicy** blocks egress from `model-finance` to any namespace other than its own (and kube-system for DNS). Even though the DNS resolution might work, the actual TCP connection is dropped by the network policy enforcement. This prevents a compromised model pod from reaching another model's API endpoint.
:::

##### Test 4: Attempt to List Other Namespace's Resources (RBAC Layer)

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Try to list PVCs in model-healthcare namespace using the finance service account
kubectl auth can-i list persistentvolumeclaims \
  --namespace=model-healthcare \
  --as=system:serviceaccount:model-finance:finance-model-sa
:::

**Expected result — DENIED:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
no
:::

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Verify the finance SA CAN access its own namespace
kubectl auth can-i list persistentvolumeclaims \
  --namespace=model-finance \
  --as=system:serviceaccount:model-finance:finance-model-sa
:::

**Expected result — ALLOWED:**

:::code{showCopyAction=false showLineNumbers=false language=bash}
yes
:::

---

## Isolation Summary

| Layer | Test | Result | Enforcement |
|-------|------|--------|-------------|
| Kubernetes | Cross-namespace PVC reference | ❌ Denied | PVCs are namespace-scoped |
| Storage | Direct NFS mount attempt | ❌ Denied | ONTAP export policy (IP-based) |
| Network | Cross-namespace service access | ❌ Blocked | Kubernetes NetworkPolicy |
| RBAC | List other namespace resources | ❌ Denied | Kubernetes RBAC RoleBindings |

:::alert{header="Defense in Depth" type="info"}
No single layer is relied upon for security. Even if one layer is misconfigured or bypassed:
- **Without storage export policies**, Kubernetes namespace isolation still prevents PVC access
- **Without NetworkPolicies**, ONTAP export policies still block NFS mounts from unauthorized IPs
- **Without RBAC**, the PVC namespace scoping still prevents cross-namespace volume references

This layered approach is essential for enterprise data governance compliance (HIPAA, SOX, GDPR).
:::

---

##### Clean Up Test Resources

:::code[]{language=bash showLineNumbers=true showCopyAction=true}
# Remove test pods (if any remain)
kubectl delete pod unauthorized-access-attempt -n model-finance --ignore-not-found
kubectl delete pod direct-nfs-attempt -n model-finance --ignore-not-found
:::

---

### Summary

You have proven that data isolation between models is enforced at **four independent layers**: Kubernetes namespace scoping, ONTAP storage export policies, Kubernetes NetworkPolicies, and RBAC. A breach of any single layer does not compromise the isolation — all four must be bypassed simultaneously to access another model's data.

This defense-in-depth approach gives enterprises confidence that deploying multiple AI models against different data domains maintains strict data governance boundaries, even in a shared Kubernetes cluster.

