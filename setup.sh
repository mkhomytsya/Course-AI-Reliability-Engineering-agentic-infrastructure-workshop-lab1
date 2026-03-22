#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Agentic Infrastructure Deployment Script (Max Level)
# Deploys: k3d cluster + agentgateway (K8s Gateway API) + kagent
# Provider: OpenAI
# =============================================================================

CLUSTER_NAME="agentic-lab"
AGW_NAMESPACE="agentgateway-system"
AGW_CHART_VERSION="1.0.1"
KAGENT_NAMESPACE="kagent"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/k8s"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; }
info()  { echo -e "${CYAN}[i]${NC} $*"; }

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
preflight() {
    info "Running pre-flight checks..."

    for cmd in docker kubectl helm k3d; do
        if ! command -v "$cmd" &>/dev/null; then
            err "$cmd is not installed. Please install it first."
            exit 1
        fi
    done

    if [ -z "${OPENAI_API_KEY:-}" ]; then
        err "OPENAI_API_KEY environment variable is not set."
        echo ""
        echo "  export OPENAI_API_KEY='sk-your-key-here'"
        echo ""
        exit 1
    fi

    log "All pre-flight checks passed."
}

# -----------------------------------------------------------------------------
# Phase 1: Create k3d cluster
# -----------------------------------------------------------------------------
create_cluster() {
    info "Phase 1: Creating k3d cluster '${CLUSTER_NAME}'..."

    if k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
        warn "Cluster '${CLUSTER_NAME}' already exists. Skipping creation."
        kubectl config use-context "k3d-${CLUSTER_NAME}"
    else
        k3d cluster create "${CLUSTER_NAME}" \
            --port "15000:15000@loadbalancer" \
            --port "8080:8080@loadbalancer" \
            --port "8088:8088@loadbalancer" \
            --agents 1 \
            --wait
        log "Cluster '${CLUSTER_NAME}' created."
    fi

    kubectl wait --for=condition=Ready nodes --all --timeout=120s
    log "All nodes are Ready."
}

# -----------------------------------------------------------------------------
# Phase 2: Install Gateway API CRDs
# -----------------------------------------------------------------------------
install_gateway_api() {
    info "Phase 2: Installing Kubernetes Gateway API CRDs..."

    if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
        warn "Gateway API CRDs already installed. Skipping."
    else
        kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
        log "Gateway API CRDs installed."
    fi
}

# -----------------------------------------------------------------------------
# Phase 3: Install AgentGateway Helm charts
# -----------------------------------------------------------------------------
install_agentgateway() {
    info "Phase 3: Installing AgentGateway Helm charts (v${AGW_CHART_VERSION})..."

    # Install CRDs chart
    helm upgrade -i agentgateway-crds \
        oci://cr.agentgateway.dev/agentgateway/charts/agentgateway-crds \
        --namespace "${AGW_NAMESPACE}" --create-namespace \
        --version "${AGW_CHART_VERSION}" \
        --wait
    log "AgentGateway CRDs chart installed."

    # Install main controller chart
    helm upgrade -i agentgateway \
        oci://cr.agentgateway.dev/agentgateway/charts/agentgateway \
        --namespace "${AGW_NAMESPACE}" \
        --version "${AGW_CHART_VERSION}" \
        --wait --timeout 5m
    log "AgentGateway controller chart installed."

    # Wait for controller pod
    kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=agentgateway \
        -n "${AGW_NAMESPACE}" --timeout=120s 2>/dev/null || \
    kubectl wait --for=condition=Ready pods --all \
        -n "${AGW_NAMESPACE}" --timeout=120s
    log "AgentGateway controller is running."
}

