#!/bin/bash
# Email Notification System
# Sends notifications using system mail commands with platform detection

# Source utility libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR%/*}/lib"

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

# Configuration file
NOTIFICATIONS_CONFIG="${NOTIFICATIONS_CONFIG:-${SCRIPT_DIR%/*}/config/notifications.json}"

# Default notification settings
DEFAULT_FROM_EMAIL="${DEFAULT_FROM_EMAIL:-noreply@localhost}"
DEFAULT_SUBJECT_PREFIX="${DEFAULT_SUBJECT_PREFIX:-[TaskScheduler]}"

# Get mail command
get_mail_command() {
    if [[ -f "$LIB_DIR/platform_detect.sh" ]]; then
        source "$LIB_DIR/platform_detect.sh"
        get_mail_command
    else
        # Fallback detection
        if command -v mailx >/dev/null 2>&1; then
            echo "mailx"
        elif command -v mail >/dev/null 2>&1; then
            echo "mail"
        elif command -v sendmail >/dev/null 2>&1; then
            echo "sendmail"
        else
            echo "none"
        fi
    fi
}

# Check if email notifications are available
is_email_available() {
    local mail_cmd=$(get_mail_command)
    [[ "$mail_cmd" != "none" ]]
}

# Get notification recipients from config
get_notification_recipients() {
    local event_type="$1"  # success, failure, or both
    
    if [[ ! -f "$NOTIFICATIONS_CONFIG" ]]; then
        return 1
    fi
    
    if has_jq; then
        local recipients=$(json_get "$NOTIFICATIONS_CONFIG" ".recipients.$event_type[]?" 2>/dev/null)
        if [[ -z "$recipients" ]]; then
            # Fallback to general recipients
            recipients=$(json_get "$NOTIFICATIONS_CONFIG" ".recipients.default[]?" 2>/dev/null)
        fi
        echo "$recipients"
    else
        # Fallback: try to extract from JSON manually
        grep -o "\"$event_type\"[[:space:]]*:[[:space:]]*\[[^]]*\]" "$NOTIFICATIONS_CONFIG" 2>/dev/null | \
        grep -o '"[^"]*@[^"]*"' | sed 's/"//g' | tr '\n' ' '
    fi
}

# Get notification preferences
get_notification_preferences() {
    local entity_type="$1"  # task or workflow
    local entity_id="$2"
    
    if [[ ! -f "$NOTIFICATIONS_CONFIG" ]]; then
        return 1
    fi
    
    if has_jq; then
        json_get "$NOTIFICATIONS_CONFIG" ".preferences.${entity_type}.${entity_id}?" 2>/dev/null
    else
        echo "{}"
    fi
}

# Build email subject
build_email_subject() {
    local status="$1"  # success, failure
    local entity_type="$2"  # task or workflow
    local entity_id="$3"
    local entity_name="${4:-$entity_id}"
    
    local status_text=""
    case "$status" in
        "success") status_text="SUCCESS" ;;
        "failure") status_text="FAILED" ;;
        *) status_text="COMPLETED" ;;
    esac
    
    echo "${DEFAULT_SUBJECT_PREFIX} ${entity_type^} $status_text: $entity_name ($entity_id)"
}

# Build email body
build_email_body() {
    local status="$1"
    local entity_type="$2"
    local entity_id="$3"
    local entity_name="${4:-$entity_id}"
    local exit_code="${5:-0}"
    local duration="${6:-0}"
    local output="${7:-}"
    local error_msg="${8:-}"
    
    local timestamp=$(get_timestamp)
    local body=""
    
    body+="Task Scheduling System Notification\n"
    body+="=====================================\n\n"
    body+="Timestamp: $timestamp\n"
    body+="Entity Type: $entity_type\n"
    body+="Entity ID: $entity_id\n"
    body+="Entity Name: $entity_name\n"
    body+="Status: $status\n"
    body+="Exit Code: $exit_code\n"
    body+="Duration: ${duration} seconds\n\n"
    
    if [[ -n "$error_msg" ]]; then
        body+="Error Message:\n"
        body+="$error_msg\n\n"
    fi
    
    if [[ -n "$output" ]]; then
        body+="Output:\n"
        body+="$(echo "$output" | head -50)\n"  # Limit to first 50 lines
        if [[ $(echo "$output" | wc -l) -gt 50 ]]; then
            body+="\n... (output truncated, see logs for full output)\n"
        fi
        body+="\n"
    fi
    
    body+="\n---\n"
    body+="This is an automated notification from the Task Scheduling System.\n"
    
    echo -e "$body"
}

