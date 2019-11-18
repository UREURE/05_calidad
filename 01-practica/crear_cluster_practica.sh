#!/bin/bash

# Párámetros por defecto
NOMBRE_CLUSTER=${1:-practica-calidad}
ZONA_CLUSTER=${2:-europe-west1-b}
MAQUINAS_CLUSTER=${3:-n1-standard-2}
MAX_NODES_CLUSTER=${4:-5}
NAMESPACE=${5:-practica-netcore-counter}
RELEASE=${6:-netcore-counter-test}
PASSWORD=${7:-PasswordMuyMuyDificilDeAdivinar0=0}
VERSION_HELM=${8:-v2.14.3}

# Valida si una IP es válida, retorna:
# 0: válida.
# 1: NO válida.
function valid_ip()
{
  local  ip=$1
  local  stat=1

  if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    OIFS=$IFS
    IFS='.'
    ip=($ip)
    IFS=$OIFS
    [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
    stat=$?
  fi
  echo $stat
}

# Crear clúster
gcloud container clusters create $NOMBRE_CLUSTER \
  --zone $ZONA_CLUSTER \
  --enable-stackdriver-kubernetes \
  --enable-autoscaling \
  --machine-type=$MAQUINAS_CLUSTER \
  --max-nodes=$MAX_NODES_CLUSTER

# Utilizar clúster creado
gcloud container clusters get-credentials $NOMBRE_CLUSTER

# Clonar el repositorio de la aplicación
git clone https://github.com/UREURE/netcore-counter.git

# Instalar Helm
cd ./netcore-counter/helm
chmod 700 *.sh
./helm_install.sh $VERSION_HELM
cd ../..

# Instalar nginx-ingress
kubectl create clusterrolebinding cluster-admin-binding --clusterrole cluster-admin --user $(gcloud config get-value account)
kubectl apply -f ./netcore-counter/nginx-ingress/mandatory.yaml
kubectl apply -f ./netcore-counter/nginx-ingress/cloud-generic.yaml
LOAD_BALANCER_IP=$(kubectl get services --all-namespaces|grep LoadBalancer|awk '{print $5};')
IP_LOAD_BALANCER_VALIDA=$(valid_ip $LOAD_BALANCER_IP)
until [[ $IP_LOAD_BALANCER_VALIDA -eq 0 ]]; do
  echo "Esperando 10 segundos para obtener IP del balanceador..."
  sleep 10
  LOAD_BALANCER_IP=$(kubectl get svc --all-namespaces|grep LoadBalancer|awk '{print $5};')
  IP_LOAD_BALANCER_VALIDA=$(valid_ip $LOAD_BALANCER_IP)
done
echo "Obtenida IP del balanceador: $LOAD_BALANCER_IP"

# Instalar Prometheus Operator
cd ./monitoring
sudo chmod 700 *.sh
sed -i "s/0.0.0.0/$LOAD_BALANCER_IP/g" monitoring-ingress.yaml
./instalar_prometheus_operator.sh
cd ..
NUMERO_CRDs_PROMETHEUS=$(kubectl get crds | grep 'monitoring' | wc -l)
until [[ $NUMERO_CRDs_PROMETHEUS -eq 4 ]]; do
  echo "Esperando 10 segundos mientras se crean los CRDs de Prometheus..."
  sleep 10
  NUMERO_CRDs_PROMETHEUS=$(kubectl get crds | grep 'monitoring' | wc -l)
done

# Instalar Istio con Kiali
cd istio
curl -L https://git.io/getLatestIstio | ISTIO_VERSION=1.3.3 sh -
cd istio-1.3.3
helm repo add istio.io https://storage.googleapis.com/istio-release/releases/1.3.3/charts/
helm repo update
helm install install/kubernetes/helm/istio-init --name istio-init --namespace istio-system
NUMERO_CRDs_ISTIO=$(kubectl get crds | grep 'istio.io' | wc -l)
until [[ $NUMERO_CRDs_ISTIO -eq 23 ]]; do
  echo "Esperando 10 segundos mientras se crean los CRDs de Istio..."
  sleep 10
  NUMERO_CRDs_ISTIO=$(kubectl get crds | grep 'istio.io' | wc -l)
done
helm install install/kubernetes/helm/istio --name istio --namespace istio-system \
  --values install/kubernetes/helm/istio/values-istio-demo.yaml \
  --set gateways.istio-ingressgateway.enabled=false \
  --set gateways.istio-egressgateway.enabled=false \
  --set grafana.enabled=false \
  --set prometheus.enabled=false \
  --set kiali.prometheusAddr=http://prometheus-prometheus-oper-prometheus.monitoring:9090
cd ..
sed -i "s/0.0.0.0/$LOAD_BALANCER_IP/g" istio-system-ingress.yaml
kubectl apply -f istio-system-ingress.yaml --namespace=istio-system
kubectl apply -f istio-telemetry-service-monitor.yaml --namespace=istio-system
cd ..

# Instalar la aplicación con inyección de Istio
cd netcore-counter/k8s
sudo chmod 700 *.sh
kubectl create namespace $NAMESPACE
kubectl label namespace $NAMESPACE istio-injection=enabled
./start-kubernetes.sh $PASSWORD $NAMESPACE
cd ../..

# Exponer la aplicación
sed -i "s/0.0.0.0/$LOAD_BALANCER_IP/g" ./netcore-counter/nginx-ingress/netcore-counter-ingress-user.yaml
kubectl apply -f ./netcore-counter/nginx-ingress/netcore-counter-ingress-user.yaml --namespace=$NAMESPACE

# Añadir los Service Monitor para la aplicación
kubectl apply -f ./monitoring/counter-service-monitor-redis.yaml --namespace=$NAMESPACE
kubectl apply -f ./monitoring/counter-service-monitor-next.yaml --namespace=$NAMESPACE
kubectl apply -f ./monitoring/counter-service-monitor-user.yaml --namespace=$NAMESPACE

# Instalar Locust
cd locust
sed -i "s/0.0.0.0/$LOAD_BALANCER_IP/g" locust-ingress.yaml
sed -i "s/0.0.0.0/$LOAD_BALANCER_IP/g" locust_install.sh
sudo chmod 700 *.sh
./locust_install.sh
cd ..