# -----------------------------------------------------------------------------
# Phase 4: Create Secrets and deploy Gateway + Backend
# -----------------------------------------------------------------------------
deploy_gateway_resources() {
    info "Phase 4: Creating OpenAI API key Secret and deploying Gateway resources..."

    # Create OpenAI secret (in default namespace for gateway backend)
    # The agentgateway CRD requires the key to be stored in the 'Authorization' field
    kubectl create secret generic openai-api-key \
        --from-literal=Authorization="Bearer ${OPENAI_API_KEY}" \
        -n default --dry-run=client -o yaml | kubectl apply -f -
    log "OpenAI API key Secret created in default namespace."

    # Apply AgentGateway Parameters
    kubectl apply -f "${K8S_DIR}/agentgateway-params.yaml"
    log "AgentgatewayParameters applied."

    # Apply Gateway resource
    kubectl apply -f "${K8S_DIR}/gateway.yaml"
    log "Gateway resource applied."

    # Wait for gateway to be accepted
    sleep 5
    info "Waiting for Gateway data plane pods to start..."
    for i in $(seq 1 30); do
        if kubectl get pods -n default -l gateway=agentgateway 2>/dev/null | grep -q "Running"; then
            log "Gateway data plane pod is running."
            break
        fi
        if [ "$i" -eq 30 ]; then
            warn "Gateway pod not yet running. Check: kubectl get pods -n default"
        fi
        sleep 5
    done

    # Apply Backend configuration
    kubectl apply -f "${K8S_DIR}/openai-backend.yaml"
    log "OpenAI Backend resource applied."

    # Apply HTTPRoute to connect Gateway listener to Backend
    kubectl apply -f "${K8S_DIR}/httproute.yaml"
    log "HTTPRoute applied."

    # Show status
    kubectl get gateway -n default
    kubectl get agentgatewaybackend -n default 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Phase 5: Install kagent
# -----------------------------------------------------------------------------
install_kagent() {
    info "Phase 5: Installing kagent..."

    # Create kagent namespace
    kubectl create namespace "${KAGENT_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    # Create the OpenAI API key secret for kagent
    kubectl create secret generic kagent-openai \
        --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY}" \
        -n "${KAGENT_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    log "kagent OpenAI secret created."

    # Install kagent via Helm
    helm upgrade -i kagent \
        oci://ghcr.io/kagent-dev/kagent/helm/kagent \
        --namespace "${KAGENT_NAMESPACE}" \
        --values "${K8S_DIR}/kagent-values.yaml" \
        --wait --timeout 10m
    log "kagent Helm chart installed."

    # Wait for kagent controller
    info "Waiting for kagent pods to be ready..."
    kubectl wait --for=condition=Ready pods --all \
        -n "${KAGENT_NAMESPACE}" --timeout=300s 2>/dev/null || \
        warn "Some kagent pods may still be starting. Check: kubectl get pods -n ${KAGENT_NAMESPACE}"
    log "kagent is deployed."
}

# -----------------------------------------------------------------------------
# Phase 6: Configure model route via agentgateway
# -----------------------------------------------------------------------------
configure_model_route() {
    info "Phase 6: Configuring kagent model route through agentgateway..."

    # Get the agentgateway data plane service in default namespace
    local gw_svc
    gw_svc=$(kubectl get svc -n default agentgateway -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

    if [ -z "$gw_svc" ]; then
        warn "AgentGateway data plane service not found yet."
        warn "You can configure the model route manually once the gateway pod is running."
        return
    fi

    local gw_endpoint="http://${gw_svc}.default.svc.cluster.local:8080"
    info "AgentGateway data plane endpoint: ${gw_endpoint}"

    # Apply ModelConfig pointing kagent through agentgateway
    kubectl apply -f "${K8S_DIR}/kagent-modelconfig.yaml"
    log "ModelConfig 'openai-via-agentgateway' created."

    # Patch all agents to use the agentgateway-routed ModelConfig
    for agent in $(kubectl get agents -n "${KAGENT_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}'); do
        kubectl patch agent "$agent" -n "${KAGENT_NAMESPACE}" --type=json \
            -p '[{"op":"replace","path":"/spec/declarative/modelConfig","value":"openai-via-agentgateway"}]' 2>/dev/null || true
    done
    log "All agents patched to route through agentgateway."

    # Wait for agent pods to restart
    sleep 10
    kubectl wait --for=condition=Ready pods -l app.kubernetes.io/part-of=kagent \
        -n "${KAGENT_NAMESPACE}" --timeout=120s 2>/dev/null || true

    log "Model route configuration complete."
}

# -----------------------------------------------------------------------------
# Phase 7: Verification
# -----------------------------------------------------------------------------
verify() {
    info "Phase 7: Verification..."
    echo ""

    echo "=== k3d Cluster ==="
    kubectl get nodes
    echo ""

    echo "=== AgentGateway System (${AGW_NAMESPACE}) ==="
    kubectl get pods -n "${AGW_NAMESPACE}"
    echo ""

    echo "=== Gateway Resources ==="
    kubectl get gateway -n default
    kubectl get agentgatewaybackend -n default 2>/dev/null || true
    echo ""

    echo "=== kagent (${KAGENT_NAMESPACE}) ==="
    kubectl get pods -n "${KAGENT_NAMESPACE}"
    echo ""

    echo "=== kagent CRDs ==="
    kubectl get crd | grep -i "kagent\|autogen" || echo "No kagent CRDs found"
    echo ""

    log "Deployment complete!"
    echo ""
    info "=== Access Points ==="
    echo ""
    echo "  AgentGateway (port-forward):  kubectl port-forward -n default svc/agentgateway 18080:8080"
    echo "  kagent UI (port-forward):     kubectl port-forward -n ${KAGENT_NAMESPACE} svc/kagent-ui 9090:8080"
    echo ""
    echo "  Then open:"
    echo "    kagent UI:       http://localhost:9090"
    echo ""
    echo "  Test LLM via agentgateway:"
    echo "    curl -s -X POST http://localhost:18080/v1/chat/completions \\"
    echo "      -H 'Content-Type: application/json' \\"
    echo "      -d '{\"model\":\"gpt-4.1-mini\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    echo ""
    echo "============================================"
    echo "  Agentic Infrastructure Deployment (Max)"
    echo "  k3d + agentgateway (Gateway API) + kagent"
    echo "============================================"
    echo ""

    preflight
    create_cluster
    install_gateway_api
    install_agentgateway
    deploy_gateway_resources
    install_kagent
    configure_model_route
    verify
}

main "$@"
