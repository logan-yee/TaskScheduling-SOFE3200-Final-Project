#!/bin/bash
# Cron/Anacron Integration
# Manages cron jobs dynamically with safe file handling

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

if [[ -f "$SCRIPT_DIR/logger.sh" ]]; then
    source "$SCRIPT_DIR/logger.sh"
fi

# Configuration
TASKS_CONFIG="${TASKS_CONFIG:-$CONFIG_DIR/tasks.json}"
CRON_MARKER="# TaskScheduler Managed"
CRON_WRAPPER="${SCRIPT_DIR}/cron_wrapper.sh"

# Get cron file path
get_cron_file() {
    local os=$(get_os 2>/dev/null || echo "linux")
    local cron_file=""
    
    case "$os" in
        "macos")
            # macOS uses user crontab
            cron_file="$HOME/.crontab"
            ;;
        "linux"|"wsl")
            # Linux typically uses system crontab or user crontab
            if [[ -d "/var/spool/cron/crontabs" ]]; then
                cron_file="/var/spool/cron/crontabs/$USER"
            else
                cron_file="$HOME/.crontab"
            fi
            ;;
        *)
            cron_file="$HOME/.crontab"
            ;;
    esac
    
    echo "$cron_file"
}

# Get current crontab
get_current_crontab() {
    crontab -l 2>/dev/null || echo ""
}

# Validate cron expression
validate_cron_expression() {
    local cron_expr="$1"
    
    # Basic validation: should have 5 fields (minute hour day month weekday)
    local field_count=$(echo "$cron_expr" | awk '{print NF}')
    
    if [[ $field_count -ne 5 ]]; then
        log_error "CRON_MANAGER" "Invalid cron expression (must have 5 fields): $cron_expr"
        return 1
    fi
    
    # Check each field
    local minute=$(echo "$cron_expr" | awk '{print $1}')
    local hour=$(echo "$cron_expr" | awk '{print $2}')
    local day=$(echo "$cron_expr" | awk '{print $3}')
    local month=$(echo "$cron_expr" | awk '{print $4}')
    local weekday=$(echo "$cron_expr" | awk '{print $5}')
    
    # Validate ranges (simplified)
    if [[ "$minute" =~ ^[0-9]+$ ]] && [[ $minute -gt 59 ]]; then
        log_error "CRON_MANAGER" "Invalid minute value: $minute (must be 0-59)"
        return 1
    fi
    
    if [[ "$hour" =~ ^[0-9]+$ ]] && [[ $hour -gt 23 ]]; then
        log_error "CRON_MANAGER" "Invalid hour value: $hour (must be 0-23)"
        return 1
    fi
    
    # More complex validation would check for */N, ranges, lists, etc.
    # For now, basic validation is sufficient
    
    return 0
}

# Generate cron entry for task
generate_cron_entry() {
    local task_id="$1"
    local cron_expr="$2"
    local command="$3"
    
    # Validate cron expression
    if ! validate_cron_expression "$cron_expr"; then
        return 1
    fi
    
    # Create wrapper command that calls task executor
    local wrapper_cmd="${SCRIPT_DIR}/cron_wrapper.sh"
    local full_command="$wrapper_cmd $task_id"
    
    # Generate cron entry with marker
    echo "$cron_expr $full_command $CRON_MARKER # Task: $task_id"
}

# Create cron wrapper script
create_cron_wrapper() {
    local wrapper_file="${SCRIPT_DIR}/cron_wrapper.sh"
    
    if [[ -f "$wrapper_file" ]]; then
        return 0
    fi
    
    cat > "$wrapper_file" <<'EOF'
#!/bin/bash
# Cron Wrapper Script
# Executes tasks when triggered by cron

TASK_ID="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source task executor
if [[ -f "$SCRIPT_DIR/task_executor.sh" ]]; then
    source "$SCRIPT_DIR/task_executor.sh"
    execute_task "$TASK_ID"
else
    echo "ERROR: task_executor.sh not found" >&2
    exit 1
fi
EOF
    
    chmod +x "$wrapper_file"
    log_info "CRON_MANAGER" "Created cron wrapper script: $wrapper_file"
}

