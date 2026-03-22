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
│           │     │  │  ├─ observability-agent ─────────────┤   │  │
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
read -s OPENAI_API_KEY && export OPENAI_API_KEY

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

### Phase 6: Verify Model Route via AgentGateway

The `kagent-values.yaml` configures the default provider with `config.baseUrl` pointing to the agentgateway data plane service. All agents automatically route through agentgateway — no manual patching required.

```bash
# Verify the default-model-config has the agentgateway baseUrl
kubectl get modelconfig default-model-config -n kagent -o jsonpath='{.spec.openAI.baseUrl}'
# Expected: http://agentgateway.default.svc.cluster.local:8080/v1
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
    └── kagent-values.yaml           # Helm values for kagent (routes through agentgateway)
```

## Key Resources

| Resource | Namespace | Description |
|----------|-----------|-------------|
| `Gateway/agentgateway` | default | K8s Gateway API listener on port 8080 |
| `HTTPRoute/llm-route` | default | Routes all traffic to OpenAI backend |
| `AgentgatewayBackend/openai-backend` | default | OpenAI LLM provider config |
| `ModelConfig/default-model-config` | kagent | Default model config routing through agentgateway |
| `Agent/k8s-agent` | kagent | Kubernetes diagnostics agent |
| `Agent/kgateway-agent` | kagent | Gateway management agent |
| `Agent/helm-agent` | kagent | Helm operations agent |
| `Agent/observability-agent` | kagent | Observability & monitoring agent |

## Cleanup

```bash
k3d cluster delete agentic-lab
```

## Lab Tasks Completed

- [x] **Beginner**: Install agentgateway, configure OpenAI provider, config.yaml, run gateway
- [x] **Experienced**: Helm deployment in K8s, Secrets & ConfigMaps, deploy kagent, model route via agentgateway, verify built-in agent
- [x] **Max**: kagent Gateway API — full Kubernetes Gateway API mode with Gateway, HTTPRoute, AgentgatewayBackend CRs
