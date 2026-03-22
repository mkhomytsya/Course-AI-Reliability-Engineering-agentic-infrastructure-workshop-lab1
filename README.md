# Agentic Infrastructure Workshop — Lab 1

Hands-on lab for deploying **Basic Agentic Infrastructure** using **AgentGateway**, **kagent**, and **Kubernetes** (k3d).

## Architecture

```
┌──────────┐     ┌──────────────────────────────────────────────┐
│  Client   │────▶│  k3d Kubernetes Cluster (agentic-lab)        │
│  (curl/   │     │                                              │
│   kagent  │     │  ┌────────────────────────┐                  │
│   UI)     │     │  │  agentgateway-system    │                  │
│           │     │  │  └─ controller (Go)     │                  │
│           │     │  └────────────────────────┘                  │
│           │     │                                              │
│           │     │  ┌────────────────────────────────────────┐  │
│           │     │  │  default namespace                     │  │
│           │     │  │  ├─ Gateway (listener :8080)           │  │
│           │     │  │  ├─ HTTPRoute (/* → openai-backend)    │  │
│           │     │  │  ├─ AgentgatewayBackend (OpenAI)       │  │
│           │     │  │  ├─ AgentgatewayParameters             │  │
│           │     │  │  ├─ Secret (openai-api-key)            │  │
│           │     │  │  └─ agentgateway data plane (Rust)     │  │
│           │     │  └────────────────────────────────────────┘  │
│           │     │             ▲                                 │
│           │     │             │ baseUrl: http://agentgateway    │
│           │     │             │         .default:8080/v1        │
│           │     │  ┌──────────┴─────────────────────────────┐  │
│           │     │  │  kagent namespace                      │  │
│           │     │  │  ├─ kagent-controller                  │  │
│           │     │  │  ├─ kagent-ui                          │  │
│           │     │  │  ├─ k8s-agent ─────────────────────┐   │  │
│           │     │  │  ├─ kgateway-agent ─────────────────┤   │  │
│           │     │  │  ├─ helm-agent ─────────────────────┤   │  │
│           │     │  │  ├─ cilium-debug-agent ─────────────┤   │  │
│           │     │  │  ├─ ModelConfig (openai-via-agw) ───┘   │  │
│           │     │  │  └─ Secret (kagent-openai)              │  │
│           │     │  └────────────────────────────────────────┘  │
│           │     └──────────────────────────────────────────────┘
│           │                        │
└──────────┘                        ▼
                              api.openai.com
                              (GPT-4.1-mini)
```

## Prerequisites

- Docker
- kubectl
- Helm 3
- k3d (installed automatically by setup script)
- OpenAI API key

## Quick Start

```bash
# 1. Set your OpenAI API key
export OPENAI_API_KEY='sk-your-key-here'

# 2. Run the setup script
./setup.sh
```

## Manual Step-by-Step Deployment

### Phase 1: Create k3d Cluster

```bash
k3d cluster create agentic-lab \
  --port "15000:15000@loadbalancer" \
  --port "8080:8080@loadbalancer" \
  --port "8088:8088@loadbalancer" \
  --agents 1 --wait
```

### Phase 2: Install Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

### Phase 3: Install AgentGateway (Helm)

```bash
# CRDs
helm upgrade -i agentgateway-crds \
  oci://cr.agentgateway.dev/agentgateway/charts/agentgateway-crds \
  --namespace agentgateway-system --create-namespace \
  --version 1.0.1 --wait

# Controller
helm upgrade -i agentgateway \
  oci://cr.agentgateway.dev/agentgateway/charts/agentgateway \
  --namespace agentgateway-system \
  --version 1.0.1 --wait
```

### Phase 4: Create Secrets & Deploy Gateway Resources

```bash
# Create secret with Bearer token for agentgateway
kubectl create secret generic openai-api-key \
  --from-literal=Authorization="Bearer ${OPENAI_API_KEY}" \
  -n default

# Apply Gateway API resources
kubectl apply -f k8s/agentgateway-params.yaml
kubectl apply -f k8s/gateway.yaml
kubectl apply -f k8s/openai-backend.yaml
kubectl apply -f k8s/httproute.yaml
```

