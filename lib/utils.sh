#!/bin/bash
# Utility Library
# Common utility functions for JSON parsing, validation, and file operations

# Source platform detection if available
if [[ -f "${BASH_SOURCE%/*}/platform_detect.sh" ]]; then
    source "${BASH_SOURCE%/*}/platform_detect.sh"
fi

# Check if jq is available
has_jq() {
    command -v jq >/dev/null 2>&1
}

# Get JSON value using jq (preferred) or fallback
json_get() {
    local file="$1"
    local path="$2"
    
    if has_jq; then
        jq -r "$path" "$file" 2>/dev/null
    else
        json_get_fallback "$file" "$path"
    fi
}

# Fallback JSON parsing using awk/sed (simple cases)
json_get_fallback() {
    local file="$1"
    local path="$2"
    
    # Remove leading . if present
    path="${path#.}"
    
    # Simple key extraction (works for top-level keys)
    if [[ "$path" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        grep -o "\"$path\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | \
        sed 's/.*"\([^"]*\)".*/\1/' | head -1
    elif [[ "$path" =~ ^\[0\]$ ]] || [[ "$path" =~ ^\[[0-9]+\]$ ]]; then
        # Array access (simplified)
        grep -o '"[^"]*"' "$file" 2>/dev/null | sed -n '2p'
    else
        # More complex paths - return empty
        echo ""
    fi
}

# Set JSON value (requires jq)
json_set() {
    local file="$1"
    local path="$2"
    local value="$3"
    
    if ! has_jq; then
        echo "ERROR: jq is required for JSON modification" >&2
        return 1
    fi
    
    # Create backup
    local backup="${file}.bak.$$"
    cp "$file" "$backup" 2>/dev/null || return 1
    
    # Use jq to update
    if jq "$path = $value" "$backup" > "${file}.tmp.$$" 2>/dev/null; then
        mv "${file}.tmp.$$" "$file" && rm -f "$backup"
        return 0
    else
        # Restore backup on failure
        mv "$backup" "$file" 2>/dev/null
        return 1
    fi
}

# Add item to JSON array
json_array_add() {
    local file="$1"
    local array_path="$2"
    local item="$3"
    
    if ! has_jq; then
        echo "ERROR: jq is required for JSON modification" >&2
        return 1
    fi
    
    local backup="${file}.bak.$$"
    cp "$file" "$backup" 2>/dev/null || return 1
    
    if jq "$array_path += [$item]" "$backup" > "${file}.tmp.$$" 2>/dev/null; then
        mv "${file}.tmp.$$" "$file" && rm -f "$backup"
        return 0
    else
        mv "$backup" "$file" 2>/dev/null
        return 1
    fi
}

# Remove item from JSON array by index
json_array_remove() {
    local file="$1"
    local array_path="$2"
    local index="$3"
    
    if ! has_jq; then
        echo "ERROR: jq is required for JSON modification" >&2
        return 1
    fi
    
    local backup="${file}.bak.$$"
    cp "$file" "$backup" 2>/dev/null || return 1
    
    if jq "del($array_path[$index])" "$backup" > "${file}.tmp.$$" 2>/dev/null; then
        mv "${file}.tmp.$$" "$file" && rm -f "$backup"
        return 0
    else
        mv "$backup" "$file" 2>/dev/null
        return 1
    fi
}

# Remove item from JSON array by matching field
json_array_remove_by_field() {
    local file="$1"
    local array_path="$2"
    local field="$3"
    local value="$4"
    
    if ! has_jq; then
        echo "ERROR: jq is required for JSON modification" >&2
        return 1
    fi
    
    local backup="${file}.bak.$$"
    cp "$file" "$backup" 2>/dev/null || return 1
    
    if jq "$array_path |= map(select(.$field != \"$value\"))" "$backup" > "${file}.tmp.$$" 2>/dev/null; then
        mv "${file}.tmp.$$" "$file" && rm -f "$backup"
        return 0
    else
        mv "$backup" "$file" 2>/dev/null
        return 1
    fi
}

# Validate JSON file syntax
validate_json() {
    local file="$1"
    
    if has_jq; then
        jq empty "$file" 2>/dev/null
        return $?
    else
        # Basic validation using grep (very basic)
        if [[ ! -f "$file" ]]; then
            return 1
        fi
        # Check for balanced braces (simplified)
        local open=$(grep -o '{' "$file" | wc -l)
        local close=$(grep -o '}' "$file" | wc -l)
        [[ "$open" == "$close" ]]
    fi
}

# Validate JSON schema (basic validation)
validate_task_schema() {
    local file="$1"
    local task_id="$2"
    
    if ! has_jq; then
        echo "WARNING: jq not available, skipping schema validation" >&2
        return 0
    fi
    
    # Check required fields
    local required_fields=("id" "name" "command" "schedule")
    for field in "${required_fields[@]}"; do
        local value=$(json_get "$file" ".$field")
        if [[ -z "$value" ]] || [[ "$value" == "null" ]]; then
            echo "ERROR: Missing required field: $field" >&2
            return 1
        fi
    done
    
    # Validate schedule structure
    local schedule_type=$(json_get "$file" ".schedule.type")
    if [[ -z "$schedule_type" ]] || [[ "$schedule_type" == "null" ]]; then
        echo "ERROR: Missing schedule.type" >&2
        return 1
    fi
    
    return 0
}

# Validate workflow schema
validate_workflow_schema() {
    local file="$1"
    
    if ! has_jq; then
        echo "WARNING: jq not available, skipping schema validation" >&2
        return 0
    fi
    
    # Check required fields
    local required_fields=("id" "name" "tasks")
    for field in "${required_fields[@]}"; do
        local value=$(json_get "$file" ".$field")
        if [[ -z "$value" ]] || [[ "$value" == "null" ]]; then
            echo "ERROR: Missing required field: $field" >&2
            return 1
        fi
    done
    
    return 0
}

# File locking using lockfile (if available) or mkdir
acquire_lock() {
    local lockfile="$1"
    local timeout="${2:-30}"
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if mkdir "$lockfile.lock" 2>/dev/null; then
            echo $$ > "$lockfile.lock/pid"
            return 0
        fi
        
        # Check if lock is stale (process no longer exists)
        if [[ -f "$lockfile.lock/pid" ]]; then
            local pid=$(cat "$lockfile.lock/pid" 2>/dev/null)
            if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
                # Stale lock, remove it
                rm -rf "$lockfile.lock" 2>/dev/null
                continue
            fi
        fi
        
        sleep 0.5
        elapsed=$((elapsed + 1))
    done
    
    echo "ERROR: Failed to acquire lock on $lockfile after ${timeout}s" >&2
    return 1
}

# Release file lock
release_lock() {
    local lockfile="$1"
    rm -rf "$lockfile.lock" 2>/dev/null
}

# Atomic file write
atomic_write() {
    local content="$1"
    local target="$2"
    local tmpfile="${target}.tmp.$$"
    
    # Write to temp file
    echo "$content" > "$tmpfile" || return 1
    
    # Atomic move
    mv "$tmpfile" "$target" 2>/dev/null || {
        rm -f "$tmpfile"
        return 1
    }
    
    return 0
}

# Safe JSON file update with locking
safe_json_update() {
    local file="$1"
    local update_func="$2"
    local lockfile="${file}.lock"
    
    # Acquire lock
    if ! acquire_lock "$lockfile" 30; then
        return 1
    fi
    
    # Create backup
    local backup="${file}.bak.$$"
    cp "$file" "$backup" 2>/dev/null || {
        release_lock "$lockfile"
        return 1
    }
    
    # Perform update
    if $update_func "$backup" "${file}.tmp.$$"; then
        mv "${file}.tmp.$$" "$file" && rm -f "$backup"
        local result=$?
        release_lock "$lockfile"
        return $result
    else
        # Restore backup on failure
        mv "$backup" "$file" 2>/dev/null
        release_lock "$lockfile"
        return 1
    fi
}

# Get absolute path
get_absolute_path() {
    local path="$1"
    
    if [[ -z "$path" ]]; then
        return 1
    fi
    
    # If already absolute
    if [[ "$path" = /* ]] || [[ "$path" =~ ^[A-Za-z]: ]]; then
        echo "$path"
        return 0
    fi
    
    # Resolve relative path
    local dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd)
    local base=$(basename "$path")
    echo "${dir}/${base}"
}

# Check if command exists and is executable
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Sanitize string for use in filenames
sanitize_filename() {
    local str="$1"
    echo "$str" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g'
}

# Get current timestamp
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date
}

# Get current timestamp (ISO format)
get_timestamp_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%d %H:%M:%S"
}

# Get epoch timestamp
get_timestamp_epoch() {
    date +%s 2>/dev/null || date +%s
}

# Parse cron expression to next execution time (simplified)
parse_cron_next() {
    local cron_expr="$1"
    local current_time="${2:-$(date +%s)}"
    
    # This is a simplified parser - full cron parsing would be more complex
    # For now, return current time + 1 hour as placeholder
    echo $((current_time + 3600))
}

# Convert schedule type to cron expression
schedule_to_cron() {
    local type="$1"
    local time="$2"
    local day="${3:-}"
    
    case "$type" in
        "daily")
            if [[ -n "$time" ]]; then
                local hour=$(echo "$time" | cut -d: -f1)
                local minute=$(echo "$time" | cut -d: -f2)
                echo "${minute:-0} ${hour:-0} * * *"
            else
                echo "0 0 * * *"
            fi
            ;;
        "weekly")
            if [[ -n "$time" ]] && [[ -n "$day" ]]; then
                local hour=$(echo "$time" | cut -d: -f1)
                local minute=$(echo "$time" | cut -d: -f2)
                # Convert day name to number (0=Sunday, 1=Monday, etc.)
                local day_num=$(echo "$day" | tr '[:upper:]' '[:lower:]')
                case "$day_num" in
                    "sunday"|"sun") day_num=0 ;;
                    "monday"|"mon") day_num=1 ;;
                    "tuesday"|"tue") day_num=2 ;;
                    "wednesday"|"wed") day_num=3 ;;
                    "thursday"|"thu") day_num=4 ;;
                    "friday"|"fri") day_num=5 ;;
                    "saturday"|"sat") day_num=6 ;;
                    *) day_num=0 ;;
                esac
                echo "${minute:-0} ${hour:-0} * * $day_num"
            else
                echo "0 0 * * 0"
            fi
            ;;
        "monthly")
            if [[ -n "$time" ]]; then
                local hour=$(echo "$time" | cut -d: -f1)
                local minute=$(echo "$time" | cut -d: -f2)
                echo "${minute:-0} ${hour:-0} 1 * *"
            else
                echo "0 0 1 * *"
            fi
            ;;
        "cron")
            # Already a cron expression
            echo "$time"
            ;;
        *)
            echo "0 0 * * *"
            ;;
    esac
}

# Check if path is safe (not outside project directory)
is_safe_path() {
    local path="$1"
    local base_dir="${2:-$(pwd)}"
    
    local abs_path=$(get_absolute_path "$path")
    local abs_base=$(get_absolute_path "$base_dir")
    
    # Check if path is within base directory
    [[ "$abs_path" == "$abs_base"* ]]
}

# Create directory if it doesn't exist
ensure_directory() {
    local dir="$1"
    
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" 2>/dev/null || return 1
    fi
    return 0
}

# Export functions for use in other scripts
export -f has_jq
export -f json_get
export -f json_get_fallback
export -f json_set
export -f json_array_add
export -f json_array_remove
export -f json_array_remove_by_field
export -f validate_json
export -f validate_task_schema
export -f validate_workflow_schema
export -f acquire_lock
export -f release_lock
export -f atomic_write
export -f safe_json_update
export -f get_absolute_path
export -f command_exists
export -f sanitize_filename
export -f get_timestamp
export -f get_timestamp_iso
export -f get_timestamp_epoch
export -f parse_cron_next
export -f schedule_to_cron
export -f is_safe_path
export -f ensure_directory

