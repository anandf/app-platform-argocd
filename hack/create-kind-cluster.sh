set -e

kind create cluster --name $1

# Install MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml

#Install ArgoCD
kubectl create ns argocd && kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.7.6/manifests/install.yaml -n argocd

sleep 10
kubectl wait --namespace metallb-system \
                --for=condition=ready pod \
                --selector=app=metallb \
                --timeout=90s

PODMAN_CIDR=$(podman network inspect -f '{{range .Subnets}}{{if eq (len .Subnet.IP) 4}}{{.Subnet}}{{end}}{{end}}' kind)
IP_ADDR_PREFIX=$(echo ${PODMAN_CIDR} | cut -f1,2,3 -d.)
IP_ADDR_RANGE=$(echo "${IP_ADDR_PREFIX}.200-${IP_ADDR_PREFIX}.250")

DOCKER_CIDR=$(docker network inspect -f '{{.IPAM.Config}}' kind)
IP_ADDR_PREFIX=$(echo ${DOCKER_CIDR} | cut -f1,2 -d.)
#IP_ADDR_RANGE=$(echo "${IP_ADDR_PREFIX}.255.200-${IP_ADDR_PREFIX}.255.250")
IP_ADDR_RANGE="172.18.255.200-172.18.255.250"


kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: example
  namespace: metallb-system
spec:
  addresses:
  - ${IP_ADDR_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
  namespace: metallb-system
EOF

# Update the health check info for Istio, Certificate and other resources"
kubectl patch cm argocd-cm -n argocd -p '{"data": { "resource.customizations": "cert-manager.io/Certificate:\n  health.lua: |\n    hs = {}\n    if obj.status ~= nil then\n      if obj.status.conditions ~= nil then\n        for i, condition in ipairs(obj.status.conditions) do\n          if condition.type == \"Ready\" and condition.status == \"False\" then\n            hs.status = \"Degraded\"\n            hs.message = condition.message\n            return hs\n          end\n          if condition.type == \"Ready\" and condition.status == \"True\" then\n            hs.status = \"Healthy\"\n            hs.message = condition.message\n            return hs\n          end\n        end\n      end\n    end\n\n    hs.status = \"Progressing\"\n    hs.message = \"Waiting for certificate\"\n    return hs\ninstall.istio.io/IstioOperator:\n  health.lua: |\n    hs= {}\n    hs.status = \"Healthy\"\n    hs.message = \"Healthy\"\n    return hs\n" }}'

kubectl port-forward -n argocd svc/argocd-server 8443:443 > /dev/null 2>&1 &

kubectl apply -f ../root-app-set.yaml -n argocd
