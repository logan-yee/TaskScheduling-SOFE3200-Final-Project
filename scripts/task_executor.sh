#!/bin/bash
# Task Execution Engine
# Executes tasks, captures output, tracks status, and integrates with logging/notifications

# Source utility libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR%/*}/lib"
CONFIG_DIR="${SCRIPT_DIR%/*}/config"

if [[ -f "$LIB_DIR/platform_detect.sh" ]]; then
    source "$LIB_DIR/platform_detect.sh"
    init_platform
fi

if [[ -f "$LIB_DIR/utils.sh" ]]; then
    source "$LIB_DIR/utils.sh"
fi

if [[ -f "$LIB_DIR/error_handler.sh" ]]; then
    source "$LIB_DIR/error_handler.sh"
fi

if [[ -f "$SCRIPT_DIR/logger.sh" ]]; then
    source "$SCRIPT_DIR/logger.sh"
fi

if [[ -f "$SCRIPT_DIR/notification.sh" ]]; then
    source "$SCRIPT_DIR/notification.sh"
fi

# Configuration files
TASKS_CONFIG="${TASKS_CONFIG:-$CONFIG_DIR/tasks.json}"

# Execution state directory
EXECUTION_STATE_DIR="${EXECUTION_STATE_DIR:-${SCRIPT_DIR%/*}/logs/execution_state}"

# Ensure execution state directory exists
ensure_directory "$EXECUTION_STATE_DIR" || {
    echo "ERROR: Failed to create execution state directory" >&2
    exit 1
}

# Get task configuration
get_task_config() {
    local task_id="$1"
    
    if [[ ! -f "$TASKS_CONFIG" ]]; then
        log_error "TASK_EXECUTOR" "Tasks configuration file not found: $TASKS_CONFIG"
        return 1
    fi
    
    if has_jq; then
        # Extract task from array
        jq ".[] | select(.id == \"$task_id\")" "$TASKS_CONFIG" 2>/dev/null
    else
        # Fallback: return empty
        echo "{}"
    fi
}

# Get task field value
get_task_field() {
    local task_id="$1"
    local field="$2"
    
    local task_config=$(get_task_config "$task_id")
    if [[ -z "$task_config" ]] || [[ "$task_config" == "{}" ]]; then
        return 1
    fi
    
    if has_jq; then
        echo "$task_config" | jq -r ".$field // empty" 2>/dev/null
    else
        # Fallback parsing
        echo "$task_config" | grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/.*"\([^"]*\)".*/\1/'
    fi
}

# Validate task configuration
validate_task() {
    local task_id="$1"
    
    # Check if task exists
    local task_config=$(get_task_config "$task_id")
    if [[ -z "$task_config" ]] || [[ "$task_config" == "{}" ]]; then
        log_error "TASK_EXECUTOR" "Task not found: $task_id"
        return 1
    fi
    
    # Check required fields
    local name=$(get_task_field "$task_id" "name")
    local command=$(get_task_field "$task_id" "command")
    
    if [[ -z "$name" ]]; then
        log_error "TASK_EXECUTOR" "Task $task_id missing required field: name"
        return 1
    fi
    
    if [[ -z "$command" ]]; then
        log_error "TASK_EXECUTOR" "Task $task_id missing required field: command"
        return 1
    fi
    
    # Validate command path (if absolute or relative)
    if [[ ! "$command" =~ ^/ ]] && [[ ! "$command" =~ ^[A-Za-z]: ]]; then
        # Relative path - check if it exists in PATH or current directory
        if ! command_exists "$command" && [[ ! -f "$command" ]]; then
            log_warning "TASK_EXECUTOR" "Command may not be executable: $command"
        fi
    fi
    
    return 0
}

# Get execution state file
get_execution_state_file() {
    local task_id="$1"
    local sanitized=$(sanitize_filename "$task_id")
    echo "${EXECUTION_STATE_DIR}/${sanitized}.json"
}

