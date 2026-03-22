# Course-AI-Reliability-Engineering-agentic-infrastructure-workshop-lab1
Hands-on labs for deploying Basic Agentic Infrastructure using AgentGateway, kagent, and Kubernetes

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