# Install cron job for task
install_cron_job() {
    local task_id="$1"
    local cron_expr="$2"
    
    # Create wrapper if needed
    create_cron_wrapper
    
    # Generate cron entry
    local cron_entry=$(generate_cron_entry "$task_id" "$cron_expr" "")
    
    if [[ -z "$cron_entry" ]]; then
        log_error "CRON_MANAGER" "Failed to generate cron entry for task: $task_id"
        return 1
    fi
    
    # Get current crontab
    local current_crontab=$(get_current_crontab)
    local temp_crontab=$(mktemp)
    
    # Remove existing entry for this task (if any)
    echo "$current_crontab" | grep -v "# Task: $task_id" > "$temp_crontab"
    
    # Add new entry
    echo "$cron_entry" >> "$temp_crontab"
    
    # Install new crontab
    if crontab "$temp_crontab" 2>/dev/null; then
        rm -f "$temp_crontab"
        log_info "CRON_MANAGER" "Installed cron job for task: $task_id"
        return 0
    else
        rm -f "$temp_crontab"
        log_error "CRON_MANAGER" "Failed to install cron job for task: $task_id"
        return 1
    fi
}

# Remove cron job for task
remove_cron_job() {
    local task_id="$1"
    
    # Get current crontab
    local current_crontab=$(get_current_crontab)
    
    if [[ -z "$current_crontab" ]]; then
        log_debug "CRON_MANAGER" "No crontab found for task: $task_id"
        return 0
    fi
    
    # Remove entry for this task
    local temp_crontab=$(mktemp)
    echo "$current_crontab" | grep -v "# Task: $task_id" > "$temp_crontab"
    
    # Install updated crontab
    if crontab "$temp_crontab" 2>/dev/null; then
        rm -f "$temp_crontab"
        log_info "CRON_MANAGER" "Removed cron job for task: $task_id"
        return 0
    else
        rm -f "$temp_crontab"
        log_error "CRON_MANAGER" "Failed to remove cron job for task: $task_id"
        return 1
    fi
}

# Update cron job for task
update_cron_job() {
    local task_id="$1"
    local cron_expr="$2"
    
    # Remove old entry and install new one
    remove_cron_job "$task_id"
    install_cron_job "$task_id" "$cron_expr"
}

# List all managed cron jobs
list_cron_jobs() {
    local current_crontab=$(get_current_crontab)
    
    if [[ -z "$current_crontab" ]]; then
        echo "No cron jobs found"
        return 0
    fi
    
    # Extract managed jobs
    echo "$current_crontab" | grep "$CRON_MARKER" | while read -r line; do
        local task_id=$(echo "$line" | grep -o "# Task: [^ ]*" | cut -d' ' -f3)
        local cron_expr=$(echo "$line" | awk '{print $1, $2, $3, $4, $5}')
        echo "$task_id: $cron_expr"
    done
}

