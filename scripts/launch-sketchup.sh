#!/usr/bin/env bash
# SketchUp Launcher Script for Supex Runtime Development
# Deploys extension sources directly to SketchUp, then launches SketchUp
#
# Usage: launch-sketchup.sh [--detach] [--restart] [--template PATH] [--no-template] [model.skp]
#   --detach        Launch SketchUp, wait for Supex runtime readiness, then exit
#   --restart       Quit existing SketchUp before launching
#   --template PATH Use a startup template when no model is provided
#   --no-template   Launch without a startup template when no model is provided
#   --no-wait-ready Skip waiting for the Supex runtime socket
#   model.skp       Optional path to a SketchUp model file to open on startup

set -euo pipefail

# Determine script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXTENSION_DIR="$PROJECT_ROOT/runtime"

# Source common utilities
source "$SCRIPT_DIR/helpers/common.sh"

usage() {
    cat <<'USAGE'
Usage: launch-sketchup.sh [--detach] [--restart] [--template PATH] [--no-template] [model.skp]
  --detach        Launch SketchUp, wait for Supex runtime readiness, then exit
  --restart       Quit existing SketchUp before launching
  --template PATH Use a startup template when no model is provided
  --no-template   Launch without a startup template when no model is provided
  --no-wait-ready Skip waiting for the Supex runtime socket
  model.skp       Optional path to a SketchUp model file to open on startup
USAGE
}

# Parse options and optional model file argument
DETACH=0
RESTART=0
WAIT_READY=1
TEMPLATE_FILE="${SUPEX_SKETCHUP_TEMPLATE-$PROJECT_ROOT/tests/data/template.skp}"
MODEL_FILE=""
STARTUP_MODEL_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --detach|--detached)
            DETACH=1
            shift
            ;;
        --restart)
            RESTART=1
            shift
            ;;
        --template)
            if [[ -z "${2:-}" ]]; then
                log_error "--template requires a path"
                exit 1
            fi
            TEMPLATE_FILE="$2"
            shift 2
            ;;
        --no-template)
            TEMPLATE_FILE=""
            shift
            ;;
        --no-wait-ready)
            WAIT_READY=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [[ -n "$MODEL_FILE" ]]; then
                log_error "Only one model file can be provided"
                usage
                exit 1
            fi
            if [[ -f "$1" ]]; then
                # Convert to absolute path
                MODEL_FILE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
            else
                log_error "Model file not found: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Configuration
APP_NAME="${SUPEX_SKETCHUP_APP:-SketchUp}"
APP_PROCESS_NAME="${SUPEX_SKETCHUP_PROCESS:-SketchUp}"
export SUPEX_WORKSPACE="${SUPEX_WORKSPACE:-$(pwd)}"
LOG_DIR="$SUPEX_WORKSPACE/.tmp/logs"
SKETCHUP_OUT_FILE="$LOG_DIR/runtime-stdout.log"
SKETCHUP_ERR_FILE="$LOG_DIR/runtime-stderr.log"
CONSOLE_LOG_FILE="$LOG_DIR/runtime-console.log"

# Colors and logging functions are provided by common.sh

# Create log directories
create_log_dirs() {
    for dir in "$LOG_DIR"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
        fi
    done

    # Clean old log files
    [[ -e "$SKETCHUP_OUT_FILE" ]] && rm "$SKETCHUP_OUT_FILE" || true
    [[ -e "$SKETCHUP_ERR_FILE" ]] && rm "$SKETCHUP_ERR_FILE" || true
    [[ -e "$CONSOLE_LOG_FILE" ]] && rm "$CONSOLE_LOG_FILE" || true
}

stop_log_tails() {
    kill "${TAIL_STDERR_PID:-}" 2>/dev/null || true
    kill "${TAIL_CONSOLE_PID:-}" 2>/dev/null || true
}

# Signal handler for graceful shutdown
sigterm_handler() {
    log_warn "Shutdown signal received"

    # Kill tail processes first
    stop_log_tails

    # Save window position (output goes to terminal)
    "$SCRIPT_DIR/helpers/manage-window-position.sh" save || log_warn "Could not save window position"

    # Shutdown SketchUp gracefully
    log_info "Shutting down SketchUp gracefully..."
    osascript "$SCRIPT_DIR/helpers/shutdown-sketchup.applescript"

    exit 0
}

# Set up signal traps - call handler directly without kill 0
trap 'trap "" SIGINT SIGTERM SIGHUP; sigterm_handler' SIGINT SIGTERM SIGHUP



