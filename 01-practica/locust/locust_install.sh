#!/bin/bash
VERSION=${1:-1.1.2}
NAMESPACE=${2:-locust}

kubectl create namespace $NAMESPACE
kubectl create configmap locust-worker-configs --from-file ./scripts --namespace=$NAMESPACE
helm install --name locust stable/locust --version $VERSION --namespace $NAMESPACE \
  --set master.config.target-host=http://netcore-counter-user.0.0.0.0.nip.io \
  --set worker.config.configmapName=locust-worker-configs
kubectl apply -f locust-ingress.yaml --namespace=$NAMESPACE