# Update execution state
update_execution_state() {
    local task_id="$1"
    local status="$2"  # running, success, failed
    local exit_code="${3:-0}"
    local start_time="${4:-}"
    local end_time="${5:-}"
    local output_file="${6:-}"
    local error_msg="${7:-}"
    
    local state_file=$(get_execution_state_file "$task_id")
    local timestamp=$(get_timestamp_iso)
    
    local state_json=""
    if has_jq; then
        # Read existing state or create new
        if [[ -f "$state_file" ]]; then
            state_json=$(cat "$state_file")
        else
            state_json="{}"
        fi
        
        # Update state
        state_json=$(echo "$state_json" | jq \
            --arg status "$status" \
            --argjson exit_code "$exit_code" \
            --arg start_time "$start_time" \
            --arg end_time "$end_time" \
            --arg output_file "$output_file" \
            --arg error_msg "$error_msg" \
            --arg timestamp "$timestamp" \
            '.status = $status |
             .exit_code = $exit_code |
             .start_time = $start_time |
             .end_time = $end_time |
             .output_file = $output_file |
             .error_msg = $error_msg |
             .last_updated = $timestamp |
             .execution_count = (.execution_count // 0 | tonumber + 1)' \
            2>/dev/null)
        
        echo "$state_json" > "$state_file"
    else
        # Fallback: simple JSON
        local exec_count=1
        if [[ -f "$state_file" ]]; then
            exec_count=$(grep -o '"execution_count":[0-9]*' "$state_file" | grep -o '[0-9]*' || echo "1")
            exec_count=$((exec_count + 1))
        fi
        
        cat > "$state_file" <<EOF
{
  "status": "$status",
  "exit_code": $exit_code,
  "start_time": "$start_time",
  "end_time": "$end_time",
  "output_file": "$output_file",
  "error_msg": "$error_msg",
  "last_updated": "$timestamp",
  "execution_count": $exec_count
}
EOF
    fi
}

# Get execution state
get_execution_state() {
    local task_id="$1"
    local state_file=$(get_execution_state_file "$task_id")
    
    if [[ -f "$state_file" ]] && has_jq; then
        cat "$state_file"
    else
        echo "{}"
    fi
}

# Execute task command
execute_task_command() {
    local task_id="$1"
    local command="$2"
    local working_dir="${3:-}"
    local timeout="${4:-0}"  # 0 = no timeout
    
    # Get task log file
    local log_file=$(get_task_log_file "$task_id")
    local output_file="${EXECUTION_STATE_DIR}/$(sanitize_filename "$task_id")_output_$(get_timestamp_epoch).txt"
    
    # Change to working directory if specified
    local original_dir=$(pwd)
    if [[ -n "$working_dir" ]] && [[ -d "$working_dir" ]]; then
        cd "$working_dir" || {
            log_error "TASK_EXECUTOR" "Failed to change to working directory: $working_dir"
            return 1
        }
    fi
    
    # Log command execution
    log_info "TASK_EXECUTOR" "Executing command: $command" "$log_file"
    if [[ -n "$working_dir" ]]; then
        log_info "TASK_EXECUTOR" "Working directory: $working_dir" "$log_file"
    fi
    
    # Execute command and capture output
    local start_time=$(get_timestamp_iso)
    local start_epoch=$(get_timestamp_epoch)
    local exit_code=0
    local output=""
    
    if [[ $timeout -gt 0 ]]; then
        # Execute with timeout
        log_info "TASK_EXECUTOR" "Command timeout set to: ${timeout}s" "$log_file"
        output=$(timeout "$timeout" bash -c "$command" 2>&1)
        exit_code=$?
        
        # Check if timeout occurred
        if [[ $exit_code -eq 124 ]]; then
            log_error "TASK_EXECUTOR" "Command timed out after ${timeout}s" "$log_file"
            output="Command execution timed out after ${timeout} seconds"
        fi
    else
        # Execute without timeout
        output=$(eval "$command" 2>&1)
        exit_code=$?
    fi
    
    local end_time=$(get_timestamp_iso)
    local end_epoch=$(get_timestamp_epoch)
    local duration=$((end_epoch - start_epoch))
    
    # Save output to file
    echo "$output" > "$output_file"
    
    # Log output
    if [[ -n "$output" ]]; then
        log_command_output "TASK_EXECUTOR" "$output" "$log_file"
    fi
    
    # Restore original directory
    cd "$original_dir" 2>/dev/null
    
    # Update execution state
    update_execution_state "$task_id" "success" "$exit_code" "$start_time" "$end_time" "$output_file" ""
    
    # Return exit code (non-zero if failed)
    if [[ $exit_code -ne 0 ]]; then
        update_execution_state "$task_id" "failed" "$exit_code" "$start_time" "$end_time" "$output_file" "Command failed with exit code $exit_code"
    fi
    
    echo "$output"
    return $exit_code
}

# Execute task with retry logic
execute_task_with_retry() {
    local task_id="$1"
    
    # Get retry configuration
    local max_attempts=$(get_task_field "$task_id" "retry.max_attempts")
    max_attempts="${max_attempts:-3}"
    
    local initial_delay=$(get_task_field "$task_id" "retry.delay")
    initial_delay="${initial_delay:-1}"
    
    local command=$(get_task_field "$task_id" "command")
    local working_dir=$(get_task_field "$task_id" "working_dir")
    local timeout=$(get_task_field "$task_id" "timeout")
    timeout="${timeout:-0}"
    
    if [[ -z "$command" ]]; then
        log_error "TASK_EXECUTOR" "No command specified for task: $task_id"
        return 1
    fi
    
    # Use error handler's retry mechanism
    if [[ -f "$LIB_DIR/error_handler.sh" ]]; then
        execute_with_retry "$task_id" "$command" "$max_attempts" "$initial_delay" 300 2 true
        return $?
    else
        # Fallback: execute without retry
        execute_task_command "$task_id" "$command" "$working_dir" "$timeout"
        return $?
    fi
}

# Execute task (main function)
execute_task() {
    local task_id="$1"
    local manual_run="${2:-false}"  # true if manually triggered
    
    # Validate task
    if ! validate_task "$task_id"; then
        return 1
    fi
    
    # Get task details
    local task_name=$(get_task_field "$task_id" "name")
    local command=$(get_task_field "$task_id" "command")
    local working_dir=$(get_task_field "$task_id" "working_dir")
    local timeout=$(get_task_field "$task_id" "timeout")
    timeout="${timeout:-0}"
    
    # Log task start
    log_task_start "$task_id" "$task_name"
    
    # Update state to running
    local start_time=$(get_timestamp_iso)
    update_execution_state "$task_id" "running" 0 "$start_time" "" "" ""
    
    # Execute task
    local output=""
    local exit_code=0
    local duration=0
    local start_epoch=$(get_timestamp_epoch)
    
    if [[ -f "$LIB_DIR/error_handler.sh" ]]; then
        # Use retry mechanism
        output=$(execute_task_with_retry "$task_id" 2>&1)
        exit_code=$?
    else
        # Execute directly
        output=$(execute_task_command "$task_id" "$command" "$working_dir" "$timeout" 2>&1)
        exit_code=$?
    fi
    
    local end_epoch=$(get_timestamp_epoch)
    duration=$((end_epoch - start_epoch))
    
    # Determine final status
    local status="success"
    local error_msg=""
    
    if [[ $exit_code -ne 0 ]]; then
        status="failed"
        error_msg="Task execution failed with exit code $exit_code"
        if [[ -n "$output" ]]; then
            error_msg="$error_msg: $(echo "$output" | tail -1)"
        fi
    fi
    
    # Log task end
    log_task_end "$task_id" "$task_name" "$exit_code" "$duration"
    
    # Send notifications
    if [[ -f "$SCRIPT_DIR/notification.sh" ]]; then
        send_task_notification "$task_id" "$task_name" "$status" "$exit_code" "$duration" "$output" "$error_msg"
    fi
    
    # Update final state
    local end_time=$(get_timestamp_iso)
    local output_file=$(get_execution_state "$task_id" | jq -r '.output_file // empty' 2>/dev/null || echo "")
    update_execution_state "$task_id" "$status" "$exit_code" "$start_time" "$end_time" "$output_file" "$error_msg"
    
    # Return exit code
    return $exit_code
}

# Get task status
get_task_status() {
    local task_id="$1"
    
    local state=$(get_execution_state "$task_id")
    
    if has_jq; then
        local status=$(echo "$state" | jq -r '.status // "unknown"' 2>/dev/null)
        local exit_code=$(echo "$state" | jq -r '.exit_code // 0' 2>/dev/null)
        local last_updated=$(echo "$state" | jq -r '.last_updated // "never"' 2>/dev/null)
        local execution_count=$(echo "$state" | jq -r '.execution_count // 0' 2>/dev/null)
        
        echo "Status: $status"
        echo "Exit Code: $exit_code"
        echo "Last Updated: $last_updated"
        echo "Execution Count: $execution_count"
    else
        echo "Status information not available (jq required)"
    fi
}

# List all tasks
list_tasks() {
    if [[ ! -f "$TASKS_CONFIG" ]]; then
        echo "No tasks configuration file found"
        return 1
    fi
    
    if has_jq; then
        jq -r '.[] | "\(.id)\t\(.name)\t\(.schedule.type // "manual")"' "$TASKS_CONFIG" 2>/dev/null | \
        column -t -s $'\t' || \
        jq -r '.[] | "\(.id) - \(.name)"' "$TASKS_CONFIG" 2>/dev/null
    else
        # Fallback: basic listing
        grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$TASKS_CONFIG" | sed 's/.*"\([^"]*\)".*/\1/'
    fi
}

# Check if task is currently running
is_task_running() {
    local task_id="$1"
    local state=$(get_execution_state "$task_id")
    
    if has_jq; then
        local status=$(echo "$state" | jq -r '.status // "unknown"' 2>/dev/null)
        [[ "$status" == "running" ]]
    else
        return 1
    fi
}

# Cancel running task (if possible)
cancel_task() {
    local task_id="$1"
    
    if ! is_task_running "$task_id"; then
        log_warning "TASK_EXECUTOR" "Task $task_id is not currently running"
        return 1
    fi
    
    # Note: This is a simplified implementation
    # In a full implementation, we would track process IDs and kill them
    log_warning "TASK_EXECUTOR" "Task cancellation not fully implemented (would require PID tracking)"
    update_execution_state "$task_id" "cancelled" 130 "" "$(get_timestamp_iso)" "" "Task was cancelled"
    return 0
}

# Export functions
export -f get_task_config
export -f get_task_field
export -f validate_task
export -f get_execution_state_file
export -f update_execution_state
export -f get_execution_state
export -f execute_task_command
export -f execute_task_with_retry
export -f execute_task
export -f get_task_status
export -f list_tasks
export -f is_task_running
export -f cancel_task

