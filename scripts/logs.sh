#!/usr/bin/env bash
# Show logs of a cluster node.
#
#   bash scripts/logs.sh              # server, last 200 lines
#   bash scripts/logs.sh agent -f     # follow the agent
#   bash scripts/logs.sh lb
#   bash scripts/logs.sh tools
#   bash scripts/logs.sh all

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

NODE="server"
FOLLOW=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    server|agent|lb|tools|all) NODE="$1" ;;
    -f|--follow) FOLLOW=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

if ! cluster_exists; then
  die "Cluster '${CLUSTER_NAME}' does not exist."
fi

container_for() {
  case "$1" in
    server) printf 'k3d-%s-server-0\n' "$CLUSTER_NAME" ;;
    agent)  printf 'k3d-%s-agent-0\n' "$CLUSTER_NAME" ;;
    lb)     printf 'k3d-%s-serverlb\n' "$CLUSTER_NAME" ;;
    tools)  printf 'k3d-%s-tools\n' "$CLUSTER_NAME" ;;
  esac
}

docker_logs() {
  local c="$1"
  if [[ "$FOLLOW" == "1" ]]; then
    docker logs -f --tail 200 "$c"
  else
    docker logs --tail 200 "$c"
  fi
}

if [[ "$NODE" == "all" ]]; then
  for n in server agent lb; do
    printf '\n===== %s =====\n' "$n"
    docker_logs "$(container_for "$n")" 2>&1 | tail -100
  done
else
  docker_logs "$(container_for "$NODE")"
fi
