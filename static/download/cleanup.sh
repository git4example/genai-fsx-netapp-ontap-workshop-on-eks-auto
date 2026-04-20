#! /bin/bash

rm -vf ${HOME}/.aws/credentials
aws sts get-caller-identity

export CLUSTER_NAME=eksworkshop
echo $AWS_REGION
echo $CLUSTER_NAME
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

rm trident-csi-driver.json

cd /home/participant/environment/eks/genai

helm uninstall -n kube-system neuron-helm-chart

kubectl delete -f mistral-ontap.yaml
kubectl delete -f open-webui.yaml
kubectl delete -f inferentia_nodepool.yaml
kubectl get nodepool,ec2nodeclass

kubectl get ing

# --- Ordered ONTAP resource teardown ---
cd /home/participant/environment/eks/FSxONTAP

kubectl delete job model-download --ignore-not-found
kubectl delete -f ontap-pvc.yaml --ignore-not-found
kubectl delete -f ontap-storage-class.yaml --ignore-not-found
kubectl delete -f trident-backend-config.yaml --ignore-not-found
kubectl delete -f fsx-ontap-secret.yaml --ignore-not-found

kubectl get pv,pvc

helm uninstall trident-operator -n trident

rm -rf /home/participant/environment/eks/download
