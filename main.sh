#!/bin/bash
set -euo pipefail

# =========================
# CONFIG
# =========================
LINUX_USER="${SUDO_USER:-abel-hid}"
CLUSTER_NAME="mycluster"

GITLAB_HOST="gitlab.localhost"
GITLAB_PORT="8081"

ARGO_PORT="9090"

PROJECT_NAME="abel-hid"
GITLAB_INTERNAL_REPO="http://gitlab-webservice-default.gitlab.svc.cluster.local:8181/root/${PROJECT_NAME}.git"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BONUS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VALUES_FILE="$BONUS_DIR/confs/values.yaml"
ARGO_VALUES_FILE="$BONUS_DIR/confs/argocd-values.yaml"
APP_FILE="$BONUS_DIR/confs/app.yaml"
KUBECONFIG_FILE="/home/$LINUX_USER/.kube/config"

# =========================
# HELPERS
# =========================
run_kubectl() {
  KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"
}

print_gitlab_debug() {
  echo ""
  echo "=== GitLab debug info ==="
  run_kubectl get pods -n gitlab -o wide || true
  echo ""
  run_kubectl get jobs -n gitlab || true
  echo ""
  run_kubectl get events -n gitlab --sort-by=.lastTimestamp | tail -80 || true
  echo ""

  MIGRATION_POD="$(run_kubectl get pods -n gitlab --no-headers 2>/dev/null | awk '/gitlab-migrations/ {print $1; exit}' || true)"
  if [ -n "${MIGRATION_POD:-}" ]; then
    echo "=== Migration pod logs: $MIGRATION_POD ==="
    run_kubectl logs -n gitlab "$MIGRATION_POD" --all-containers=true --tail=200 || true
  fi

  WEB_POD="$(run_kubectl get pods -n gitlab --no-headers 2>/dev/null | awk '/gitlab-webservice-default/ {print $1; exit}' || true)"
  if [ -n "${WEB_POD:-}" ]; then
    echo "=== Webservice pod describe: $WEB_POD ==="
    run_kubectl describe pod -n gitlab "$WEB_POD" || true
  fi
}

wait_for_argocd() {
  echo "=== Waiting for Argo CD server ==="

  ARGO_DEPLOY="$(run_kubectl -n argocd get deploy -o name | grep -E 'argocd-server|argo-cd-argocd-server' | head -n 1 || true)"
  if [ -z "$ARGO_DEPLOY" ]; then
    echo "ERROR: Could not find Argo CD server deployment."
    run_kubectl get deploy -n argocd
    exit 1
  fi

  run_kubectl -n argocd rollout status "$ARGO_DEPLOY" --timeout=600s
}

wait_for_gitlab() {
  echo "=== Waiting for GitLab migrations job ==="

  # GitLab chart creates a migration Job with a generated suffix, so find it dynamically.
  MIGRATION_JOB=""
  for i in {1..60}; do
    MIGRATION_JOB="$(run_kubectl -n gitlab get jobs -o name 2>/dev/null | grep 'gitlab-migrations' | tail -n 1 || true)"
    if [ -n "$MIGRATION_JOB" ]; then
      break
    fi
    echo "Waiting for GitLab migrations job to be created..."
    sleep 10
  done

  if [ -z "$MIGRATION_JOB" ]; then
    echo "ERROR: GitLab migrations job was not found."
    print_gitlab_debug
    exit 1
  fi

  echo "Found migration job: $MIGRATION_JOB"
  if ! run_kubectl -n gitlab wait --for=condition=complete "$MIGRATION_JOB" --timeout=1800s; then
    echo "ERROR: GitLab migrations did not complete."
    print_gitlab_debug
    exit 1
  fi

  echo "=== Waiting for GitLab webservice deployment ==="
  WEB_DEPLOY="$(run_kubectl -n gitlab get deploy -o name | grep 'gitlab-webservice-default' | head -n 1 || true)"
  if [ -z "$WEB_DEPLOY" ]; then
    echo "ERROR: GitLab webservice deployment was not found."
    print_gitlab_debug
    exit 1
  fi

  run_kubectl -n gitlab rollout status "$WEB_DEPLOY" --timeout=1800s

  echo "=== Waiting for GitLab sidekiq deployment ==="
  SIDEKIQ_DEPLOY="$(run_kubectl -n gitlab get deploy -o name | grep 'gitlab-sidekiq' | head -n 1 || true)"
  if [ -n "$SIDEKIQ_DEPLOY" ]; then
    run_kubectl -n gitlab rollout status "$SIDEKIQ_DEPLOY" --timeout=1800s || true
  fi

  echo "=== Waiting until GitLab HTTP answers without 502 ==="
  for i in {1..120}; do
    CODE="$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $GITLAB_HOST" "http://127.0.0.1:$GITLAB_PORT/users/sign_in" || true)"

    if [[ "$CODE" == "200" || "$CODE" == "302" ]]; then
      echo "GitLab is ready. HTTP status: $CODE"
      return 0
    fi

    echo "GitLab not ready yet. HTTP status: ${CODE:-none}. Attempt $i/120"
    sleep 10
  done

  echo "ERROR: GitLab did not become ready on http://$GITLAB_HOST:$GITLAB_PORT"
  print_gitlab_debug
  exit 1
}