# Send email using mailx
send_email_mailx() {
    local to="$1"
    local subject="$2"
    local body="$3"
    local from="${4:-$DEFAULT_FROM_EMAIL}"
    
    echo -e "$body" | mailx -s "$subject" -r "$from" "$to" 2>&1
    return $?
}

# Send email using mail
send_email_mail() {
    local to="$1"
    local subject="$2"
    local body="$3"
    local from="${4:-$DEFAULT_FROM_EMAIL}"
    
    {
        echo "From: $from"
        echo "To: $to"
        echo "Subject: $subject"
        echo ""
        echo -e "$body"
    } | mail -s "$subject" "$to" 2>&1
    return $?
}

# Send email using sendmail
send_email_sendmail() {
    local to="$1"
    local subject="$2"
    local body="$3"
    local from="${4:-$DEFAULT_FROM_EMAIL}"
    
    {
        echo "From: $from"
        echo "To: $to"
        echo "Subject: $subject"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo ""
        echo -e "$body"
    } | sendmail "$to" 2>&1
    return $?
}

# Send email (platform-agnostic)
send_email() {
    local to="$1"
    local subject="$2"
    local body="$3"
    local from="${4:-$DEFAULT_FROM_EMAIL}"
    
    if [[ -z "$to" ]]; then
        log_warning "NOTIFICATION" "No recipient specified for email notification"
        return 1
    fi
    
    local mail_cmd=$(get_mail_command)
    
    if [[ "$mail_cmd" == "none" ]]; then
        log_error "NOTIFICATION" "No mail command available. Email notification skipped."
        return 1
    fi
    
    local result
    case "$mail_cmd" in
        "mailx")
            result=$(send_email_mailx "$to" "$subject" "$body" "$from")
            ;;
        "mail")
            result=$(send_email_mail "$to" "$subject" "$body" "$from")
            ;;
        "sendmail")
            result=$(send_email_sendmail "$to" "$subject" "$body" "$from")
            ;;
        *)
            log_error "NOTIFICATION" "Unsupported mail command: $mail_cmd"
            return 1
            ;;
    esac
    
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        log_info "NOTIFICATION" "Email sent successfully to: $to"
    else
        log_error "NOTIFICATION" "Failed to send email to: $to - $result"
    fi
    
    return $exit_code
}

# Send notification to multiple recipients
send_notification() {
    local status="$1"  # success or failure
    local entity_type="$2"  # task or workflow
    local entity_id="$3"
    local entity_name="${4:-$entity_id}"
    local exit_code="${5:-0}"
    local duration="${6:-0}"
    local output="${7:-}"
    local error_msg="${8:-}"
    
    # Check if email is available
    if ! is_email_available; then
        log_warning "NOTIFICATION" "Email notifications not available (no mail command found)"
        return 1
    fi
    
    # Determine which recipients to notify
    local recipients=""
    if [[ "$status" == "success" ]]; then
        recipients=$(get_notification_recipients "success")
    elif [[ "$status" == "failure" ]]; then
        recipients=$(get_notification_recipients "failure")
    fi
    
    # If no specific recipients, try default
    if [[ -z "$recipients" ]]; then
        recipients=$(get_notification_recipients "default")
    fi
    
    if [[ -z "$recipients" ]]; then
        log_debug "NOTIFICATION" "No recipients configured for $status notifications"
        return 0
    fi
    
    # Build email content
    local subject=$(build_email_subject "$status" "$entity_type" "$entity_id" "$entity_name")
    local body=$(build_email_body "$status" "$entity_type" "$entity_id" "$entity_name" "$exit_code" "$duration" "$output" "$error_msg")
    
    # Send to each recipient
    local success_count=0
    local fail_count=0
    
    for recipient in $recipients; do
        if [[ -n "$recipient" ]] && [[ "$recipient" =~ .+@.+ ]]; then
            if send_email "$recipient" "$subject" "$body"; then
                ((success_count++))
            else
                ((fail_count++))
            fi
        fi
    done
    
    if [[ $fail_count -gt 0 ]]; then
        log_warning "NOTIFICATION" "Failed to send $fail_count notification(s) out of $((success_count + fail_count))"
        return 1
    fi
    
    return 0
}