# Clean up any old deployments and validate extension sources
prepare_extension() {
    log_info "Preparing extension for injection..."

    # Check if injector script exists
    local injector_script="$EXTENSION_DIR/src/injector.rb"
    if [[ ! -f "$injector_script" ]]; then
        log_error "Injector script not found: $injector_script"
        exit 1
    fi

    # Check if main extension file exists
    local main_extension="$EXTENSION_DIR/src/supex_runtime.rb"
    if [[ ! -f "$main_extension" ]]; then
        log_error "Main extension file not found: $main_extension"
        exit 1
    fi

    # Check if source directory exists
    local source_dir="$EXTENSION_DIR/src/supex_runtime"
    if [[ ! -d "$source_dir" ]]; then
        log_error "Extension source directory not found: $source_dir"
        exit 1
    fi

    log_success "Extension prepared for injection"
    log_info "Extension will be loaded from: $EXTENSION_DIR"
}

absolute_path() {
    local path="$1"
    local dir
    dir="$(cd "$(dirname "$path")" && pwd)"
    printf '%s/%s\n' "$dir" "$(basename "$path")"
}

prepare_startup_model() {
    if [[ -n "$MODEL_FILE" || -z "$TEMPLATE_FILE" ]]; then
        return 0
    fi

    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        log_error "Template file not found: $TEMPLATE_FILE"
        exit 1
    fi

    local template_path
    template_path="$(absolute_path "$TEMPLATE_FILE")"

    local startup_dir="$SUPEX_WORKSPACE/.tmp"
    mkdir -p "$startup_dir"

    STARTUP_MODEL_FILE="$startup_dir/sketchup-startup.skp"
    cp "$template_path" "$STARTUP_MODEL_FILE"
    log_info "Using startup model copy: $STARTUP_MODEL_FILE"
}