start_argocd_port_forward() {
  echo "=== Starting Argo CD port-forward on port $ARGO_PORT ==="

  pkill -f "kubectl.*port-forward.*argocd" 2>/dev/null || true
  pkill -f "kubectl.*port-forward.*argo-cd" 2>/dev/null || true

  ARGO_SERVICE="$(run_kubectl -n argocd get svc -o name | grep -E 'argocd-server|argo-cd-argocd-server' | head -n 1 || true)"
  if [ -z "$ARGO_SERVICE" ]; then
    echo "ERROR: Could not find Argo CD server service."
    run_kubectl get svc -n argocd
    exit 1
  fi

  # With server.insecure=true, use http://localhost:9090 in browser.
  nohup env KUBECONFIG="$KUBECONFIG_FILE" kubectl -n argocd port-forward \
    "$ARGO_SERVICE" \
    "$ARGO_PORT:443" \
    --address 127.0.0.1 \
    > /tmp/argocd-port-forward.log 2>&1 &

  sleep 5

  if ! grep -q "Forwarding from" /tmp/argocd-port-forward.log 2>/dev/null; then
    echo "WARNING: Argo CD port-forward may not have started. Log:"
    cat /tmp/argocd-port-forward.log || true
  fi
}

# =========================
# MAIN
# =========================
echo "=== Checking root user ==="
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo:"
  echo "sudo bash scripts/setup.sh"
  exit 1
fi

echo "=== Checking files ==="
if [ ! -f "$VALUES_FILE" ]; then
  echo "ERROR: values.yaml not found here:"
  echo "$VALUES_FILE"
  exit 1
fi

if [ ! -f "$ARGO_VALUES_FILE" ]; then
  echo "ERROR: argocd-values.yaml not found here:"
  echo "$ARGO_VALUES_FILE"
  exit 1
fi

if [ ! -f "$APP_FILE" ]; then
  echo "ERROR: app.yaml not found here:"
  echo "$APP_FILE"
  exit 1
fi

echo "=== Installing dependencies ==="
apt-get update -y
apt-get install -y curl ca-certificates git vim openssh-server

echo "=== Enabling SSH ==="
systemctl enable ssh || true
systemctl start ssh || true

echo "=== Installing Docker ==="
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o get-docker.sh
  chmod +x get-docker.sh
  sh get-docker.sh
  rm -f get-docker.sh
fi

systemctl enable docker
systemctl start docker
usermod -aG docker "$LINUX_USER" || true

echo "=== Installing K3d ==="
if ! command -v k3d >/dev/null 2>&1; then
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

echo "=== Installing kubectl ==="
if ! command -v kubectl >/dev/null 2>&1; then
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
fi

echo "=== Installing Helm ==="
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "=== Deleting old K3d cluster if exists ==="
k3d cluster delete "$CLUSTER_NAME" 2>/dev/null || true

echo "=== Creating K3d cluster ==="
k3d cluster create "$CLUSTER_NAME" \
  --servers 1 \
  --agents 1 \
  --api-port 6550 \
  --k3s-arg "--disable=traefik@server:0" \
  --port "$GITLAB_PORT:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --wait