### Phase 5: Install kagent

```bash
# CRDs first
helm upgrade -i kagent-crds \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --namespace kagent --wait

# Create API key secret for kagent
kubectl create secret generic kagent-openai \
  --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY}" \
  -n kagent

# Install kagent
helm upgrade -i kagent \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace kagent \
  --values k8s/kagent-values.yaml \
  --timeout 10m --wait
```

### Phase 6: Configure Model Route via AgentGateway

```bash
# Create ModelConfig that routes through agentgateway
kubectl apply -f k8s/kagent-modelconfig.yaml

# Patch agents to use the agentgateway-routed model config
for agent in k8s-agent kgateway-agent helm-agent cilium-debug-agent; do
  kubectl patch agent "$agent" -n kagent --type=json \
    -p '[{"op":"replace","path":"/spec/declarative/modelConfig","value":"openai-via-agentgateway"}]'
done
```

### Phase 7: Verification

```bash
# Check all components
kubectl get nodes
kubectl get pods -n agentgateway-system
kubectl get gateway,agentgatewaybackend,httproute -n default
kubectl get pods -n kagent
kubectl get agents,modelconfigs -n kagent

# Test LLM through agentgateway
kubectl port-forward -n default svc/agentgateway 18080:8080 &
curl -s -X POST http://localhost:18080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4.1-mini","messages":[{"role":"user","content":"Hello!"}]}'

# Access kagent UI
kubectl port-forward -n kagent svc/kagent-ui 9090:8080 &
# Open http://localhost:9090
```

## Project Structure

```
├── README.md
├── setup.sh                         # Full automation script
└── k8s/
    ├── agentgateway-params.yaml     # AgentgatewayParameters CR
    ├── gateway.yaml                 # Gateway resource (K8s Gateway API)
    ├── httproute.yaml               # HTTPRoute connecting listener → backend
    ├── openai-backend.yaml          # AgentgatewayBackend for OpenAI
    ├── openai-secret.yaml           # Secret template (API key placeholder)
    ├── kagent-values.yaml           # Helm values for kagent
    └── kagent-modelconfig.yaml      # ModelConfig routing through agentgateway
```

## Key Resources

| Resource | Namespace | Description |
|----------|-----------|-------------|
| `Gateway/agentgateway` | default | K8s Gateway API listener on port 8080 |
| `HTTPRoute/llm-route` | default | Routes all traffic to OpenAI backend |
| `AgentgatewayBackend/openai-backend` | default | OpenAI LLM provider config |
| `ModelConfig/openai-via-agentgateway` | kagent | Points kagent agents to agentgateway |
| `Agent/k8s-agent` | kagent | Kubernetes diagnostics agent |
| `Agent/kgateway-agent` | kagent | Gateway management agent |
| `Agent/helm-agent` | kagent | Helm operations agent |

## Cleanup

```bash
k3d cluster delete agentic-lab
```

## Lab Tasks Completed

- [x] **Beginner**: Install agentgateway, configure OpenAI provider, config.yaml, run gateway
- [x] **Experienced**: Helm deployment in K8s, Secrets & ConfigMaps, deploy kagent, model route via agentgateway, verify built-in agent
- [x] **Max**: kagent Gateway API — full Kubernetes Gateway API mode with Gateway, HTTPRoute, AgentgatewayBackend CRs

