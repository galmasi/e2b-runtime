#!/usr/bin/env bash
#
# Deploy an E2B development environment on a target machine.
#
# The script is organized into stages that can be run individually or all at
# once.  Each stage is idempotent: re-running it is safe.
#
# Usage:
#   deploy-dev.sh [options] <host>
#
# Options:
#   -b BRANCH    Branch to check out (default: current branch of this repo)
#   -s STAGE     Run only this stage (can be repeated: -s prep -s infra)
#                Stages: prep, artifacts, infra, migrate, services, template, verify
#   -t SESSION   tmux session name (default: e2b)
#   -h           Show this help
#
# Prerequisites on the local machine:
#   - ssh access to <host> (key-based, no password prompts)
#   - This script is run from the repo root (or REPO_ROOT is set)
#
# Prerequisites on the target:
#   - Linux with KVM support (/dev/kvm)
#   - Docker Engine 24+ with Compose v2
#   - Node.js (for template builds)
#   - tmux
#   - Internet access (for Go install, GCS downloads, Docker pulls)

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BRANCH="${BRANCH:-$(git -C "$REPO_ROOT" branch --show-current)}"
TMUX_SESSION="e2b"
STAGES=()

GO_VERSION="$(sed -n 's/^go //p' "$REPO_ROOT/go.work")"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
usage() {
    sed -n '3,/^$/s/^# //p' "$0"
    exit "${1:-0}"
}

while getopts "b:s:t:h" opt; do
    case "$opt" in
        b) BRANCH="$OPTARG" ;;
        s) STAGES+=("$OPTARG") ;;
        t) TMUX_SESSION="$OPTARG" ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))

HOST="${1:?Usage: deploy-dev.sh [options] <host>}"

