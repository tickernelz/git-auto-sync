#!/usr/bin/env python3
"""
Git Auto-Sync - Sync Engine
Handles actual git operations for multiple repositories
"""

import json
import os
import sys
import subprocess
import time
from datetime import datetime
from pathlib import Path

# Configuration
SCRIPT_DIR = Path(__file__).parent
CONFIG_FILE = SCRIPT_DIR / "config.json"
LOG_DIR = Path("/tmp/git-auto-sync")
LOG_FILE = LOG_DIR / "git-sync.log"
STATUS_FILE = LOG_DIR / "last-sync.json"
LOCK_FILE = LOG_DIR / "lock.pid"

# Ensure log directory exists
LOG_DIR.mkdir(parents=True, exist_ok=True)

def log(message, level="INFO"):
    """Write to log file"""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_line = f"{timestamp} | {level} | {message}\n"
    
    with open(LOG_FILE, "a") as f:
        f.write(log_line)
    
    # Also print if in head mode
    if "--head" in sys.argv:
        print(f"[{timestamp}] {level}: {message}")

def get_config():
    """Load configuration"""
    if not CONFIG_FILE.exists():
        return {"repos": [], "global": {}}
    
    with open(CONFIG_FILE) as f:
        return json.load(f)

def save_status(repo_path, status, message="", branch="main", remote="origin"):
    """Save last sync status"""
    status_data = {
        "repo": repo_path,
        "branch": branch,
        "remote": remote,
        "status": status,
        "message": message,
        "timestamp": datetime.now().isoformat()
    }
    
    with open(STATUS_FILE, "w") as f:
        json.dump(status_data, f, indent=2)

def acquire_lock():
    """Acquire sync lock"""
    if LOCK_FILE.exists():
        try:
            pid = int(LOCK_FILE.read_text().strip())
            # Check if process is still running
            os.kill(pid, 0)
            log(f"Another sync is running (PID: {pid})", "ERROR")
            return False
        except (ProcessLookupError, ValueError):
            # Process dead, remove stale lock
            LOCK_FILE.unlink()
    
    LOCK_FILE.write_text(str(os.getpid()))
    return True

def release_lock():
    """Release sync lock"""
    if LOCK_FILE.exists():
        LOCK_FILE.unlink()

def should_skip_sync():
    """Check if should skip based on quiet hours"""
    config = get_config()
    global_config = config.get("global", {})
    quiet_hours = global_config.get("quietHours", {})
    skip_hours = global_config.get("skipHours", [])
    
    current_hour = datetime.now().hour
    
    # Check quiet hours (e.g., 22:00 - 09:00)
    start = quiet_hours.get("start", 22)
    end = quiet_hours.get("end", 9)
    
    if current_hour >= start or current_hour < end:
        log(f"Quiet hours ({current_hour}:00) - skipping", "SKIP")
        return True
    
    # Check skip hours (e.g., lunch break at 12:00)
    if current_hour in skip_hours:
        log(f"Skip hour ({current_hour}:00) - skipping", "SKIP")
        return True
    
    return False

def has_changes(repo_path):
    """Check if repo has uncommitted changes"""
    try:
        result = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=repo_path,
            capture_output=True,
            text=True
        )
        return bool(result.stdout.strip())
    except Exception as e:
        log(f"Error checking changes in {repo_path}: {e}", "ERROR")
        return False