```
Plan: Deploy Full Agentic Infrastructure (Max Level) on k3d
Deploy agentgateway + kagent on a k3d Kubernetes cluster using the Kubernetes Gateway API approach (max-level task). Uses OpenAI as LLM provider. All infrastructure runs locally via k3d.

Phase 1: Environment Setup
Install k3d — curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
Create k3d cluster with port mappings — k3d cluster create agentic-lab --port "15000:80@loadbalancer" --port "8080:8080@loadbalancer" --agents 1
Verify cluster — kubectl cluster-info / kubectl get nodes
Install Gateway API CRDs — kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
Phase 2: Deploy AgentGateway via Helm (K8s Gateway API)
Install agentgateway CRDs chart from oci://cr.agentgateway.dev/agentgateway/charts/agentgateway-crds
Install agentgateway controller chart from oci://cr.agentgateway.dev/agentgateway/charts/agentgateway
Verify controller pods running in agentgateway-system
Phase 3: Configure Secrets
Create OpenAI API key Secret — kubectl create secret generic openai-api-key --from-literal=key=$OPENAI_API_KEY
Phase 4: Configure Gateway & Backend CRs
Create AgentgatewayParameters CR — image registry, resource limits, logging
Create Gateway resource — gatewayClassName: agentgateway, listener on port 8080
Create AgentgatewayBackend for OpenAI — provider: openai, model: gpt-4o-mini, auth via secretRef
Apply all resources via kubectl apply
Verify — kubectl get gateway, kubectl get agentgatewaybackend, check pods
Phase 5: Deploy kagent
Install kagent via Helm — helm repo add kagent https://kagent-dev.github.io/kagent/ && helm install kagent kagent/kagent -n kagent-system --create-namespace
Verify kagent — pods in kagent-system, CRDs registered
Phase 6: Configure Model Route via AgentGateway
Create ModelConfig CR pointing kagent's LLM endpoint to agentgateway's in-cluster service (instead of direct OpenAI) — this fulfills "налаштувати маршрут моделі через agentgateway"
Verify connectivity between kagent → agentgateway → OpenAI
Phase 7: Verify Built-in Agent
Port-forward kagent UI — kubectl port-forward svc/kagent-ui -n kagent-system 8088:80
Test a built-in agent (e.g., K8sExpert) via the kagent UI
Port-forward agentgateway UI — access at http://localhost:15000/ui/
Verify backends & policies visible in agentgateway dashboard
Phase 8: End-to-End Verification (Max Task)
Confirm full flow: Client → kagent → agentgateway (Gateway API) → OpenAI
Test LLM completion through the gateway route via curl
Review policies, backends in agentgateway UI
```


