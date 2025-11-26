#!/bin/bash
# Error Handling and Retry System
# Implements retry logic with exponential backoff and error tracking

# Source utility libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/utils.sh" ]]; then
    source "$SCRIPT_DIR/utils.sh"
fi

if [[ -f "$SCRIPT_DIR/../scripts/logger.sh" ]]; then
    source "$SCRIPT_DIR/../scripts/logger.sh"
fi

# Default retry configuration
DEFAULT_MAX_ATTEMPTS=3
DEFAULT_INITIAL_DELAY=1
DEFAULT_MAX_DELAY=300
DEFAULT_BACKOFF_MULTIPLIER=2
DEFAULT_JITTER=true

# Retry state tracking directory
RETRY_STATE_DIR="${RETRY_STATE_DIR:-${SCRIPT_DIR%/*}/logs/retry_state}"

# Ensure retry state directory exists
ensure_directory "$RETRY_STATE_DIR" || {
    echo "ERROR: Failed to create retry state directory: $RETRY_STATE_DIR" >&2
    exit 1
}

# Get retry state file path
get_retry_state_file() {
    local entity_id="$1"  # task_id or workflow_id
    local sanitized=$(sanitize_filename "$entity_id")
    echo "${RETRY_STATE_DIR}/${sanitized}.json"
}

# Initialize retry state
init_retry_state() {
    local entity_id="$1"
    local state_file=$(get_retry_state_file "$entity_id")
    
    if [[ ! -f "$state_file" ]]; then
        echo "{\"attempts\": 0, \"last_attempt\": null, \"last_error\": null, \"permanent_failure\": false}" > "$state_file"
    fi
}

# Get retry state
get_retry_state() {
    local entity_id="$1"
    local state_file=$(get_retry_state_file "$entity_id")
    
    if [[ ! -f "$state_file" ]]; then
        init_retry_state "$entity_id"
    fi
    
    if has_jq; then
        cat "$state_file" 2>/dev/null
    else
        # Fallback: return basic state
        echo "{\"attempts\": 0, \"last_attempt\": null, \"last_error\": null, \"permanent_failure\": false}"
    fi
}

# Update retry state
update_retry_state() {
    local entity_id="$1"
    local attempts="$2"
    local error_msg="${3:-}"
    local permanent_failure="${4:-false}"
    local state_file=$(get_retry_state_file "$entity_id")
    
    local timestamp=$(get_timestamp_iso)
    
    if has_jq; then
        local temp_file="${state_file}.tmp.$$"
        jq \
            --arg attempts "$attempts" \
            --arg timestamp "$timestamp" \
            --arg error "$error_msg" \
            --argjson permanent "$permanent_failure" \
            '.attempts = ($attempts | tonumber) | 
             .last_attempt = $timestamp | 
             .last_error = $error | 
             .permanent_failure = $permanent' \
            "$state_file" > "$temp_file" 2>/dev/null && mv "$temp_file" "$state_file"
    else
        # Fallback: simple JSON update
        echo "{\"attempts\": $attempts, \"last_attempt\": \"$timestamp\", \"last_error\": \"$error_msg\", \"permanent_failure\": $permanent_failure}" > "$state_file"
    fi
}

# Reset retry state (on success)
reset_retry_state() {
    local entity_id="$1"
    local state_file=$(get_retry_state_file "$entity_id")
    
    update_retry_state "$entity_id" 0 "" false
    log_debug "ERROR_HANDLER" "Reset retry state for: $entity_id"
}

# Check if entity has permanent failure
is_permanent_failure() {
    local entity_id="$1"
    local state=$(get_retry_state "$entity_id")
    
    if has_jq; then
        local permanent=$(echo "$state" | jq -r '.permanent_failure' 2>/dev/null)
        [[ "$permanent" == "true" ]]
    else
        # Fallback: check if attempts exceed a threshold
        local attempts=$(echo "$state" | grep -o '"attempts":[0-9]*' | grep -o '[0-9]*' || echo "0")
        [[ $attempts -ge 10 ]]  # Arbitrary threshold for fallback
    fi
}

# Calculate exponential backoff delay
calculate_backoff_delay() {
    local attempt="$1"
    local initial_delay="${2:-$DEFAULT_INITIAL_DELAY}"
    local max_delay="${3:-$DEFAULT_MAX_DELAY}"
    local multiplier="${4:-$DEFAULT_BACKOFF_MULTIPLIER}"
    local use_jitter="${5:-$DEFAULT_JITTER}"
    
    # Calculate base delay: initial_delay * (multiplier ^ (attempt - 1))
    local base_delay=$(echo "$initial_delay * $multiplier^($attempt - 1)" | bc 2>/dev/null)
    
    # If bc is not available, use awk
    if [[ -z "$base_delay" ]]; then
        base_delay=$(awk "BEGIN {printf \"%.0f\", $initial_delay * ($multiplier ^ ($attempt - 1))}")
    fi
    
    # Cap at max_delay
    if [[ $(echo "$base_delay > $max_delay" | bc 2>/dev/null || echo "0") == "1" ]]; then
        base_delay=$max_delay
    fi
    
    # Add jitter if enabled (random 0-20% of delay)
    if [[ "$use_jitter" == "true" ]]; then
        local jitter=$(awk "BEGIN {srand(); printf \"%.0f\", $base_delay * 0.2 * rand()}")
        base_delay=$((base_delay + jitter))
    fi
    
    # Ensure minimum delay of 1 second
    if [[ $base_delay -lt 1 ]]; then
        base_delay=1
    fi
    
    echo $base_delay
}

