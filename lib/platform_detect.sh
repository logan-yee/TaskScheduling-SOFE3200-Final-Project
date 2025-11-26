#!/bin/bash
# Platform Detection Library
# Detects OS, mail commands, and scheduling tools for cross-platform support

# Detect operating system
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Check if running in WSL
        if grep -qEi "(Microsoft|WSL)" /proc/version 2>/dev/null; then
            echo "wsl"
        else
            echo "linux"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "msys" ]]; then
        echo "windows"
    else
        echo "unknown"
    fi
}

# Get the detected OS (cached)
get_os() {
    if [[ -z "${PLATFORM_OS:-}" ]]; then
        export PLATFORM_OS=$(detect_os)
    fi
    echo "$PLATFORM_OS"
}

# Detect available mail command
detect_mail_command() {
    local os=$(get_os)
    
    case "$os" in
        "linux"|"wsl")
            # Try mailx first (most common on Linux)
            if command -v mailx >/dev/null 2>&1; then
                echo "mailx"
            # Try mail command
            elif command -v mail >/dev/null 2>&1; then
                echo "mail"
            # Try sendmail
            elif command -v sendmail >/dev/null 2>&1; then
                echo "sendmail"
            else
                echo "none"
            fi
            ;;
        "macos")
            # macOS typically has mail command
            if command -v mail >/dev/null 2>&1; then
                echo "mail"
            elif command -v mailx >/dev/null 2>&1; then
                echo "mailx"
            else
                echo "none"
            fi
            ;;
        *)
            # For other platforms, try common commands
            if command -v mailx >/dev/null 2>&1; then
                echo "mailx"
            elif command -v mail >/dev/null 2>&1; then
                echo "mail"
            elif command -v sendmail >/dev/null 2>&1; then
                echo "sendmail"
            else
                echo "none"
            fi
            ;;
    esac
}

# Get the detected mail command (cached)
get_mail_command() {
    if [[ -z "${PLATFORM_MAIL_CMD:-}" ]]; then
        export PLATFORM_MAIL_CMD=$(detect_mail_command)
    fi
    echo "$PLATFORM_MAIL_CMD"
}

# Detect scheduling tool (cron vs anacron)
detect_scheduler() {
    local os=$(get_os)
    
    case "$os" in
        "linux"|"wsl")
            # Prefer cron, fallback to anacron
            if command -v crontab >/dev/null 2>&1; then
                echo "cron"
            elif command -v anacron >/dev/null 2>&1; then
                echo "anacron"
            else
                echo "none"
            fi
            ;;
        "macos")
            # macOS uses launchd, but cron is available
            if command -v crontab >/dev/null 2>&1; then
                echo "cron"
            else
                echo "none"
            fi
            ;;
        *)
            # Try cron first
            if command -v crontab >/dev/null 2>&1; then
                echo "cron"
            elif command -v anacron >/dev/null 2>&1; then
                echo "anacron"
            else
                echo "none"
            fi
            ;;
    esac
}

# Get the detected scheduler (cached)
get_scheduler() {
    if [[ -z "${PLATFORM_SCHEDULER:-}" ]]; then
        export PLATFORM_SCHEDULER=$(detect_scheduler)
    fi
    echo "$PLATFORM_SCHEDULER"
}

# Get path separator based on OS
get_path_separator() {
    local os=$(get_os)
    case "$os" in
        "windows"|"cygwin"|"msys")
            echo ";"
            ;;
        *)
            echo ":"
            ;;
    esac
}

# Normalize path based on OS
normalize_path() {
    local path="$1"
    local os=$(get_os)
    
    case "$os" in
        "windows"|"cygwin"|"msys")
            # Convert forward slashes to backslashes for Windows
            echo "$path" | sed 's/\//\\/g'
            ;;
        *)
            # Keep as-is for Unix-like systems
            echo "$path"
            ;;
    esac
}

# Get cron file path based on OS
get_cron_file() {
    local os=$(get_os)
    
    case "$os" in
        "macos")
            # macOS uses user-specific crontab
            echo "$HOME/.crontab"
            ;;
        "linux"|"wsl")
            # Linux typically uses /var/spool/cron/crontabs/$USER or /etc/cron.d/
            if [[ -d "/var/spool/cron/crontabs" ]]; then
                echo "/var/spool/cron/crontabs/$USER"
            else
                echo "$HOME/.crontab"
            fi
            ;;
        *)
            echo "$HOME/.crontab"
            ;;
    esac
}

# Check if platform supports required features
check_platform_compatibility() {
    local os=$(get_os)
    local mail_cmd=$(get_mail_command)
    local scheduler=$(get_scheduler)
    local issues=0
    
    echo "Platform Detection Results:" >&2
    echo "  OS: $os" >&2
    echo "  Mail Command: $mail_cmd" >&2
    echo "  Scheduler: $scheduler" >&2
    
    if [[ "$mail_cmd" == "none" ]]; then
        echo "  WARNING: No mail command found. Email notifications will be disabled." >&2
        ((issues++))
    fi
    
    if [[ "$scheduler" == "none" ]]; then
        echo "  ERROR: No scheduling tool found (cron/anacron). Task scheduling will not work." >&2
        ((issues++))
    fi
    
    # Check for jq (preferred JSON parser)
    if ! command -v jq >/dev/null 2>&1; then
        echo "  WARNING: jq not found. Will use fallback JSON parsing (may be slower)." >&2
    fi
    
    return $issues
}

# Initialize platform detection (call this at startup)
init_platform() {
    get_os >/dev/null
    get_mail_command >/dev/null
    get_scheduler >/dev/null
}

# Export functions for use in other scripts
export -f detect_os
export -f get_os
export -f detect_mail_command
export -f get_mail_command
export -f detect_scheduler
export -f get_scheduler
export -f get_path_separator
export -f normalize_path
export -f get_cron_file
export -f check_platform_compatibility
export -f init_platform