if [[ ${#STAGES[@]} -eq 0 ]]; then
    STAGES=(prep artifacts infra migrate services template verify)
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m>>>\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; }
die()  { err "$@"; exit 1; }

# Run a command on the target via ssh.  Exports PATH so Go and snap binaries
# are always available, and sets the working directory to the repo.
remote() {
    ssh "$HOST" "export PATH=/usr/local/go/bin:/snap/bin:\$PATH; cd ~/e2b-runtime && $*"
}

should_run() {
    local stage="$1"
    for s in "${STAGES[@]}"; do
        [[ "$s" == "$stage" ]] && return 0
    done
    return 1
}

wait_for_health() {
    local url="$1" label="$2" max="${3:-60}"
    local elapsed=0
    log "Waiting for $label ($url) ..."
    while ! ssh "$HOST" "curl -sf '$url'" >/dev/null 2>&1; do
        sleep 3
        elapsed=$((elapsed + 3))
        if [[ $elapsed -ge $max ]]; then
            die "$label did not become healthy within ${max}s"
        fi
    done
    log "$label is healthy"
}

# ---------------------------------------------------------------------------
# Stage: prep — OS prerequisites, Go, repo checkout
# ---------------------------------------------------------------------------
stage_prep() {
    log "=== Stage: prep ==="

    # Ensure build-essential is present (provides make, gcc, etc.)
    log "Installing build-essential (if missing)..."
    ssh "$HOST" 'dpkg -s build-essential >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y -qq build-essential; }' 2>&1 | tail -1

    # KVM check
    ssh "$HOST" 'test -e /dev/kvm' || die "/dev/kvm not found on $HOST — enable KVM / nested virtualization"

    # NBD kernel module
    log "Loading NBD kernel module..."
    ssh "$HOST" 'lsmod | grep -q "^nbd " || sudo modprobe nbd nbds_max=512'
    ssh "$HOST" 'grep -q nbd /etc/modules-load.d/nbd.conf 2>/dev/null || echo "nbd nbds_max=512" | sudo tee /etc/modules-load.d/nbd.conf >/dev/null'

    # Huge pages — disabled for high-density mode (VMs use regular pages).
    # Release any previously reserved hugepages so the memory is available for
    # regular-page VM backing.
    log "Releasing huge pages (high-density mode, VMs use regular pages)..."
    ssh "$HOST" 'current=$(grep HugePages_Total /proc/meminfo | awk "{print \$2}"); [ "$current" -eq 0 ] || sudo sysctl -w vm.nr_hugepages=0 >/dev/null'
    ssh "$HOST" 'echo "vm.nr_hugepages=0" | sudo tee /etc/sysctl.d/99-hugepages.conf >/dev/null'

    # Install Go
    if ssh "$HOST" "test -x /usr/local/go/bin/go && /usr/local/go/bin/go version | grep -q 'go${GO_VERSION} '" 2>/dev/null; then
        log "Go $GO_VERSION already installed"
    else
        log "Installing Go $GO_VERSION..."
        ssh "$HOST" "curl -fsSL -o /tmp/go.tar.gz 'https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz' \
            && sudo rm -rf /usr/local/go \
            && sudo tar -C /usr/local -xzf /tmp/go.tar.gz \
            && rm /tmp/go.tar.gz"
        ssh "$HOST" 'echo "export PATH=\$PATH:/usr/local/go/bin" | sudo tee /etc/profile.d/go.sh >/dev/null'
    fi
    ssh "$HOST" '/usr/local/go/bin/go version'

    # Install gsutil via snap (needed for artifact downloads)
    if ssh "$HOST" 'which gsutil >/dev/null 2>&1'; then
        log "gsutil already installed"
    else
        log "Installing Google Cloud CLI (for gsutil)..."
        ssh "$HOST" 'sudo snap install google-cloud-cli --classic'
    fi

    # Clone or update the repo
    if ssh "$HOST" 'test -d ~/e2b-runtime/.git'; then
        log "Updating repo to branch $BRANCH..."
        remote "git fetch origin '$BRANCH' && git checkout '$BRANCH' && git pull origin '$BRANCH'"
    else
        log "Cloning repo..."
        ssh "$HOST" "git clone https://github.com/galmasi/e2b-runtime.git ~/e2b-runtime"
        remote "git checkout '$BRANCH'"
    fi

    log "prep done"
}

# ---------------------------------------------------------------------------
# Stage: artifacts — download kernels, firecrackers, busybox
# ---------------------------------------------------------------------------
stage_artifacts() {
    log "=== Stage: artifacts ==="

    log "Downloading kernels..."
    remote 'make download-public-kernels 2>&1 | tail -1'

    log "Downloading firecrackers..."
    remote 'make download-public-firecrackers 2>&1 | tail -1'

    log "Fetching busybox..."
    remote 'make -C packages/orchestrator fetch-busybox 2>&1 | tail -3'

    # Verify
    remote 'ls packages/fc-kernels/ | head -3'
    remote 'ls packages/fc-versions/builds/ | head -3'
    remote 'ls packages/orchestrator/.busybox/*/amd64/busybox'

    log "artifacts done"
}

# ---------------------------------------------------------------------------
# Stage: infra — bring up postgres, clickhouse, redis, observability
# ---------------------------------------------------------------------------
stage_infra() {
    log "=== Stage: infra ==="

    # Start infrastructure in the background (docker compose up follows logs
    # and never exits, so we detach it).
    log "Starting Docker Compose infrastructure..."
    remote 'docker compose -f packages/local-dev/docker-compose.yaml up -d'

    # Wait for the three required stores to be ready.
    log "Waiting for Postgres..."
    local elapsed=0
    while ! ssh "$HOST" 'docker exec local-dev-postgres-1 pg_isready -U postgres' >/dev/null 2>&1; do
        sleep 2; elapsed=$((elapsed + 2))
        [[ $elapsed -ge 60 ]] && die "Postgres did not become ready"
    done

    log "Waiting for Redis..."
    elapsed=0
    while ! ssh "$HOST" 'docker exec local-dev-redis-1 redis-cli ping' 2>/dev/null | grep -q PONG; do
        sleep 2; elapsed=$((elapsed + 2))
        [[ $elapsed -ge 60 ]] && die "Redis did not become ready"
    done

    log "Waiting for ClickHouse..."
    elapsed=0
    while ! ssh "$HOST" "docker exec local-dev-clickhouse-1 clickhouse-client --user clickhouse --password clickhouse --query 'SELECT 1'" >/dev/null 2>&1; do
        sleep 2; elapsed=$((elapsed + 2))
        [[ $elapsed -ge 60 ]] && die "ClickHouse did not become ready"
    done

    log "infra done"
}

# ---------------------------------------------------------------------------
# Stage: migrate — run DB migrations, build envd, seed database
# ---------------------------------------------------------------------------
stage_migrate() {
    log "=== Stage: migrate ==="

    log "Running Postgres migrations..."
    remote 'make -C packages/db migrate-local 2>&1 | tail -3'

    log "Running ClickHouse migrations..."
    remote 'make -C packages/clickhouse migrate-local 2>&1 | tail -3'

    log "Building envd..."
    remote 'make -C packages/envd build 2>&1 | tail -1'
    remote 'ls -l packages/envd/bin/envd'

    log "Seeding database..."
    remote 'make -C packages/local-dev seed-database 2>&1 | tail -1'

    log "migrate done"
}

# ---------------------------------------------------------------------------
# Stage: services — start API, orchestrator, client-proxy in tmux
# ---------------------------------------------------------------------------
stage_services() {
    log "=== Stage: services ==="

    # Kill any existing session with the same name.
    ssh "$HOST" "tmux kill-session -t $TMUX_SESSION 2>/dev/null || true"

    # Create session with the api window.
    ssh "$HOST" "tmux new-session -d -s $TMUX_SESSION -n api -x 200 -y 50"

    # --- API ---
    log "Starting API server..."
    ssh "$HOST" "tmux send-keys -t $TMUX_SESSION:api \
        'export PATH=/usr/local/go/bin:/snap/bin:\$PATH; cd ~/e2b-runtime && make -C packages/api run-local' Enter"

    # --- Orchestrator ---
    log "Starting orchestrator (build-debug + run-local)..."
    ssh "$HOST" "tmux new-window -t $TMUX_SESSION -n orchestrator"
    ssh "$HOST" "tmux send-keys -t $TMUX_SESSION:orchestrator \
        'export PATH=/usr/local/go/bin:/snap/bin:\$PATH; cd ~/e2b-runtime && make -C packages/orchestrator build-debug && sudo make -C packages/orchestrator run-local' Enter"

    # --- Client proxy ---
    log "Starting client proxy..."
    ssh "$HOST" "tmux new-window -t $TMUX_SESSION -n client-proxy"
    ssh "$HOST" "tmux send-keys -t $TMUX_SESSION:client-proxy \
        'export PATH=/usr/local/go/bin:/snap/bin:\$PATH; cd ~/e2b-runtime && make -C packages/client-proxy run-local' Enter"

    # --- Wait for health ---
    wait_for_health "http://localhost:5008/health" "orchestrator" 180
    wait_for_health "http://localhost:3000/health" "API" 180
    wait_for_health "http://localhost:3003/health" "client-proxy" 120

    log "services done — tmux session: $TMUX_SESSION (windows: api, orchestrator, client-proxy)"
}

# ---------------------------------------------------------------------------
# Stage: template — build the base sandbox template
# ---------------------------------------------------------------------------
stage_template() {
    log "=== Stage: template ==="

    log "Building base template (this takes ~2 min)..."
    remote 'set -o pipefail; make -C packages/shared/scripts local-build-base-template 2>&1 | grep -E "^\[|Build finished|error|make:"' \
        || die "Base template build failed"

    log "template done"
}

# ---------------------------------------------------------------------------
# Stage: verify — create a sandbox and confirm it works
# ---------------------------------------------------------------------------
stage_verify() {
    log "=== Stage: verify ==="

    log "Health checks..."
    wait_for_health "http://localhost:3000/health" "API" 10
    wait_for_health "http://localhost:5008/health" "orchestrator" 10
    wait_for_health "http://localhost:3003/health" "client-proxy" 10

    log "Creating test sandbox..."
    local response
    response=$(ssh "$HOST" "curl -sf -X POST http://localhost:3000/sandboxes \
        -H 'X-API-Key: e2b_53ae1fed82754c17ad8077fbc8bcdd90' \
        -H 'Content-Type: application/json' \
        -d '{\"templateID\": \"base\"}'")

    local sandbox_id
    sandbox_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['sandboxID'])" 2>/dev/null) \
        || die "Failed to create sandbox. Response: $response"

    log "Sandbox created: $sandbox_id"

    cat <<-EOF

	=== Deployment verified ===

	tmux session : ssh $HOST -t tmux attach -t $TMUX_SESSION
	API          : http://$HOST:3000   (health: /health)
	Orchestrator : http://$HOST:5008   (health: /health)
	Client Proxy : http://$HOST:3003   (health: /health)
	Sandbox URL  : http://$HOST:3002

	Client config:
	  E2B_API_KEY=e2b_53ae1fed82754c17ad8077fbc8bcdd90
	  E2B_API_URL=http://$HOST:3000
	  E2B_SANDBOX_URL=http://$HOST:3002
	EOF

    log "verify done"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "Deploying branch '$BRANCH' to $HOST"
log "Stages: ${STAGES[*]}"
echo

should_run prep      && stage_prep
should_run artifacts && stage_artifacts
should_run infra     && stage_infra
should_run migrate   && stage_migrate
should_run services  && stage_services
should_run template  && stage_template
should_run verify    && stage_verify

echo
log "All requested stages complete."
