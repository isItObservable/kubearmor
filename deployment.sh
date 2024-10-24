#!/usr/bin/env bash

################################################################################
### Script deploying the Observ-K8s environment
### Parameters:
### Clustern name: name of your k8s cluster
### dttoken: Dynatrace api token with ingest metrics and otlp ingest scope
### dturl : url of your DT tenant wihtout any / at the end for example: https://dedede.live.dynatrace.com
################################################################################


### Pre-flight checks for dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "Please install jq before continuing"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "Please install git before continuing"
    exit 1
fi


if ! command -v helm >/dev/null 2>&1; then
    echo "Please install helm before continuing"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Please install kubectl before continuing"
    exit 1
fi
echo "parsing arguments"
while [ $# -gt 0 ]; do
  case "$1" in
   --dtoperatortoken)
          DTOPERATORTOKEN="$2"
         shift 2
          ;;
       --dtingesttoken)
          DTTOKEN="$2"
         shift 2
          ;;
       --dturl)
          DTURL="$2"
         shift 2
          ;;
       --clustername)
         CLUSTERNAME="$2"
         shift 2
         ;;
  *)
    echo "Warning: skipping unsupported option: $1"
    shift
    ;;
  esac
done
echo "Checking arguments"
 if [ -z "$CLUSTERNAME" ]; then
   echo "Error: clustername not set!"
   exit 1
 fi
 if [ -z "$DTURL" ]; then
   echo "Error: Dt url not set!"
   exit 1
 fi

 if [ -z "$DTTOKEN" ]; then
   echo "Error: Data ingest api-token not set!"
   exit 1
 fi

 if [ -z "$DTOPERATORTOKEN" ]; then
   echo "Error: DT operator token not set!"
   exit 1
 fi

#### Deploy the cert-manager
echo "Deploying Cert Manager ( for OpenTelemetry Operator)"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.10.0/cert-manager.yaml
# Wait for pod webhook started
kubectl wait pod -l app.kubernetes.io/component=webhook -n cert-manager --for=condition=Ready --timeout=2m
# Deploy the opentelemetry operator
sleep 10
echo "Deploying the OpenTelemetry Operator"
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml

echo "Deploying Istio"
istioctl install -f istio/istioOperator.yaml --skip-confirmation

echo "installing KuberArmor"
helm repo add kubearmor https://kubearmor.github.io/charts
helm repo update kubearmor

helm upgrade --install kubearmor-operator kubearmor/kubearmor-operator -n kubearmor --create-namespace -f kubearmor/values.yaml
kubectl apply -f kubearmor/kubeArmorConfig.yaml
kubectl apply -f  kubearmor/kuberarmo_prometheus_exporter.yaml -n kubearmor

#### Deploy the Dynatrace Operator
kubectl create namespace dynatrace
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/download/v1.2.2/kubernetes.yaml
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/download/v1.2.2/kubernetes-csi.yaml
kubectl -n dynatrace wait pod --for=condition=ready --selector=app.kubernetes.io/name=dynatrace-operator,app.kubernetes.io/component=webhook --timeout=300s
kubectl -n dynatrace create secret generic dynakube --from-literal="apiToken=$DTOPERATORTOKEN" --from-literal="dataIngestToken=$DTTOKEN"
sed -i "s,TENANTURL_TOREPLACE,$DTURL," dynatrace/dynakube.yaml
sed -i "s,CLUSTER_NAME_TO_REPLACE,$CLUSTERNAME,"  dynatrace/dynakube.yaml

### get the ip adress of ingress ####
IP=""
while [ -z $IP ]; do
  echo "Waiting for external IP"
  IP=$(kubectl get svc istio-ingressgateway -n istio-system -ojson | jq -j '.status.loadBalancer.ingress[].ip')
  [ -z "$IP" ] && sleep 10
done
echo 'Found external IP: '$IP

### Update the ip of the ip adress for the ingres
#TODO to update this part to create the various Gateway rules
sed -i "s,IP_TO_REPLACE,$IP," opentelemetry/deploy_1_11.yaml
sed -i "s,IP_TO_REPLACE,$IP," istio/istio_gateway.yaml

#Deploy collector
kubectl create secret generic dynatrace  --from-literal=dynatrace_oltp_url="$DTURL" --from-literal=clustername="$CLUSTERNAME"  --from-literal=clusterid=$CLUSTERID  --from-literal=dt_api_token="$DTTOKEN"
kubectl label namespace  default oneagent=false
kubectl apply -f opentelemetry/rbac.yaml

kubectl apply -f opentelemetry/openTelemetry-manifest_statefulset.yaml
kubectl apply -f opentelemetry/openTelemetry-manifest_ds.yaml
#deploy demo application
kubectl apply -f dynatrace/dynakube.yaml -n dynatrace
kubectl create ns otel-demo
kubectl label namespace otel-demo istio-injection=enabled
kubectl label namespace  otel-demo oneagent=false




kubectl apply -f opentelemetry/deploy_1_11.yaml -n otel-demo


kubectl create ns goat-app
kubectl label namespace  goat-app oneagent=false


kubectl apply -f k8sGoat/unsafejob.yaml -n goat-app
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install unguard-mariadb bitnami/mariadb --version 11.5.7 --set primary.persistence.enabled=false --wait --namespace unguard --create-namespace
helm install unguard  oci://ghcr.io/dynatrace-oss/unguard/chart/unguard --set maliciousLoadGenerat.enabled=true --wait --namespace unguard

kubectl apply -f istio/istio_gateway.yaml

kubectl annotate ns goat-app kubearmor-visibility=network,process,file,capability --overwrite
kubectl annotate ns otel-demo kubearmor-visibility=network,process,file,capability --overwrite
kubectl annotate ns unguard kubearmor-visibility=network,process,file,capability --overwrite

#deploy predefined policies:
kubectl apply -f https://raw.githubusercontent.com/kubearmor/policy-templates/refs/heads/main/nist/system/hsp-ac-2-4-automated-audit-action.yaml
kubectl apply -f https://raw.githubusercontent.com/kubearmor/policy-templates/refs/heads/main/nist/system/hsp-ca-7-4-continuous-monitoring-automation-support-for-monitoring.yaml
kubectl apply -f https://raw.githubusercontent.com/kubearmor/policy-templates/refs/heads/main/nist/system/hsp-cm-1-configuration-management-policy-and-procedures.yaml
kubectl apply -f kubearmor/policies/ksp-cm-7-4-least-functionality-nist.yaml.yaml
kubectl apply -f kubearmor/policies/ksp-remote-access-audit.yaml
kubectl apply -f kubearmor/policies/ksp-nist-si-4-detect-execution-of-network-tools-inside-container.yaml
kubectl apply -f kubearmor/policies/ksp-nist-cp-2-8-critical-system-files.yaml
kubectl apply -f kubearmor/policies/ksp-nist-au-12-audit-write-below-binary-directories.yaml
kubectl apply -f kubearmor/policies/ksp-cm-9-1-configuration-management-plan.yaml


#Deploy the ingress rules
echo "--------------Demo--------------------"
echo "url of the demo: "
echo " otel-demo : http://oteldemo.$IP.nip.io"
echo "========================================================"