def git_pull(repo_path, strategy="ours", remote="origin", branch="main"):
    """Pull changes from remote"""
    log(f"Pulling {repo_path} ({remote}/{branch}, strategy: {strategy})")
    
    try:
        # Fetch first
        result = subprocess.run(
            ["git", "fetch", remote],
            cwd=repo_path,
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode != 0:
            log(f"Fetch failed: {result.stderr}", "ERROR")
            return False
        
        # Check if behind
        result = subprocess.run(
            ["git", "rev-list", "--count", f"HEAD..{remote}/{branch}"],
            cwd=repo_path,
            capture_output=True,
            text=True
        )
        behind = int(result.stdout.strip()) if result.stdout.strip() else 0
        
        if behind == 0:
            log("Already up-to-date")
            return True
        
        log(f"Behind by {behind} commit(s), pulling...")
        
        # Pull with conflict strategy
        result = subprocess.run(
            ["git", "pull", "-X", strategy, remote, branch],
            cwd=repo_path,
            capture_output=True,
            text=True,
            timeout=60
        )
        
        if result.returncode == 0:
            log(f"Pull completed ({behind} commits)", "SUCCESS")
            return True
        else:
            log(f"Pull failed: {result.stderr}", "ERROR")
            # Try to abort merge
            subprocess.run(["git", "merge", "--abort"], cwd=repo_path, capture_output=True)
            return False
            
    except subprocess.TimeoutExpired:
        log("Pull timed out", "ERROR")
        return False
    except Exception as e:
        log(f"Pull error: {e}", "ERROR")
        return False

def git_commit(repo_path):
    """Commit changes if any"""
    if not has_changes(repo_path):
        log("No changes to commit")
        return True
    
    try:
        # Add all changes (excluding logs/)
        result = subprocess.run(
            ["git", "add", "-A", "--", ":(exclude)logs/"],
            cwd=repo_path,
            capture_output=True,
            text=True,
            timeout=30
        )
        
        # Count changed files
        result = subprocess.run(
            ["git", "diff", "--cached", "--name-only"],
            cwd=repo_path,
            capture_output=True,
            text=True
        )
        changed = len([l for l in result.stdout.split('\n') if l.strip()])
        
        if changed == 0:
            log("No changes to commit after add")
            return True
        
        # Commit
        message = f"Auto-sync: {changed} file(s) updated - {datetime.now().strftime('%Y-%m-%d %H:%M')}"
        result = subprocess.run(
            ["git", "commit", "-m", message],
            cwd=repo_path,
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode == 0:
            log(f"Committed {changed} file(s)", "SUCCESS")
            return True
        else:
            log(f"Commit failed: {result.stderr}", "ERROR")
            return False
            
    except Exception as e:
        log(f"Commit error: {e}", "ERROR")
        return False

def git_push(repo_path, remote="origin", branch="main"):
    """Push changes to remote"""
    log(f"Pushing {repo_path} ({remote}/{branch})")
    
    try:
        # Check if ahead
        result = subprocess.run(
            ["git", "rev-list", "--count", f"{remote}/{branch}..HEAD"],
            cwd=repo_path,
            capture_output=True,
            text=True
        )
        ahead = int(result.stdout.strip()) if result.stdout.strip() else 0
        
        if ahead == 0:
            log("No new commits to push")
            return True
        
        log(f"Ahead by {ahead} commit(s), pushing...")
        
        # Push with force-if-includes (safer than --force)
        result = subprocess.run(
            ["git", "push", "--force-if-includes", remote, branch],
            cwd=repo_path,
            capture_output=True,
            text=True,
            timeout=60
        )
        
        if result.returncode == 0:
            log(f"Push completed ({ahead} commits)", "SUCCESS")
            return True
        else:
            log(f"Push failed: {result.stderr}", "ERROR")
            return False
            
    except subprocess.TimeoutExpired:
        log("Push timed out", "ERROR")
        return False
    except Exception as e:
        log(f"Push error: {e}", "ERROR")
        return False

def sync_repo(repo_config, dry_run=False, force=False):
    """Sync a single repository"""
    repo_path = Path(repo_config["path"])
    strategy = repo_config.get("strategy", "ours")
    branch = repo_config.get("branch", "main")
    remote = repo_config.get("remote", "origin")
    
    if not repo_path.exists():
        log(f"Repository not found: {repo_path}", "ERROR")
        return False
    
    if not (repo_path / ".git").exists():
        log(f"Not a git repo: {repo_path}", "ERROR")
        return False
    
    log(f"=== Syncing: {repo_path} ===")
    log(f"Branch: {branch} | Remote: {remote} | Strategy: {strategy}")
    
    if dry_run:
        log("DRY RUN - no changes will be made")
        return True
    
    # Pull
    if not git_pull(repo_path, strategy, remote, branch):
        save_status(str(repo_path), "failed", "Pull failed", branch, remote)
        return False
    
    time.sleep(2)
    
    # Commit
    if not git_commit(repo_path):
        save_status(str(repo_path), "failed", "Commit failed", branch, remote)
        return False
    
    time.sleep(2)
    
    # Push
    if not git_push(repo_path, remote, branch):
        save_status(str(repo_path), "failed", "Push failed", branch, remote)
        return False
    
    save_status(str(repo_path), "success", "Sync completed", branch, remote)
    log(f"=== Sync completed: {repo_path} ===")
    return True

def main():
    """Main sync logic"""
    import argparse
    
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", default="headless", choices=["head", "headless"])
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--repo", help="Sync specific repo only")
    args = parser.parse_args()
    
    # Acquire lock
    if not acquire_lock():
        sys.exit(1)
    
    try:
        config = get_config()
        repos = config.get("repos", [])
        
        if not repos:
            log("No repositories configured", "WARNING")
            sys.exit(0)
        
        # Filter by repo if specified
        if args.repo:
            repos = [r for r in repos if r["path"] == args.repo]
            if not repos:
                log(f"Repository not found: {args.repo}", "ERROR")
                sys.exit(1)
        
        # Check quiet hours (skip for manual sync with --force)
        if not args.force and args.mode == "headless":
            if should_skip_sync():
                sys.exit(0)
        
        # Sync each repo
        success_count = 0
        for repo in repos:
            if not repo.get("enabled", True):
                log(f"Skipping disabled repo: {repo['path']}")
                continue
            
            if sync_repo(repo, dry_run=args.dry_run, force=args.force):
                success_count += 1
        
        log(f"Sync completed: {success_count}/{len(repos)} repos successful")
        
    finally:
        release_lock()

if __name__ == "__main__":
    main()