echo "=== Configuring kubeconfig for user: $LINUX_USER ==="
mkdir -p "/home/$LINUX_USER/.kube"
k3d kubeconfig get "$CLUSTER_NAME" > "$KUBECONFIG_FILE"
chown -R "$LINUX_USER:$LINUX_USER" "/home/$LINUX_USER/.kube"
chmod 600 "$KUBECONFIG_FILE"

export KUBECONFIG="$KUBECONFIG_FILE"

grep -q "KUBECONFIG" "/home/$LINUX_USER/.bashrc" || \
  echo 'export KUBECONFIG="$HOME/.kube/config"' >> "/home/$LINUX_USER/.bashrc"
chown "$LINUX_USER:$LINUX_USER" "/home/$LINUX_USER/.bashrc"

echo "=== Waiting for Kubernetes nodes ==="
run_kubectl wait --for=condition=Ready nodes --all --timeout=300s

echo "=== Adding local hosts entry ==="
grep -q "$GITLAB_HOST" /etc/hosts || echo "127.0.0.1 $GITLAB_HOST argocd.localhost" >> /etc/hosts

echo "=== Adding Helm repositories ==="
helm repo add gitlab https://charts.gitlab.io/ 2>/dev/null || true
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update

echo "=== Installing Argo CD ==="
helm upgrade --install argocd argo/argo-cd \
  -n argocd \
  --create-namespace \
  -f "$ARGO_VALUES_FILE" \
  --set server.ingress.enabled=false \
  --timeout 10m

wait_for_argocd

echo "=== Installing GitLab using values.yaml ==="
helm upgrade --install gitlab gitlab/gitlab \
  -n gitlab \
  --create-namespace \
  -f "$VALUES_FILE" \
  --timeout 30m \
  --set gitlab.webservice.minReplicas=1 \
  --set gitlab.webservice.maxReplicas=1 \
  --set gitlab.sidekiq.minReplicas=1 \
  --set gitlab.sidekiq.maxReplicas=1 \
  --set gitlab.gitlab-shell.minReplicas=1 \
  --set gitlab.gitlab-shell.maxReplicas=1 \
  --set gitlab.kas.minReplicas=1 \
  --set gitlab.kas.maxReplicas=1 \
  --set gitlab-runner.install=false

wait_for_gitlab

echo "=== Getting GitLab root password ==="
GITLAB_PASSWORD="$(run_kubectl -n gitlab get secret gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d)"

echo "=== Adding GitLab repository credentials to Argo CD ==="
run_kubectl -n argocd delete secret gitlab-repo 2>/dev/null || true

run_kubectl -n argocd create secret generic gitlab-repo \
  --from-literal=type=git \
  --from-literal=url="$GITLAB_INTERNAL_REPO" \
  --from-literal=username=root \
  --from-literal=password="$GITLAB_PASSWORD"

run_kubectl -n argocd label secret gitlab-repo \
  argocd.argoproj.io/secret-type=repository \
  --overwrite

echo "=== Applying Argo CD application ==="
run_kubectl apply -f "$APP_FILE"

echo "=== Getting Argo CD admin password ==="
ARGO_PASSWORD="$(run_kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

start_argocd_port_forward

echo "=== Final GitLab test ==="
curl -I -H "Host: $GITLAB_HOST" "http://127.0.0.1:$GITLAB_PORT/users/sign_in"

echo "====================================="
echo "SETUP FINISHED"
echo "====================================="
echo ""
echo "GitLab:"
echo "URL:      http://$GITLAB_HOST:$GITLAB_PORT"
echo "Username: root"
echo "Password: $GITLAB_PASSWORD"
echo ""
echo "Argo CD:"
echo "URL:      http://localhost:$ARGO_PORT"
echo "Username: admin"
echo "Password: $ARGO_PASSWORD"
echo ""
echo "IMPORTANT NEXT STEP:"
echo "1. Open GitLab and create a blank project named: $PROJECT_NAME"
echo "2. Push this bonus folder to:"
echo "   http://$GITLAB_HOST:$GITLAB_PORT/root/$PROJECT_NAME.git"
echo ""
echo "After push, Argo CD will sync the app from local GitLab."
echo "====================================="
