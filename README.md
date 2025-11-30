# Task Scheduling and Workflows System

A comprehensive bash-based task scheduling and workflow management system with support for recurring tasks, dependency-based workflows, error handling, retries, and email notifications.

## Features

- ✅ **Task Management**: Create, list, remove, and execute tasks with flexible scheduling
- ✅ **Workflow Management**: Define workflows with task dependencies (DAG-based)
- ✅ **Scheduling**: Support for daily, weekly, monthly, and custom cron expressions
- ✅ **Error Handling**: Automatic retries with exponential backoff
- ✅ **Logging**: Structured logging with rotation and per-task logs
- ✅ **Notifications**: Email notifications on task/workflow success/failure
- ✅ **CLI Interface**: Interactive command-line tool for managing the system
- ✅ **Cross-Platform**: Works on Linux, macOS, and WSL
- ✅ **Cron Integration**: Automatic cron job management

## Project Structure

```
TaskScheduling-SOFE3200-Final-Project/
├── README.md                          # Project documentation
├── config/
│   ├── tasks.json                     # Task definitions (array format)
│   ├── workflows.json                 # Workflow definitions
│   └── notifications.json             # Notification preferences
├── scripts/
│   ├── task_executor.sh               # Task execution engine
│   ├── workflow_engine.sh             # Workflow coordinator
│   ├── notification.sh                # Email notification handler
│   ├── logger.sh                      # Logging utilities
│   └── cron_manager.sh                # Cron/anacron integration
├── bin/
│   └── taskctl                        # Main CLI tool
├── lib/
│   ├── utils.sh                       # Utility functions
│   ├── error_handler.sh               # Error handling and retries
│   └── platform_detect.sh             # Cross-platform detection
├── logs/                              # Execution logs directory
└── examples/                          # Example configurations
```

## Installation

### Prerequisites

- Bash 4.0 or higher
- `jq` (recommended) - for JSON parsing
  ```bash
  # Ubuntu/Debian
  sudo apt-get install jq
  
  # macOS
  brew install jq
  
  # Or use fallback parsing (limited functionality)
  ```

### Dependencies

- **Email Notifications**: One of the following mail commands
  ```bash
  # Ubuntu/Debian
  sudo apt-get install mailutils      # Provides 'mail' command
  # OR
  sudo apt-get install bsd-mailx      # Provides 'mailx' command
  
  # macOS (usually pre-installed)
  # mail command is typically available
  ```

- **Cron**: Usually pre-installed on Unix-like systems
  ```bash
  # Verify cron is available
  which crontab
  ```

### Setup

1. Clone or download the project
2. Make the CLI executable:
   ```bash
   chmod +x bin/taskctl
   ```

3. (Optional) Add to PATH for easier access:
   ```bash
   export PATH="$PATH:/path/to/TaskScheduling-SOFE3200-Final-Project/bin"
   ```

4. Initialize configuration (optional - files are created automatically):
   ```bash
   ./bin/taskctl configure
   ```

## Quick Start

### 1. Add Your First Task

```bash
./bin/taskctl add-task
```

Follow the interactive prompts to create a task. Example:
- **Task ID**: `backup_daily`
- **Name**: `Daily Backup`
- **Command**: `/path/to/backup.sh`
- **Schedule**: Choose daily at 2:00 AM
- **Retry**: 3 attempts with 60s delay
- **Notifications**: Enable for failures

### 2. List Tasks

```bash
./bin/taskctl list-tasks
```

### 3. Run a Task Manually

```bash
./bin/taskctl run-task backup_daily
```

### 4. Sync Cron Jobs

After adding scheduled tasks, sync them with cron:

```bash
./bin/taskctl sync-cron
```

### 5. Check System Status

```bash
./bin/taskctl status
```

## CLI Commands

### Task Management

| Command | Description |
|---------|-------------|
| `taskctl list-tasks` | List all defined tasks |
| `taskctl add-task` | Add a new task (interactive) |
| `taskctl remove-task <id>` | Remove a task by ID |
| `taskctl show-task <id>` | Show detailed task information |
| `taskctl run-task <id>` | Execute a task manually |

### Workflow Management

| Command | Description |
|---------|-------------|
| `taskctl list-workflows` | List all defined workflows |
| `taskctl add-workflow` | Add a new workflow (interactive) |
| `taskctl remove-workflow <id>` | Remove a workflow by ID |
| `taskctl show-workflow <id>` | Show detailed workflow information |
| `taskctl run-workflow <id>` | Execute a workflow manually |

### System Management

| Command | Description |
|---------|-------------|
| `taskctl status` | Show system status and component availability |
| `taskctl logs [id]` | View logs (specific task/workflow or all) |
| `taskctl sync-cron` | Sync cron jobs with task schedules |
| `taskctl test-email [recipient]` | Test email notification configuration |

### Configuration

| Command | Description |
|---------|-------------|
| `taskctl configure` | Configure notification settings (interactive) |

## Configuration Files

### Tasks (`config/tasks.json`)

Tasks are stored as a JSON array. Each task has the following structure:

```json
[
  {
    "id": "task_001",
    "name": "Daily Backup",
    "command": "/path/to/backup.sh",
    "schedule": {
      "type": "daily",
      "time": "02:00"
    },
    "retry": {
      "max_attempts": 3,
      "delay": 60
    },
    "notifications": {
      "on_success": false,
      "on_failure": true
    }
  }
]
```

**Schedule Types:**
- `manual` - Run only when manually triggered
- `daily` - Run daily at specified time (requires `time` field)
- `weekly` - Run weekly (requires `day` 0-6 and `time` fields)
- `monthly` - Run monthly (requires `day` 1-31 and `time` fields)
- `cron` - Custom cron expression (requires `cron` field)

### Workflows (`config/workflows.json`)

Workflows define task dependencies and execution order:

```json
{
  "workflows": [
    {
      "id": "workflow_001",
      "name": "Deployment Pipeline",
      "tasks": [
        {"task_id": "task_001", "dependencies": []},
        {"task_id": "task_002", "dependencies": ["task_001"]},
        {"task_id": "task_003", "dependencies": ["task_001", "task_002"]}
      ],
      "retry": {
        "max_attempts": 2
      }
    }
  ]
}
```

**Dependency Resolution:**
- Tasks are executed in topological order based on dependencies
- Circular dependencies are detected and prevented
- Independent tasks can run in parallel (future enhancement)

### Notifications (`config/notifications.json`)

Configure email notification recipients:

```json
{
  "recipients": {
    "success": ["admin@example.com"],
    "failure": ["admin@example.com", "alerts@example.com"],
    "default": ["admin@example.com"]
  }
}
```

For local testing, use your system username:
```json
{
  "recipients": {
    "default": ["your_username"]
  }
}
```

## Core Components

### 1. Task Execution Engine (`scripts/task_executor.sh`)

- Executes tasks and captures output
- Tracks execution state and status
- Integrates with error handling and retries
- Records execution logs
- Sends notifications on completion

### 2. Workflow Engine (`scripts/workflow_engine.sh`)

- Parses workflow definitions
- Resolves task dependencies (DAG-based)
- Executes tasks in correct order
- Handles workflow-level retries
- Supports parallel execution where possible

### 3. Error Handling (`lib/error_handler.sh`)

- Retry logic with exponential backoff
- Configurable retry policies
- Tracks retry attempts per task/workflow
- Logs all failures with timestamps
- Marks tasks as permanently failed after max retries

### 4. Logging System (`scripts/logger.sh`)

- Structured logging with timestamps
- Separate log files per task/workflow
- Log rotation (configurable size and file count)
- Log levels: DEBUG, INFO, WARNING, ERROR
- Central log directory: `logs/`

### 5. Notification System (`scripts/notification.sh`)

- Platform-aware mail command detection
- Supports mailx, mail, and sendmail
- Customizable email templates
- Multiple recipients support
- Graceful handling of missing mail commands

### 6. Cron Manager (`scripts/cron_manager.sh`)

- Dynamic cron job installation/removal
- Validates cron expressions
- Syncs with task configuration
- Platform detection (Linux, macOS, WSL)
- Safe crontab file management

### 7. Platform Detection (`lib/platform_detect.sh`)

- Detects OS (Linux, macOS, WSL)
- Selects appropriate mail command
- Chooses cron vs anacron
- Handles path differences

## Usage Examples

### Example 1: Daily Backup Task

```bash
# Add task
./bin/taskctl add-task
# Enter: backup_daily, Daily Backup, /usr/local/bin/backup.sh
# Choose: daily schedule at 02:00
# Enable failure notifications

# Sync with cron
./bin/taskctl sync-cron

# Check status
./bin/taskctl status
```

### Example 2: Workflow with Dependencies

```bash
# Create tasks first
./bin/taskctl add-task  # task: build
./bin/taskctl add-task  # task: test
./bin/taskctl add-task  # task: deploy

# Create workflow
./bin/taskctl add-workflow
# Enter: deployment_pipeline
# Add tasks: build (no deps), test (depends on build), deploy (depends on test)

# Run workflow
./bin/taskctl run-workflow deployment_pipeline
```

### Example 3: View Logs

```bash
# View all logs
./bin/taskctl logs

# View specific task logs
./bin/taskctl logs backup_daily
```

### Example 4: Test Email Configuration

```bash
# Test with default recipient
./bin/taskctl test-email

# Test with specific recipient
./bin/taskctl test-email admin@example.com
```

## Architecture

### Task Execution Flow

1. **Scheduler/Cron** triggers task execution
2. **Task Executor** runs the command and captures output
3. **Error Handler** processes result (retries if needed)
4. **Logger** records execution details
5. **Notification System** sends alerts if configured
6. **State** is updated in execution state files

### Workflow Execution Flow

1. **Workflow Engine** parses workflow definition
2. **Dependency Resolution** builds execution order (topological sort)
3. **Task Execution** runs tasks sequentially based on dependencies
4. **Error Handling** manages failures and retries at workflow level
5. **Logging** records workflow progress
6. **Notifications** sent on workflow completion

## Technical Details

### JSON Format

- **Tasks**: Stored as array `[]` format (not `{"tasks": []}`)
- **Workflows**: Stored as object with `workflows` array
- **Automatic Conversion**: System automatically converts old object format to array format

### File Operations

- Atomic file operations for JSON updates
- Backup files created before modifications
- Validation before writing
- Safe error recovery

### Error Handling

- Exit codes captured from all commands
- Exponential backoff for retries
- Context-rich error logging
- Graceful degradation when components unavailable

## Troubleshooting

### Email Notifications Not Working

1. Check if mail command is available:
   ```bash
   which mailx mail sendmail
   ```

2. Install mail command:
   ```bash
   sudo apt-get install mailutils  # Ubuntu/Debian
   ```

3. Test email configuration:
   ```bash
   ./bin/taskctl test-email
   ```

4. Check notification config:
   ```bash
   cat config/notifications.json
   ```

### Cron Jobs Not Running

1. Verify cron is available:
   ```bash
   ./bin/taskctl status
   ```

2. Sync cron jobs:
   ```bash
   ./bin/taskctl sync-cron
   ```

3. Check cron jobs:
   ```bash
   crontab -l
   ```

### Tasks Not Found

1. Verify tasks.json format (should be array):
   ```bash
   cat config/tasks.json | jq '.'
   ```

2. List tasks:
   ```bash
   ./bin/taskctl list-tasks
   ```

3. The system automatically normalizes format if needed

---

**Note**: This system is designed for Unix-like operating systems (Linux, macOS, WSL). Windows native support is not provided, but WSL works well.
