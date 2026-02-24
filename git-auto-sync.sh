#!/bin/bash
#
# Git Auto-Sync - Universal Git Repository Sync Tool
# Automatically sync multiple git repositories with configurable intervals
#
# Usage: git-auto-sync <command> [options]
#

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
PLIST_FILE="$HOME/Library/LaunchAgents/com.git-auto-sync.plist"
LOG_DIR="/tmp/git-auto-sync"
LOG_FILE="$LOG_DIR/git-sync.log"
LOCK_FILE="$LOG_DIR/lock.pid"
STATUS_FILE="$LOG_DIR/last-sync.json"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Output helpers
info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }

# Initialize config if not exists
init_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" << 'EOF'
{
  "version": 1,
  "repos": [],
  "global": {
    "quietHours": {
      "start": 22,
      "end": 9
    },
    "skipHours": [12],
    "logRetention": 7,
    "maxLogSize": 10485760
  }
}
EOF
        success "Created config file: $CONFIG_FILE"
    fi
}

# Validate JSON
validate_json() {
    if ! python3 -c "import json; json.load(open('$1'))" 2>/dev/null; then
        error "Invalid JSON in $1"
        return 1
    fi
    return 0
}

# Get config value using python3 (more reliable than jq)
get_config() {
    python3 -c "import json; data=json.load(open('$CONFIG_FILE')); print(data.get('$1', '$2'))" 2>/dev/null
}

# Add repo to sync list
cmd_set() {
    local repo_path=""
    local interval=60
    local strategy="ours"
    local branch="main"
    local remote="origin"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --interval) interval="$2"; shift 2 ;;
            --strategy) strategy="$2"; shift 2 ;;
            --branch) branch="$2"; shift 2 ;;
            --remote) remote="$2"; shift 2 ;;
            *) repo_path="$1"; shift ;;
        esac
    done
    
    if [[ -z "$repo_path" ]]; then
        error "Usage: git-auto-sync set <repo-path> [options]"
        echo ""
        echo "Options:"
        echo "  --interval <min>    Sync interval (default: 60)"
        echo "  --strategy <ours|theirs>  Conflict strategy (default: ours)"
        echo "  --branch <name>     Branch to sync (default: main)"
        echo "  --remote <name>     Remote to use (default: origin)"
        exit 1
    fi
    
    # Convert to absolute path
    repo_path="$(cd "$repo_path" 2>/dev/null && pwd)" || {
        error "Repository not found: $repo_path"
        exit 1
    }
    
    # Verify it's a git repo
    if [[ ! -d "$repo_path/.git" ]]; then
        error "Not a git repository: $repo_path"
        exit 1
    fi
    
    # Verify branch exists
    if ! git -C "$repo_path" rev-parse --verify "$branch" &>/dev/null; then
        error "Branch '$branch' not found in $repo_path"
        echo "Available branches:"
        git -C "$repo_path" branch -a | head -10
        exit 1
    fi
    
    # Verify remote exists
    if ! git -C "$repo_path" remote | grep -q "^${remote}$"; then
        error "Remote '$remote' not found in $repo_path"
        echo "Available remotes:"
        git -C "$repo_path" remote
        exit 1
    fi
    
    init_config
    validate_json "$CONFIG_FILE" || exit 1
    
    # Check if already exists
    local exists=$(python3 -c "
import json
data = json.load(open('$CONFIG_FILE'))
for repo in data.get('repos', []):
    if repo['path'] == '$repo_path':
        print('yes')
        break
else:
    print('no')
" 2>/dev/null)
    
    if [[ "$exists" == "yes" ]]; then
        warning "Repository already in sync list: $repo_path"
        echo "Use 'git-auto-sync unset $repo_path' to remove it first"
        exit 1
    fi
    
    # Add repo to config
    python3 << PYEOF
import json
from datetime import datetime

with open('$CONFIG_FILE', 'r') as f:
    data = json.load(f)

if 'repos' not in data:
    data['repos'] = []

data['repos'].append({
    'path': '$repo_path',
    'interval': $interval,
    'strategy': '$strategy',
    'branch': '$branch',
    'remote': '$remote',
    'enabled': True,
    'added': datetime.now().isoformat()
})

with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
    
    success "Added repository: $repo_path"
    info "Sync interval: $interval minutes"
    info "Conflict strategy: $strategy"
    info "Branch: $branch"
    info "Remote: $remote"
    
    # Generate and load plist
    generate_plist
    load_service
    
    success "Repository is now syncing!"
}