# Send task notification
send_task_notification() {
    local task_id="$1"
    local task_name="$2"
    local status="$3"  # success or failure
    local exit_code="${4:-0}"
    local duration="${5:-0}"
    local output="${6:-}"
    local error_msg="${7:-}"
    
    # Check if notifications are enabled for this task
    local task_config="${SCRIPT_DIR%/*}/config/tasks.json"
    if [[ -f "$task_config" ]] && has_jq; then
        local notify_on_success=$(json_get "$task_config" ".notifications.on_success?" 2>/dev/null)
        local notify_on_failure=$(json_get "$task_config" ".notifications.on_failure?" 2>/dev/null)
        
        if [[ "$status" == "success" ]] && [[ "$notify_on_success" != "true" ]]; then
            log_debug "NOTIFICATION" "Notifications disabled for task $task_id on success"
            return 0
        fi
        
        if [[ "$status" == "failure" ]] && [[ "$notify_on_failure" != "true" ]]; then
            log_debug "NOTIFICATION" "Notifications disabled for task $task_id on failure"
            return 0
        fi
    fi
    
    send_notification "$status" "task" "$task_id" "$task_name" "$exit_code" "$duration" "$output" "$error_msg"
}

# Send workflow notification
send_workflow_notification() {
    local workflow_id="$1"
    local workflow_name="$2"
    local status="$3"  # success, failure, or partial
    local duration="${4:-0}"
    local details="${5:-}"
    
    # Map workflow status to notification status
    local notify_status="success"
    if [[ "$status" == "failed" ]] || [[ "$status" == "failure" ]]; then
        notify_status="failure"
    elif [[ "$status" == "partial" ]]; then
        notify_status="failure"  # Treat partial as failure for notifications
    fi
    
    send_notification "$notify_status" "workflow" "$workflow_id" "$workflow_name" "0" "$duration" "$details" ""
}

# Test email configuration
test_email_config() {
    local test_recipient="${1:-}"
    
    if [[ -z "$test_recipient" ]]; then
        test_recipient=$(get_notification_recipients "default" | awk '{print $1}')
    fi
    
    if [[ -z "$test_recipient" ]]; then
        echo "ERROR: No recipient specified and no default recipients configured" >&2
        return 1
    fi
    
    if ! is_email_available; then
        echo "ERROR: No mail command available" >&2
        return 1
    fi
    
    local subject="${DEFAULT_SUBJECT_PREFIX} Test Email"
    local body="This is a test email from the Task Scheduling System.\n\nIf you receive this message, email notifications are configured correctly."
    
    echo "Sending test email to: $test_recipient..."
    if send_email "$test_recipient" "$subject" "$body"; then
        echo "Test email sent successfully!"
        return 0
    else
        echo "Failed to send test email" >&2
        return 1
    fi
}

# Initialize notification system
init_notifications() {
    # Ensure config directory exists
    local config_dir=$(dirname "$NOTIFICATIONS_CONFIG")
    ensure_directory "$config_dir" || return 1
    
    # Check email availability
    if is_email_available; then
        local mail_cmd=$(get_mail_command)
        log_info "NOTIFICATION" "Email notifications enabled (using $mail_cmd)"
    else
        log_warning "NOTIFICATION" "Email notifications disabled (no mail command found)"
    fi
    
    return 0
}

# Export functions
export -f get_mail_command
export -f is_email_available
export -f get_notification_recipients
export -f get_notification_preferences
export -f build_email_subject
export -f build_email_body
export -f send_email
export -f send_notification
export -f send_task_notification
export -f send_workflow_notification
export -f test_email_config
export -f init_notifications

# Initialize on source
init_notifications