# Wait with exponential backoff
wait_with_backoff() {
    local attempt="$1"
    local initial_delay="${2:-$DEFAULT_INITIAL_DELAY}"
    local max_delay="${3:-$DEFAULT_MAX_DELAY}"
    local multiplier="${4:-$DEFAULT_BACKOFF_MULTIPLIER}"
    local use_jitter="${5:-$DEFAULT_JITTER}"
    
    local delay=$(calculate_backoff_delay "$attempt" "$initial_delay" "$max_delay" "$multiplier" "$use_jitter")
    
    log_info "ERROR_HANDLER" "Waiting ${delay}s before retry attempt $attempt (exponential backoff)"
    sleep "$delay"
}

# Execute command with retry
execute_with_retry() {
    local entity_id="$1"
    local command="$2"
    local max_attempts="${3:-$DEFAULT_MAX_ATTEMPTS}"
    local initial_delay="${4:-$DEFAULT_INITIAL_DELAY}"
    local max_delay="${5:-$DEFAULT_MAX_DELAY}"
    local multiplier="${6:-$DEFAULT_BACKOFF_MULTIPLIER}"
    local use_jitter="${7:-$DEFAULT_JITTER}"
    
    # Check for permanent failure
    if is_permanent_failure "$entity_id"; then
        log_error "ERROR_HANDLER" "Entity $entity_id has permanent failure status, skipping execution"
        return 1
    fi
    
    # Initialize retry state
    init_retry_state "$entity_id"
    local state=$(get_retry_state "$entity_id")
    local current_attempt=1
    
    if has_jq; then
        current_attempt=$(echo "$state" | jq -r '.attempts // 0' 2>/dev/null || echo "0")
        current_attempt=$((current_attempt + 1))
    else
        current_attempt=1
    fi
    
    # Execute with retries
    while [[ $current_attempt -le $max_attempts ]]; do
        log_info "ERROR_HANDLER" "Executing $entity_id (attempt $current_attempt/$max_attempts)"
        
        # Execute command and capture output
        local output
        local exit_code
        
        output=$(eval "$command" 2>&1)
        exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            # Success - reset retry state
            reset_retry_state "$entity_id"
            log_info "ERROR_HANDLER" "Entity $entity_id succeeded on attempt $current_attempt"
            echo "$output"
            return 0
        else
            # Failure - update retry state
            local error_msg="Command failed with exit code $exit_code"
            if [[ -n "$output" ]]; then
                error_msg="$error_msg: $(echo "$output" | head -1)"
            fi
            
            update_retry_state "$entity_id" "$current_attempt" "$error_msg" false
            
            if [[ $current_attempt -lt $max_attempts ]]; then
                log_warning "ERROR_HANDLER" "Entity $entity_id failed on attempt $current_attempt/$max_attempts: $error_msg"
                wait_with_backoff "$current_attempt" "$initial_delay" "$max_delay" "$multiplier" "$use_jitter"
            else
                # Max attempts reached - mark as permanent failure
                log_error "ERROR_HANDLER" "Entity $entity_id failed after $max_attempts attempts: $error_msg"
                update_retry_state "$entity_id" "$current_attempt" "$error_msg" true
                echo "$output" >&2
                return $exit_code
            fi
        fi
        
        current_attempt=$((current_attempt + 1))
    done
    
    return 1
}