```
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
k3d version

k3d cluster create agentic-lab \
  --port "15000:15000@loadbalancer" \
  --port "8080:8080@loadbalancer" \
  --port "8088:8088@loadbalancer" \
  --agents 1 \
  --wait

kubectl cluster-info && echo "---" && kubectl get nodes  

kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

helm show chart oci://cr.agentgateway.dev/agentgateway/charts/agentgateway 2>&1 | head -20
helm show chart oci://cr.agentgateway.dev/agentgateway/charts/agentgateway-crds 2>&1 | head -20
helm show values oci://cr.agentgateway.dev/agentgateway/charts/agentgateway 2>&1
helm repo add kagent https://kagent-dev.github.io/kagent/ 2>&1 && helm repo update kagent 2>&1 && helm search repo kagent 2>&1
helm show chart oci://ghcr.io/kagent-dev/kagent/charts/kagent 2>&1 | head -30
helm show chart oci://ghcr.io/kagent-dev/kagent/helm/kagent 2>&1 | head -30
helm show values oci://ghcr.io/kagent-dev/kagent/helm/kagent 2>&1 | head -150
helm show values oci://ghcr.io/kagent-dev/kagent/helm/kagent 2>&1 | grep -A 50 "MODEL PROVIDER\|modelProvider\|openAI\|apiKey\|model:" | head -100
helm show values oci://ghcr.io/kagent-dev/kagent/helm/kagent 2>&1 | grep -A 80 "# AGENTS" | head -120
helm show values oci://ghcr.io/kagent-dev/kagent/helm/kagent 2>&1 | grep -A 30 "modelProvider" | head -50
helm show values oci://ghcr.io/kagent-dev/kagent/helm/kagent 2>&1 | grep -B5 -A 40 "MODEL PROVIDER\|modelConfig"
helm show values oci://ghcr.io/kagent-dev/kagent/helm/kagent 2>&1 | grep -n "model\|provider\|openAI\|default:" | head -30

mkdir -p /workspaces/Course-AI-Reliability-Engineering-agentic-infrastructure-workshop-lab1/k8s

chmod +x /workspaces/Course-AI-Reliability-Engineering-agentic-infrastructure-workshop-lab1/setup.sh

helm upgrade -i agentgateway-crds \
  oci://cr.agentgateway.dev/agentgateway/charts/agentgateway-crds \
  --namespace agentgateway-system --create-namespace \
  --version 1.0.1 \
  --wait

helm upgrade -i agentgateway \
  oci://cr.agentgateway.dev/agentgateway/charts/agentgateway \
  --namespace agentgateway-system \
  --version 1.0.1 \
  --wait --timeout 5m  

kubectl get pods -n agentgateway-system && echo "---" && kubectl get crds | grep agentgateway  


read -s OPENAI_API_KEY && export OPENAI_API_KEY
kubectl create secret generic openai-api-key \
  --from-literal=key="${OPENAI_API_KEY}" \
  -n default --dry-run=client -o yaml | kubectl apply -f - && echo "---" && \
kubectl create namespace kagent --dry-run=client -o yaml | kubectl apply -f - && \
kubectl create secret generic kagent-openai \
  --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY}" \
  -n kagent --dry-run=client -o yaml | kubectl apply -f -


kubectl explain agentgatewayparameters.spec 2>&1 | head -40  

kubectl explain agentgatewayparameters.spec.image 2>&1 && echo "===" && kubectl explain agentgatewayparameters.spec.deployment 2>&1 | head -30

kubectl explain agentgatewaybackends.spec 2>&1

kubectl explain agentgatewaybackends.spec.ai 2>&1 && echo "===" && kubectl explain agentgatewaybackends.spec.policies 2>&1

kubectl explain agentgatewaybackends.spec.ai.provider 2>&1 && echo "===" && kubectl explain agentgatewaybackends.spec.policies.auth 2>&1

kubectl explain agentgatewaybackends.spec.policies.auth.secretRef 2>&1 && echo "===" && kubectl explain agentgatewaybackends.spec.ai.provider.openai 2>&1

kubectl delete secret openai-api-key -n default 2>/dev/null; \
kubectl create secret generic openai-api-key \
  --from-literal=Authorization="Bearer ${OPENAI_API_KEY}" \
  -n default && echo "Secret recreated with Authorization key"

cd /workspaces/Course-AI-Reliability-Engineering-agentic-infrastructure-workshop-lab1 && \
kubectl apply -f k8s/agentgateway-params.yaml && \
kubectl apply -f k8s/gateway.yaml && \
echo "---waiting for gateway data plane---" && sleep 10 && \
kubectl apply -f k8s/openai-backend.yaml  


echo "=== Gateway ===" && kubectl get gateway -n default && echo "" && \
echo "=== Backends ===" && kubectl get agentgatewaybackend -n default && echo "" && \
echo "=== Pods (default ns) ===" && kubectl get pods -n default && echo "" && \
echo "=== Services (default ns) ===" && kubectl get svc -n default && echo "" && \
echo "=== Controller logs ===" && kubectl logs -n agentgateway-system -l app.kubernetes.io/name=agentgateway --tail=20

cd /workspaces/Course-AI-Reliability-Engineering-agentic-infrastructure-workshop-lab1 && \
helm upgrade -i kagent \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace kagent \
  --values k8s/kagent-values.yaml \
  --timeout 10m \
  --wait 2>&1

  helm show chart oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds 2>&1 | head -20

helm upgrade -i kagent-crds \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --namespace kagent \
  --wait --timeout 3m 2>&1  


cd /workspaces/Course-AI-Reliability-Engineering-agentic-infrastructure-workshop-lab1 && \
helm upgrade -i kagent \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace kagent \
  --values k8s/kagent-values.yaml \
  --timeout 10m \
  --wait 2>&1  


kubectl get pods -n kagent && echo "---" && kubectl get crd | grep kagent && echo "---" && kubectl get agents -n kagent && echo "---" && kubectl get modelconfigs -n kagent  


kubectl explain modelconfigs.spec 2>&1 && echo "===" && kubectl get modelconfig default-model-config -n kagent -o yaml

kubectl port-forward -n default svc/agentgateway 15000:8080 &
sleep 3 && echo "port-forward started"

kubectl port-forward -n default svc/agentgateway 18080:8080 &
sleep 3 && echo "port-forward started on 18080"
```