#!/bin/bash
# Logging System
# Structured logging with timestamps, log rotation, and log levels

# Source utility libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR%/*}/lib"

if [[ -f "$LIB_DIR/utils.sh" ]]; then
    source "$LIB_DIR/utils.sh"
fi

# Log levels
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARNING=2
LOG_LEVEL_ERROR=3

# Default log directory
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR%/*}/logs}"
LOG_LEVEL="${LOG_LEVEL:-$LOG_LEVEL_INFO}"
MAX_LOG_SIZE="${MAX_LOG_SIZE:-10485760}"  # 10MB default
MAX_LOG_FILES="${MAX_LOG_FILES:-10}"

# Ensure log directory exists
ensure_directory "$LOG_DIR" || {
    echo "ERROR: Failed to create log directory: $LOG_DIR" >&2
    exit 1
}

# Get log level name
get_log_level_name() {
    local level="$1"
    case "$level" in
        $LOG_LEVEL_DEBUG) echo "DEBUG" ;;
        $LOG_LEVEL_INFO) echo "INFO" ;;
        $LOG_LEVEL_WARNING) echo "WARNING" ;;
        $LOG_LEVEL_ERROR) echo "ERROR" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# Get log level number from name
get_log_level_number() {
    local level_name="$1"
    case "$(echo "$level_name" | tr '[:lower:]' '[:upper:]')" in
        DEBUG) echo $LOG_LEVEL_DEBUG ;;
        INFO) echo $LOG_LEVEL_INFO ;;
        WARNING|WARN) echo $LOG_LEVEL_WARNING ;;
        ERROR) echo $LOG_LEVEL_ERROR ;;
        *) echo $LOG_LEVEL_INFO ;;
    esac
}

# Format log message
format_log_message() {
    local level="$1"
    local component="$2"
    local message="$3"
    local timestamp=$(get_timestamp)
    local level_name=$(get_log_level_name "$level")
    
    echo "[$timestamp] [$level_name] [$component] $message"
}

# Write log message to file
write_log_file() {
    local log_file="$1"
    local message="$2"
    
    # Ensure log directory exists
    local log_dir=$(dirname "$log_file")
    ensure_directory "$log_dir" || return 1
    
    # Append to log file
    echo "$message" >> "$log_file" 2>/dev/null || return 1
    
    # Check if rotation is needed
    rotate_log_if_needed "$log_file"
}

# Rotate log file if it exceeds size limit
rotate_log_if_needed() {
    local log_file="$1"
    
    if [[ ! -f "$log_file" ]]; then
        return 0
    fi
    
    local file_size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0)
    
    if [[ $file_size -ge $MAX_LOG_SIZE ]]; then
        rotate_log "$log_file"
    fi
}

# Rotate log file
rotate_log() {
    local log_file="$1"
    local log_dir=$(dirname "$log_file")
    local log_base=$(basename "$log_file")
    
    # Remove oldest log if we've reached max files
    local oldest_log="${log_file}.${MAX_LOG_FILES}"
    if [[ -f "$oldest_log" ]]; then
        rm -f "$oldest_log"
    fi
    
    # Rotate existing logs
    for ((i=$MAX_LOG_FILES; i>=2; i--)); do
        local old_file="${log_file}.$((i-1))"
        local new_file="${log_file}.$i"
        if [[ -f "$old_file" ]]; then
            mv "$old_file" "$new_file" 2>/dev/null
        fi
    done
    
    # Move current log to .1
    if [[ -f "$log_file" ]]; then
        mv "$log_file" "${log_file}.1" 2>/dev/null
    fi
}

# Core logging function
log_message() {
    local level="$1"
    local component="$2"
    local message="$3"
    local log_file="${4:-}"
    
    # Check if we should log this level
    if [[ $level -lt $LOG_LEVEL ]]; then
        return 0
    fi
    
    local formatted=$(format_log_message "$level" "$component" "$message")
    
    # Write to specific log file if provided
    if [[ -n "$log_file" ]]; then
        write_log_file "$log_file" "$formatted"
    fi
    
    # Also write to main log
    local main_log="${LOG_DIR}/scheduler.log"
    write_log_file "$main_log" "$formatted"
    
    # Output to stderr for ERROR and WARNING levels
    if [[ $level -ge $LOG_LEVEL_WARNING ]]; then
        echo "$formatted" >&2
    fi
    
    return 0
}

# Log debug message
log_debug() {
    local component="$1"
    shift
    local message="$@"
    log_message $LOG_LEVEL_DEBUG "$component" "$message" "$@"
}

# Log info message
log_info() {
    local component="$1"
    shift
    local message="$@"
    log_message $LOG_LEVEL_INFO "$component" "$message" "$@"
}

# Log warning message
log_warning() {
    local component="$1"
    shift
    local message="$@"
    log_message $LOG_LEVEL_WARNING "$component" "$message" "$@"
}

# Log error message
log_error() {
    local component="$1"
    shift
    local message="$@"
    log_message $LOG_LEVEL_ERROR "$component" "$message" "$@"
}

# Get task-specific log file path
get_task_log_file() {
    local task_id="$1"
    local sanitized=$(sanitize_filename "$task_id")
    echo "${LOG_DIR}/tasks/${sanitized}.log"
}

# Get workflow-specific log file path
get_workflow_log_file() {
    local workflow_id="$1"
    local sanitized=$(sanitize_filename "$workflow_id")
    echo "${LOG_DIR}/workflows/${sanitized}.log"
}

# Log task execution start
log_task_start() {
    local task_id="$1"
    local task_name="$2"
    local log_file=$(get_task_log_file "$task_id")
    log_info "TASK" "Starting task: $task_id ($task_name)" "$log_file"
}

# Log task execution end
log_task_end() {
    local task_id="$1"
    local task_name="$2"
    local exit_code="$3"
    local duration="$4"
    local log_file=$(get_task_log_file "$task_id")
    
    if [[ $exit_code -eq 0 ]]; then
        log_info "TASK" "Task completed: $task_id ($task_name) - Exit code: $exit_code, Duration: ${duration}s" "$log_file"
    else
        log_error "TASK" "Task failed: $task_id ($task_name) - Exit code: $exit_code, Duration: ${duration}s" "$log_file"
    fi
}

# Log workflow execution start
log_workflow_start() {
    local workflow_id="$1"
    local workflow_name="$2"
    local log_file=$(get_workflow_log_file "$workflow_id")
    log_info "WORKFLOW" "Starting workflow: $workflow_id ($workflow_name)" "$log_file"
}

# Log workflow execution end
log_workflow_end() {
    local workflow_id="$1"
    local workflow_name="$2"
    local status="$3"  # success, failed, partial
    local duration="$4"
    local log_file=$(get_workflow_log_file "$workflow_id")
    
    case "$status" in
        "success")
            log_info "WORKFLOW" "Workflow completed: $workflow_id ($workflow_name) - Status: $status, Duration: ${duration}s" "$log_file"
            ;;
        "failed")
            log_error "WORKFLOW" "Workflow failed: $workflow_id ($workflow_name) - Status: $status, Duration: ${duration}s" "$log_file"
            ;;
        "partial")
            log_warning "WORKFLOW" "Workflow partially completed: $workflow_id ($workflow_name) - Status: $status, Duration: ${duration}s" "$log_file"
            ;;
    esac
}

# Log command output
log_command_output() {
    local component="$1"
    local output="$2"
    local log_file="${3:-}"
    
    if [[ -z "$output" ]]; then
        return 0
    fi
    
    # Split output into lines and log each
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            log_info "$component" "OUTPUT: $line" "$log_file"
        fi
    done <<< "$output"
}

# Read log file (with optional tail)
read_log_file() {
    local log_file="$1"
    local lines="${2:-100}"
    
    if [[ ! -f "$log_file" ]]; then
        echo "Log file not found: $log_file" >&2
        return 1
    fi
    
    # Show last N lines
    tail -n "$lines" "$log_file" 2>/dev/null || cat "$log_file"
}

# Search log file
search_log_file() {
    local log_file="$1"
    local pattern="$2"
    local lines="${3:-100}"
    
    if [[ ! -f "$log_file" ]]; then
        echo "Log file not found: $log_file" >&2
        return 1
    fi
    
    grep -i "$pattern" "$log_file" | tail -n "$lines" 2>/dev/null
}

# Get log statistics
get_log_stats() {
    local log_file="$1"
    
    if [[ ! -f "$log_file" ]]; then
        echo "Log file not found: $log_file" >&2
        return 1
    fi
    
    local total_lines=$(wc -l < "$log_file" 2>/dev/null || echo 0)
    local error_count=$(grep -c "\[ERROR\]" "$log_file" 2>/dev/null || echo 0)
    local warning_count=$(grep -c "\[WARNING\]" "$log_file" 2>/dev/null || echo 0)
    local info_count=$(grep -c "\[INFO\]" "$log_file" 2>/dev/null || echo 0)
    local file_size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0)
    
    echo "Total lines: $total_lines"
    echo "Errors: $error_count"
    echo "Warnings: $warning_count"
    echo "Info: $info_count"
    echo "File size: $file_size bytes"
}

# Clean old log files
clean_old_logs() {
    local days="${1:-30}"
    local cutoff_date=$(date -d "$days days ago" +%s 2>/dev/null || date -v-${days}d +%s 2>/dev/null || echo 0)
    
    find "$LOG_DIR" -type f -name "*.log*" -mtime +$days -delete 2>/dev/null
    log_info "LOGGER" "Cleaned log files older than $days days"
}

# Set log level
set_log_level() {
    local level="$1"
    if [[ "$level" =~ ^[0-9]+$ ]]; then
        LOG_LEVEL=$level
    else
        LOG_LEVEL=$(get_log_level_number "$level")
    fi
    log_info "LOGGER" "Log level set to: $(get_log_level_name $LOG_LEVEL)"
}

# Initialize logging system
init_logger() {
    ensure_directory "$LOG_DIR" || return 1
    ensure_directory "${LOG_DIR}/tasks" || return 1
    ensure_directory "${LOG_DIR}/workflows" || return 1
    
    log_info "LOGGER" "Logging system initialized - Log directory: $LOG_DIR"
    return 0
}

# Export functions
export -f log_message
export -f log_debug
export -f log_info
export -f log_warning
export -f log_error
export -f get_task_log_file
export -f get_workflow_log_file
export -f log_task_start
export -f log_task_end
export -f log_workflow_start
export -f log_workflow_end
export -f log_command_output
export -f read_log_file
export -f search_log_file
export -f get_log_stats
export -f clean_old_logs
export -f set_log_level
export -f init_logger
export -f get_log_level_name
export -f get_log_level_number
export -f rotate_log
export -f rotate_log_if_needed

# Initialize on source
init_logger