validate_sketchup_app() {
    if [[ "$APP_NAME" == */* ]]; then
        if [[ ! -e "$APP_NAME" ]]; then
            log_error "SketchUp app path not found: $APP_NAME"
            exit 1
        fi
        log_info "SketchUp app: $APP_NAME"
        return 0
    fi

    local bundle_id app_path
    if bundle_id=$(osascript -e "id of app \"$APP_NAME\"" 2>/dev/null) &&
       app_path=$(osascript -e "POSIX path of (path to application \"$APP_NAME\")" 2>/dev/null); then
        APP_NAME="${app_path%/}"
        log_info "SketchUp app: $APP_NAME ($bundle_id)"
        return 0
    fi

    log_error "Could not resolve SketchUp app: $APP_NAME"
    log_info "Set SUPEX_SKETCHUP_APP to the app name or path, for example:"
    log_info "  SUPEX_SKETCHUP_APP='/Applications/SketchUp 2026/SketchUp.app' bash scripts/launch-sketchup.sh --detach"
    exit 1
}

restart_sketchup_if_requested() {
    if [[ "$RESTART" != "1" ]]; then
        return 0
    fi

    if ! pgrep -x "$APP_PROCESS_NAME" > /dev/null; then
        log_info "No existing SketchUp process to restart"
        return 0
    fi

    log_warn "Restart requested; quitting existing SketchUp process..."
    osascript "$SCRIPT_DIR/helpers/shutdown-sketchup.applescript" || log_warn "Could not request graceful SketchUp shutdown"

    if ! wait_for_process_exit "$APP_PROCESS_NAME" 30; then
        log_error "SketchUp did not exit within 30 seconds"
        exit 1
    fi
}

warn_if_sketchup_already_running() {
    if [[ "$RESTART" == "1" ]]; then
        return 0
    fi

    if pgrep -x "$APP_PROCESS_NAME" > /dev/null; then
        log_warn "SketchUp is already running; macOS may ignore new -RubyStartup arguments."
        log_warn "If Supex is not ready, quit SketchUp or rerun with --restart."
    fi
}

start_log_tails() {
    # Start monitoring error output
    touch "$SKETCHUP_ERR_FILE"
    tail -f "$SKETCHUP_ERR_FILE" | sed -u $'s/^/\033[0;31m[ERROR] /' | sed -u $'s/$/\033[0m/' &
    TAIL_STDERR_PID=$!

    # Start monitoring console log output with yellow coloring
    touch "$CONSOLE_LOG_FILE"
    tail -f "$CONSOLE_LOG_FILE" | sed -u $'s/^/\033[1;33m[CONSOLE] /' | sed -u $'s/$/\033[0m/' &
    TAIL_CONSOLE_PID=$!
}

wait_for_supex_runtime() {
    if [[ "$WAIT_READY" != "1" ]]; then
        log_warn "Skipping Supex runtime readiness check"
        return 0
    fi

    local timeout="${SUPEX_LAUNCH_READY_TIMEOUT:-60}"
    local elapsed=0

    log_info "Waiting for Supex runtime to accept CLI connections..."
    while ((elapsed < timeout)); do
        if SUPEX_AGENT=launcher SUPEX_PLAIN=1 SUPEX_LOG_DIR="$LOG_DIR" "$PROJECT_ROOT/supex" status >/dev/null 2>&1; then
            log_success "Supex runtime is ready"
            return 0
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    log_error "Supex runtime did not become ready within ${timeout}s"
    log_info "Check logs:"
    log_info "  $CONSOLE_LOG_FILE"
    log_info "  $SKETCHUP_ERR_FILE"
    return 1
}

# Launch SketchUp
launch_sketchup() {
    log_info "Launching SketchUp with Ruby injector..."
    restart_sketchup_if_requested
    warn_if_sketchup_already_running

    # Path to our injector script
    local injector_script="$EXTENSION_DIR/src/injector.rb"

    # Prepare launch arguments
    local args=()
    args+=(--stdout "$SKETCHUP_OUT_FILE")
    args+=(--stderr "$SKETCHUP_ERR_FILE")

    # Add model file if specified (must come before -a)
    if [[ -n "$MODEL_FILE" ]]; then
        args+=("$MODEL_FILE")
        log_info "Opening model: $MODEL_FILE"
    elif [[ -n "$STARTUP_MODEL_FILE" ]]; then
        args+=("$STARTUP_MODEL_FILE")
    fi

    args+=(-a "$APP_NAME")
    args+=(--args)
    args+=(-RubyStartup "$injector_script")

    if [[ "$DETACH" != "1" ]]; then
        start_log_tails
    fi

    # Launch SketchUp in background
    log_success "SketchUp is starting with injected extension..."
    log_info "Extension loaded directly from source directory via -RubyStartup"
    log_info "Use 'Extensions > Supex Runtime > Reload Extension' to pick up code changes"
    log_info "Or run './supex reload'"
    log_info "Set SUPEX_VERBOSE=1 for detailed loading information"
    log_info "Console output appears in ${YELLOW}yellow${NC} with [CONSOLE] prefix"
    if [[ "$DETACH" == "1" ]]; then
        log_info "Detach mode enabled; launcher will exit after readiness checks"
    fi

    # Launch SketchUp without -W flag first to allow window positioning
    open "${args[@]}"

    # Wait for SketchUp to start with exponential backoff
    local process_timeout="${SUPEX_LAUNCH_PROCESS_TIMEOUT:-30}"
    if ! wait_for_process "$APP_PROCESS_NAME" "$process_timeout"; then
        log_error "SketchUp failed to start within ${process_timeout} seconds"
        log_info "If your process has a different name, set SUPEX_SKETCHUP_PROCESS."
        exit 1
    fi

    # Restore window position after launch
    log_info "Restoring window position..."
    "$SCRIPT_DIR/helpers/manage-window-position.sh" restore || log_warn "Could not restore window position"

    if ! wait_for_supex_runtime; then
        stop_log_tails
        exit 1
    fi

    if [[ "$DETACH" == "1" ]]; then
        log_success "Detached launch complete; SketchUp remains running"
        return 0
    fi

    log_info "Use Ctrl+C to stop monitoring and shutdown SketchUp"

    # Now wait for SketchUp to exit using a loop
    while pgrep -x "$APP_PROCESS_NAME" > /dev/null; do
        sleep 1
    done

    # Clean up tail processes
    stop_log_tails
}

# Main execution
main() {
    log_info "Starting SketchUp launcher for Supex development"
    if [[ "$DETACH" == "1" ]]; then
        log_info "Mode: detach"
    fi
    if [[ -n "$MODEL_FILE" ]]; then
        log_info "Model: $(basename "$MODEL_FILE")"
    fi
    log_info "======================================================="

    # Required by manage-window-position.sh during restore/shutdown.
    require_jq
    create_log_dirs
    prepare_extension
    prepare_startup_model
    validate_sketchup_app
    launch_sketchup

    log_success "SketchUp session completed"
}

# Run main function
main "$@"