# Sync cron jobs with task configuration
sync_cron_jobs() {
    if [[ ! -f "$TASKS_CONFIG" ]]; then
        log_error "CRON_MANAGER" "Tasks configuration file not found: $TASKS_CONFIG"
        return 1
    fi
    
    if ! has_jq; then
        log_error "CRON_MANAGER" "jq is required for cron job synchronization"
        return 1
    fi
    
    # Get all tasks with schedules
    local tasks=$(jq -r '.[] | select(.schedule.type != "manual" and .schedule.type != null) | "\(.id)|\(.schedule.type)|\(.schedule.time // "")|\(.schedule.day // "")|\(.schedule.cron // "")"' "$TASKS_CONFIG" 2>/dev/null)
    
    # Get currently installed cron jobs
    local current_crontab=$(get_current_crontab)
    local installed_tasks=$(echo "$current_crontab" | grep "$CRON_MARKER" | grep -o "# Task: [^ ]*" | cut -d' ' -f3)
    
    # Process each task
    while IFS='|' read -r task_id schedule_type schedule_time schedule_day schedule_cron; do
        if [[ -z "$task_id" ]]; then
            continue
        fi
        
        # Generate cron expression
        local cron_expr=""
        if [[ "$schedule_type" == "cron" ]] && [[ -n "$schedule_cron" ]]; then
            cron_expr="$schedule_cron"
        else
            cron_expr=$(schedule_to_cron "$schedule_type" "$schedule_time" "$schedule_day")
        fi
        
        if [[ -z "$cron_expr" ]]; then
            log_warning "CRON_MANAGER" "Could not generate cron expression for task: $task_id"
            continue
        fi
        
        # Check if already installed
        local is_installed=false
        for installed_task in $installed_tasks; do
            if [[ "$installed_task" == "$task_id" ]]; then
                is_installed=true
                break
            fi
        done
        
        # Install or update
        if [[ "$is_installed" == "true" ]]; then
            # Check if cron expression changed
            local existing_expr=$(echo "$current_crontab" | grep "# Task: $task_id" | awk '{print $1, $2, $3, $4, $5}')
            if [[ "$existing_expr" != "$cron_expr" ]]; then
                log_info "CRON_MANAGER" "Updating cron job for task: $task_id"
                update_cron_job "$task_id" "$cron_expr"
            fi
        else
            log_info "CRON_MANAGER" "Installing cron job for task: $task_id"
            install_cron_job "$task_id" "$cron_expr"
        fi
    done <<< "$tasks"
    
    # Remove cron jobs for tasks that no longer exist or are manual
    for installed_task in $installed_tasks; do
        local task_exists=$(jq -r ".[] | select(.id == \"$installed_task\") | .id" "$TASKS_CONFIG" 2>/dev/null)
        local schedule_type=$(jq -r ".[] | select(.id == \"$installed_task\") | .schedule.type // \"manual\"" "$TASKS_CONFIG" 2>/dev/null)
        
        if [[ -z "$task_exists" ]] || [[ "$schedule_type" == "manual" ]]; then
            log_info "CRON_MANAGER" "Removing cron job for removed/manual task: $installed_task"
            remove_cron_job "$installed_task"
        fi
    done
    
    log_info "CRON_MANAGER" "Cron job synchronization completed"
}

# Check if cron is available
is_cron_available() {
    command_exists crontab
}

# Check if anacron is available
is_anacron_available() {
    command_exists anacron
}

# Get scheduler type
get_scheduler_type() {
    if is_cron_available; then
        echo "cron"
    elif is_anacron_available; then
        echo "anacron"
    else
        echo "none"
    fi
}

# Install anacron job (simplified - anacron uses different format)
install_anacron_job() {
    local task_id="$1"
    local schedule_type="$2"
    local schedule_time="$3"
    
    log_warning "CRON_MANAGER" "Anacron support is limited. Using cron fallback."
    
    # Anacron uses /etc/anacrontab or ~/.anacrontab
    # This is a simplified implementation
    # Full anacron support would require parsing anacrontab format
    
    return 1
}

# Verify cron installation
verify_cron_installation() {
    local task_id="$1"
    local current_crontab=$(get_current_crontab)
    
    if echo "$current_crontab" | grep -q "# Task: $task_id"; then
        return 0
    else
        return 1
    fi
}

# Get next execution time for cron job
get_next_execution_time() {
    local cron_expr="$1"
    
    # This is a simplified implementation
    # A full implementation would parse the cron expression and calculate next run time
    # For now, return a placeholder
    
    log_debug "CRON_MANAGER" "Next execution time calculation not fully implemented"
    echo "Unknown"
}

# Export functions
export -f get_cron_file
export -f get_current_crontab
export -f validate_cron_expression
export -f generate_cron_entry
export -f create_cron_wrapper
export -f install_cron_job
export -f remove_cron_job
export -f update_cron_job
export -f list_cron_jobs
export -f sync_cron_jobs
export -f is_cron_available
export -f is_anacron_available
export -f get_scheduler_type
export -f verify_cron_installation
export -f get_next_execution_time