# Execute function with retry
execute_function_with_retry() {
    local entity_id="$1"
    local func_name="$2"
    shift 2
    local func_args="$@"
    local max_attempts="${RETRY_MAX_ATTEMPTS:-$DEFAULT_MAX_ATTEMPTS}"
    local initial_delay="${RETRY_INITIAL_DELAY:-$DEFAULT_INITIAL_DELAY}"
    local max_delay="${RETRY_MAX_DELAY:-$DEFAULT_MAX_DELAY}"
    local multiplier="${RETRY_MULTIPLIER:-$DEFAULT_BACKOFF_MULTIPLIER}"
    local use_jitter="${RETRY_JITTER:-$DEFAULT_JITTER}"
    
    # Check for permanent failure
    if is_permanent_failure "$entity_id"; then
        log_error "ERROR_HANDLER" "Entity $entity_id has permanent failure status, skipping execution"
        return 1
    fi
    
    # Initialize retry state
    init_retry_state "$entity_id"
    local state=$(get_retry_state "$entity_id")
    local current_attempt=1
    
    if has_jq; then
        current_attempt=$(echo "$state" | jq -r '.attempts // 0' 2>/dev/null || echo "0")
        current_attempt=$((current_attempt + 1))
    else
        current_attempt=1
    fi
    
    # Execute with retries
    while [[ $current_attempt -le $max_attempts ]]; do
        log_info "ERROR_HANDLER" "Executing function $func_name for $entity_id (attempt $current_attempt/$max_attempts)"
        
        # Execute function and capture output
        local output
        local exit_code
        
        output=$($func_name $func_args 2>&1)
        exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            # Success - reset retry state
            reset_retry_state "$entity_id"
            log_info "ERROR_HANDLER" "Function $func_name for $entity_id succeeded on attempt $current_attempt"
            echo "$output"
            return 0
        else
            # Failure - update retry state
            local error_msg="Function $func_name failed with exit code $exit_code"
            if [[ -n "$output" ]]; then
                error_msg="$error_msg: $(echo "$output" | head -1)"
            fi
            
            update_retry_state "$entity_id" "$current_attempt" "$error_msg" false
            
            if [[ $current_attempt -lt $max_attempts ]]; then
                log_warning "ERROR_HANDLER" "Function $func_name for $entity_id failed on attempt $current_attempt/$max_attempts: $error_msg"
                wait_with_backoff "$current_attempt" "$initial_delay" "$max_delay" "$multiplier" "$use_jitter"
            else
                # Max attempts reached - mark as permanent failure
                log_error "ERROR_HANDLER" "Function $func_name for $entity_id failed after $max_attempts attempts: $error_msg"
                update_retry_state "$entity_id" "$current_attempt" "$error_msg" true
                echo "$output" >&2
                return $exit_code
            fi
        fi
        
        current_attempt=$((current_attempt + 1))
    done
    
    return 1
}

# Get retry statistics
get_retry_stats() {
    local entity_id="$1"
    local state=$(get_retry_state "$entity_id")
    
    if has_jq; then
        local attempts=$(echo "$state" | jq -r '.attempts // 0' 2>/dev/null || echo "0")
        local last_attempt=$(echo "$state" | jq -r '.last_attempt // "never"' 2>/dev/null || echo "never")
        local last_error=$(echo "$state" | jq -r '.last_error // "none"' 2>/dev/null || echo "none")
        local permanent=$(echo "$state" | jq -r '.permanent_failure // false' 2>/dev/null || echo "false")
        
        echo "Attempts: $attempts"
        echo "Last attempt: $last_attempt"
        echo "Last error: $last_error"
        echo "Permanent failure: $permanent"
    else
        echo "Retry statistics not available (jq required)"
    fi
}

# Clear retry state (force reset)
clear_retry_state() {
    local entity_id="$1"
    local state_file=$(get_retry_state_file "$entity_id")
    
    if [[ -f "$state_file" ]]; then
        rm -f "$state_file"
        log_info "ERROR_HANDLER" "Cleared retry state for: $entity_id"
    fi
}

# Check if retry is needed
should_retry() {
    local entity_id="$1"
    local max_attempts="${2:-$DEFAULT_MAX_ATTEMPTS}"
    
    if is_permanent_failure "$entity_id"; then
        return 1
    fi
    
    local state=$(get_retry_state "$entity_id")
    local attempts=0
    
    if has_jq; then
        attempts=$(echo "$state" | jq -r '.attempts // 0' 2>/dev/null || echo "0")
    fi
    
    [[ $attempts -lt $max_attempts ]]
}

# Handle error with context
handle_error() {
    local entity_id="$1"
    local error_code="$2"
    local error_message="$3"
    local context="${4:-}"
    
    local timestamp=$(get_timestamp)
    local full_message="Error in $entity_id (code: $error_code)"
    
    if [[ -n "$error_message" ]]; then
        full_message="$full_message - $error_message"
    fi
    
    if [[ -n "$context" ]]; then
        full_message="$full_message [Context: $context]"
    fi
    
    log_error "ERROR_HANDLER" "$full_message"
    
    # Update retry state
    update_retry_state "$entity_id" "$(($(get_retry_state "$entity_id" | jq -r '.attempts // 0' 2>/dev/null || echo "0") + 1))" "$full_message" false
    
    return $error_code
}

# Export functions
export -f get_retry_state_file
export -f init_retry_state
export -f get_retry_state
export -f update_retry_state
export -f reset_retry_state
export -f is_permanent_failure
export -f calculate_backoff_delay
export -f wait_with_backoff
export -f execute_with_retry
export -f execute_function_with_retry
export -f get_retry_stats
export -f clear_retry_state
export -f should_retry
export -f handle_error

