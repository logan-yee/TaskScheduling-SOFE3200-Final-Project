#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
SCRIPTS_DIR="$ROOT_DIR/scripts"
LIB_DIR="$ROOT_DIR/lib"

WORKFLOWS_FILE="$CONFIG_DIR/workflows.json"
TASK_EXECUTOR="$SCRIPTS_DIR/task_executor.sh"

# Optional: source helpers if you already have them
if [[ -f "$SCRIPTS_DIR/logger.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPTS_DIR/logger.sh"
else
  log_info()  { echo "[INFO]  $*"; }
  log_error() { echo "[ERROR] $*" >&2; }
fi

# ---------- JSON helper wrappers (using jq) ----------

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required but not installed."
    exit 1
  fi
}

# Get entire workflow object by id
get_workflow_json() {
  local workflow_id="$1"
  jq -c --arg id "$workflow_id" '
    .workflows[] | select(.id == $id)
  ' "$WORKFLOWS_FILE"
}

# ---------- Dependency resolution + topo sort ----------

# Build arrays:
#  - TASK_IDS: list of task ids
#  - DEPS_<task_id>: space-separated dependencies for that task
build_dependency_graph() {
  local workflow_json="$1"

  TASK_IDS=()
  # Clear any previous dynamic vars
  for v in "${!DEPS_@}"; do unset "$v"; done

  # Collect all task ids
  mapfile -t TASK_IDS < <(jq -r '.tasks[].task_id' <<<"$workflow_json")

  # For each task, build dependency list
  for task in "${TASK_IDS[@]}"; do
    local deps
    deps=$(jq -r --arg tid "$task" '
      .tasks[]
      | select(.task_id == $tid)
      | .dependencies[]? // empty
    ' <<<"$workflow_json" | tr '\n' ' ')
    # Create variable: DEPS_<task>
    local var="DEPS_${task}"
    printf -v "$var" '%s' "$deps"
  done
}

# Topological sort with parallel “layers”
# Produces EXECUTION_LAYERS: array of "taskA taskB" (space-separated tasks per layer)
topological_sort_layers() {
  EXECUTION_LAYERS=()

  # remaining_deps[task] = count
  declare -gA remaining_deps=()
  declare -gA done_task=()
  local total_tasks=${#TASK_IDS[@]}

  for task in "${TASK_IDS[@]}"; do
    local var="DEPS_${task}"
    local deps="${!var:-}"
    if [[ -z "$deps" ]]; then
      remaining_deps["$task"]=0
    else
      # count words
      local count=0
      for d in $deps; do
        ((count++))
      done
      remaining_deps["$task"]=$count
    fi
    done_task["$task"]=0
  done

  local completed=0

  while (( completed < total_tasks )); do
    local ready=()
    # Find tasks with 0 remaining deps and not done
    for task in "${TASK_IDS[@]}"; do
      if (( done_task["$task"] == 0 )) && (( remaining_deps["$task"] == 0 )); then
        ready+=("$task")
      fi
    done

    if ((${#ready[@]} == 0)); then
      log_error "Cycle detected or unresolved dependencies in workflow."
      return 1
    fi

    # Mark ready tasks as done for dependency counting
    local layer=""
    for task in "${ready[@]}"; do
      done_task["$task"]=1
      ((completed++))
      layer+="$task "
      # Decrease dep count for tasks depending on this one
      for t2 in "${TASK_IDS[@]}"; do
        local var="DEPS_${t2}"
        local deps="${!var:-}"
        for d in $deps; do
          if [[ "$d" == "$task" ]]; then
            ((remaining_deps["$t2"]--))
          fi
        done
      done
    done

    EXECUTION_LAYERS+=("${layer% }")  # trim trailing space
  done

  return 0
}

# ---------- Execution engine (parallel per layer) ----------

run_workflow_once() {
  local workflow_json="$1"

  build_dependency_graph "$workflow_json"
  if ! topological_sort_layers; then
    log_error "Cannot execute workflow due to invalid dependency graph."
    return 1
  fi

  log_info "Execution layers: ${#EXECUTION_LAYERS[@]}"

  # For each layer, run tasks in parallel, then wait
  for layer in "${EXECUTION_LAYERS[@]}"; do
    log_info "Running layer: $layer"

    declare -a pids=()
    declare -A pid_to_task=()

    for task_id in $layer; do
      log_info "Starting task '$task_id'..."
      # Run task in background using task_executor
      # You may need to adjust args based on your task_executor.sh
      "$TASK_EXECUTOR" "$task_id" &
      local pid=$!
      pids+=("$pid")
      pid_to_task["$pid"]="$task_id"
    done

    # Wait for all tasks in this layer
    local failed=0
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        log_error "Task '${pid_to_task[$pid]}' failed (exit code $?)."
        failed=1
      fi
    done

    if (( failed != 0 )); then
      log_error "One or more tasks in layer failed; aborting this workflow attempt."
      return 1
    fi
  done

  log_info "Workflow completed successfully for this attempt."
  return 0
}

run_workflow_with_retries() {
  local workflow_id="$1"

  require_jq

  if [[ ! -f "$WORKFLOWS_FILE" ]]; then
    log_error "Workflows file not found: $WORKFLOWS_FILE"
    exit 1
  fi

  local workflow_json
  workflow_json="$(get_workflow_json "$workflow_id")"

  if [[ -z "$workflow_json" ]]; then
    log_error "Workflow '$workflow_id' not found in $WORKFLOWS_FILE"
    exit 1
  fi

  local max_attempts
  max_attempts="$(jq -r '.retry.max_attempts // 1' <<<"$workflow_json")"
  if [[ "$max_attempts" == "null" || -z "$max_attempts" ]]; then
    max_attempts=1
  fi

  log_info "Running workflow '$workflow_id' (max_attempts=$max_attempts)"

  local attempt=1
  while (( attempt <= max_attempts )); do
    log_info "Workflow attempt $attempt/$max_attempts"
    if run_workflow_once "$workflow_json"; then
      log_info "Workflow '$workflow_id' succeeded on attempt $attempt."
      return 0
    fi
    ((attempt++))
    if (( attempt <= max_attempts )); then
      log_info "Retrying workflow '$workflow_id'..."
      # Optional: sleep or exponential backoff here
      sleep 1
    fi
  done

  log_error "Workflow '$workflow_id' failed after $max_attempts attempts."
  return 1
}

# ---------- CLI ----------

usage() {
  cat <<EOF
Usage:
  $(basename "$0") run-workflow <workflow_id>

Description:
  run-workflow   Execute the given workflow based on config/workflows.json
EOF
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
    run-workflow)
      if [[ $# -lt 2 ]]; then
        usage
        exit 1
      fi
      local wf_id="$2"
      run_workflow_with_retries "$wf_id"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

# Only run main if this script is executed directly, not when it's sourced
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi