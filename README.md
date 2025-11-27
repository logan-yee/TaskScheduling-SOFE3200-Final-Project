# Task Scheduling and Workflows System

## Project Structure

```
TaskScheduling-SOFE3200-Final-Project/
├── README.md                          # Project documentation
├── config/
│   ├── tasks.json                     # Task definitions
│   ├── workflows.json                 # Workflow definitions
│   └── notifications.json             # Notification preferences
├── scripts/
│   ├── scheduler.sh                   # Main scheduler daemon
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

## Core Components

### 1. Task Scheduling System (`scripts/scheduler.sh`, `scripts/task_executor.sh`)

- Parse JSON task definitions from `config/tasks.json`
- Support recurring patterns: daily, weekly, monthly, custom cron expressions
- Use cron/anacron for scheduling with platform detection
- Execute tasks via `task_executor.sh`
- Track task status and next execution times

**Task JSON Schema:**

```json
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
    "delay": 300
  },
  "notifications": {
    "on_success": true,
    "on_failure": true
  }
}
```

### 2. Workflow Management (`scripts/workflow_engine.sh`)

- Parse workflow definitions from `config/workflows.json`
- Implement dependency resolution (DAG-based)
- Execute tasks in correct order based on dependencies
- Handle workflow-level retries and failures
- Support parallel execution where dependencies allow

**Workflow JSON Schema:**

```json
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
```

### 3. Notification System (`scripts/notification.sh`)

- Use system mail commands (sendmail/mailx) with platform detection
- Send notifications on task/workflow success/failure
- Customizable message templates
- Support multiple recipients
- Handle email configuration errors gracefully

### 4. Error Handling and Retries (`lib/error_handler.sh`)

- Implement retry logic with exponential backoff
- Track retry attempts per task/workflow
- Log all failures with timestamps
- Support configurable retry policies
- Mark tasks as permanently failed after max retries

### 5. Logging System (`scripts/logger.sh`)

- Structured logging with timestamps
- Separate log files per task/workflow
- Log rotation support
- Log levels: INFO, WARNING, ERROR, DEBUG
- Central log directory in `logs/`

### 6. CLI Interface (`bin/taskctl`)

Commands:

- `taskctl add-task` - Add new task
- `taskctl list-tasks` - List all tasks
- `taskctl remove-task <id>` - Remove task
- `taskctl add-workflow` - Add new workflow
- `taskctl list-workflows` - List workflows
- `taskctl run-task <id>` - Execute task manually
- `taskctl run-workflow <id>` - Execute workflow manually
- `taskctl status` - Show system status
- `taskctl logs <task_id>` - View task logs
- `taskctl configure` - Configure notifications

### 7. Cross-Platform Support (`lib/platform_detect.sh`)

- Detect OS (Linux, macOS, WSL)
- Select appropriate mail command (mailx, sendmail, mail)
- Choose cron vs anacron based on platform
- Handle path differences

### 8. Cron/Anacron Integration (`scripts/cron_manager.sh`)

- Generate cron entries dynamically
- Install/remove cron jobs programmatically
- Support anacron for systems without cron
- Validate cron syntax
- Handle cron file management safely

## Implementation Details

### Task Execution Flow

1. Scheduler checks for due tasks
2. Task executor runs command and captures output/exit code
3. Error handler processes result (retry if needed)
4. Logger records execution details
5. Notification system sends alerts if configured
6. Update task status in JSON

### Workflow Execution Flow

1. Parse workflow dependencies
2. Build execution order (topological sort)
3. Execute tasks sequentially based on dependencies
4. Handle failures and retries at workflow level
5. Log workflow progress
6. Send workflow completion notifications

### Error Handling Strategy

- Capture exit codes from all commands
- Implement retry with exponential backoff
- Log all errors with context
- Mark tasks as failed after max retries
- Continue workflow execution where possible

## Key Files

1. **`bin/taskctl`** - Main CLI entry point with command parsing
2. **`scripts/scheduler.sh`** - Core scheduling daemon
3. **`scripts/task_executor.sh`** - Task execution with error handling
4. **`scripts/workflow_engine.sh`** - Workflow dependency resolution and execution
5. **`scripts/notification.sh`** - Email notification using system mail
6. **`scripts/logger.sh`** - Centralized logging functions
7. **`scripts/cron_manager.sh`** - Cron job management
8. **`lib/utils.sh`** - Common utility functions (JSON parsing, validation)
9. **`lib/error_handler.sh`** - Retry logic and error management
10. **`lib/platform_detect.sh`** - Platform detection and adaptation
11. **`config/tasks.json`** - Task definitions (initialized empty)
12. **`config/workflows.json`** - Workflow definitions (initialized empty)
13. **`config/notifications.json`** - Notification preferences
14. **`README.md`** - Comprehensive documentation

## Technical Considerations

- Use `jq` for JSON parsing (with fallback to awk/sed if unavailable)
- Implement atomic file operations for JSON updates
- Use file locking to prevent concurrent modifications
- Validate JSON schemas before execution
- Support both relative and absolute paths for commands
- Handle special characters in commands safely
- Implement proper signal handling (SIGTERM, SIGINT)
- Create example configurations in `examples/` directory

### To-dos

- [x] Create project directory structure (config/, scripts/, bin/, lib/, logs/, examples/)
- [x] Implement platform detection library (lib/platform_detect.sh) for cross-platform support
- [x] Create utility library (lib/utils.sh) with JSON parsing, validation, and helper functions
- [x] Implement logging system (scripts/logger.sh) with structured logging and log rotation
- [x] Build error handling and retry system (lib/error_handler.sh) with exponential backoff
- [x] Implement email notification system (scripts/notification.sh) using system mail commands
- [x] Create task execution engine (scripts/task_executor.sh) with output capture and status tracking
- [x] Build cron/anacron integration (scripts/cron_manager.sh) for dynamic job management
- [ ] Implement main scheduler daemon (scripts/scheduler.sh) for recurring task management
- [ ] Create workflow engine (scripts/workflow_engine.sh) with dependency resolution and execution
- [ ] Build CLI interface (bin/taskctl) with all commands (add, list, remove, run, status, logs, configure)
- [ ] Create initial configuration files (tasks.json, workflows.json, notifications.json) with schemas
- [ ] Add example configurations and usage documentation in examples/ directory
- [ ] Write comprehensive README.md with installation, usage, and examples