# Remove repo from sync list
cmd_unset() {
    local repo_path="$1"
    
    if [[ -z "$repo_path" ]]; then
        error "Usage: git-auto-sync unset <repo-path>"
        exit 1
    fi
    
    # Convert to absolute path
    repo_path="$(cd "$repo_path" 2>/dev/null && pwd)" || {
        error "Repository not found: $repo_path"
        exit 1
    }
    
    init_config
    
    # Remove repo from config
    python3 << PYEOF
import json

with open('$CONFIG_FILE', 'r') as f:
    data = json.load(f)

data['repos'] = [r for r in data.get('repos', []) if r['path'] != '$repo_path']

with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
    
    success "Removed repository: $repo_path"
    
    # Reload service
    unload_service
    load_service
}

# List all synced repos
cmd_list() {
    init_config
    
    echo ""
    echo "📁 Synced Repositories:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    python3 << PYEOF
import json

with open('$CONFIG_FILE', 'r') as f:
    data = json.load(f)

repos = data.get('repos', [])
if not repos:
    print("  No repositories configured")
    print()
    print("Use 'git-auto-sync set <repo-path>' to add one")
else:
    for i, repo in enumerate(repos, 1):
        status = "✅" if repo.get('enabled', True) else "⏸️"
        print(f"{status} {i}. {repo['path']}")
        print(f"   Interval: {repo.get('interval', 60)} min | Strategy: {repo.get('strategy', 'ours')}")
        print(f"   Added: {repo.get('added', 'unknown')}")
        print()
PYEOF
}

# Show service status
cmd_status() {
    echo ""
    echo "🔧 Git Auto-Sync Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Check launchd service
    if launchctl list | grep -q "com.git-auto-sync"; then
        success "Service: Running"
    else
        error "Service: Not running"
    fi
    
    # Check config
    if [[ -f "$CONFIG_FILE" ]]; then
        success "Config: $CONFIG_FILE"
        local repo_count=$(python3 -c "import json; print(len(json.load(open('$CONFIG_FILE')).get('repos', [])))")
        info "Repositories: $repo_count"
    else
        warning "Config: Not found"
    fi
    
    # Check last sync
    if [[ -f "$STATUS_FILE" ]]; then
        echo ""
        echo "📊 Last Sync:"
        cat "$STATUS_FILE" | python3 -m json.tool 2>/dev/null || cat "$STATUS_FILE"
    fi
    
    # Check logs
    if [[ -f "$LOG_FILE" ]]; then
        echo ""
        echo "📝 Recent Logs:"
        tail -5 "$LOG_FILE" | sed 's/^/   /'
    fi
}

# Start service
cmd_start() {
    load_service
    success "Service started"
}

# Stop service
cmd_stop() {
    unload_service
    success "Service stopped"
}

# Restart service
cmd_restart() {
    unload_service
    load_service
    success "Service restarted"
}

# Manual sync
cmd_sync() {
    local mode="headless"
    local dry_run=false
    local force=false
    local repo_filter=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --head) mode="head"; shift ;;
            --headless) mode="headless"; shift ;;
            --dry-run) dry_run=true; shift ;;
            --force) force=true; shift ;;
            --repo) repo_filter="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    
    init_config
    
    if [[ "$mode" == "head" ]]; then
        echo ""
        echo "🔄 Starting Manual Sync"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
    
    python3 "$SCRIPT_DIR/sync.py" --mode "$mode" $([ "$dry_run" = true ] && echo "--dry-run") $([ "$force" = true ] && echo "--force") $([ -n "$repo_filter" ] && echo "--repo" "$repo_filter")
}

# View logs
cmd_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        warning "No logs found"
        exit 0
    fi
    
    tail -f "$LOG_FILE"
}

# Edit config
cmd_config() {
    init_config
    
    if command -v nano &> /dev/null; then
        nano "$CONFIG_FILE"
    elif command -v vim &> /dev/null; then
        vim "$CONFIG_FILE"
    else
        open "$CONFIG_FILE"
    fi
}

# Generate launchd plist
generate_plist() {
    cat > "$PLIST_FILE" << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.git-auto-sync</string>
    
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>SCRIPT_DIR/git-auto-sync.sh</string>
        <string>sync</string>
        <string>--headless</string>
    </array>
    
    <key>RunAtLoad</key>
    <true/>
    
    <key>StartInterval</key>
    <integer>3600</integer>
    
    <key>StandardOutPath</key>
    <string>/tmp/git-auto-sync/git-sync.log</string>
    
    <key>StandardErrorPath</key>
    <string>/tmp/git-auto-sync/git-sync.err</string>
    
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
PLISTEOF
    
    # Replace SCRIPT_DIR with actual path
    sed -i '' "s|SCRIPT_DIR|$SCRIPT_DIR|g" "$PLIST_FILE"
    
    success "Generated launchd plist: $PLIST_FILE"
}

# Load launchd service
load_service() {
    if [[ ! -f "$PLIST_FILE" ]]; then
        generate_plist
    fi
    
    # Unload first if already loaded
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    
    # Load service
    if launchctl load "$PLIST_FILE" 2>&1; then
        success "Service loaded and started"
    else
        error "Failed to load service"
        exit 1
    fi
}

# Unload launchd service
unload_service() {
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    info "Service unloaded"
}

# Show help
cmd_help() {
    cat << 'HELPEOF'
Git Auto-Sync - Universal Git Repository Sync Tool

Usage: git-auto-sync <command> [options]

Commands:
  set <repo-path>     Add repository to sync list
                      Options:
                        --interval <min>    Sync interval (default: 60)
                        --strategy <ours|theirs>  Conflict strategy (default: ours)
                        --branch <name>     Branch to sync (default: main)
                        --remote <name>     Remote to use (default: origin)
  
  unset <repo-path>   Remove repository from sync list
  
  list                Show all synced repositories
  
  status              Show service status and last sync info
  
  start               Start launchd service
  
  stop                Stop launchd service
  
  restart             Restart launchd service
  
  sync                Manual sync
                      Options:
                        --head             Interactive mode (show output)
                        --headless         Silent mode (for launchd)
                        --dry-run          Test without executing
                        --force            Force sync (ignore quiet hours)
                        --repo <path>      Sync specific repo only
  
  logs                View logs (tail -f mode)
  
  config              Edit configuration file
  
  help                Show this help message

Examples:
  git-auto-sync set ~/.openclaw --interval 60
  git-auto-sync set ~/workspace --interval 30 --strategy ours
  git-auto-sync unset ~/.openclaw
  git-auto-sync list
  git-auto-sync status
  git-auto-sync sync --head
  git-auto-sync logs

Configuration:
  Config file: ~/Projects/git-auto-sync/config.json
  Logs: /tmp/git-auto-sync/git-sync.log
  Service: ~/Library/LaunchAgents/com.git-auto-sync.plist

For more information, see README.md
HELPEOF
}

# Main command router
main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        set) cmd_set "$@" ;;
        unset) cmd_unset "$@" ;;
        list) cmd_list "$@" ;;
        status) cmd_status "$@" ;;
        start) cmd_start "$@" ;;
        stop) cmd_stop "$@" ;;
        restart) cmd_restart "$@" ;;
        sync) cmd_sync "$@" ;;
        logs) cmd_logs "$@" ;;
        config) cmd_config "$@" ;;
        help|--help|-h) cmd_help ;;
        *)
            error "Unknown command: $command"
            echo "Use 'git-auto-sync help' for usage"
            exit 1
            ;;
    esac
}

# Run main
main "$@"
