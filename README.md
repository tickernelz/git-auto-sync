# Git Auto-Sync 🔄

**Universal git repository auto-sync tool for macOS**

Automatically sync multiple git repositories with configurable intervals, smart scheduling, and zero maintenance.

![Platform](https://img.shields.io/badge/platform-macOS-blue)
![Git](https://img.shields.io/badge/git-2.37+-orange)
![License](https://img.shields.io/badge/license-MIT-green)

---

## ⚡ Quick Start

```bash
# Add your first repository
cd ~/Projects/git-auto-sync
./git-auto-sync.sh set ~/.openclaw --interval 60

# Check status
./git-auto-sync.sh status
```

That's it! Your repo will now auto-sync every 60 minutes.

---

## ✨ Features

- ✅ **Multiple Repos** - Sync unlimited git repositories
- ✅ **Smart Scheduling** - Configurable intervals (30-120 min)
- ✅ **Quiet Hours** - No sync during night (22:00-09:00) & lunch (12:00)
- ✅ **Conflict Resolution** - Auto-resolve with `ours` or `theirs` strategy
- ✅ **Branch/Remote** - Sync any branch to any remote
- ✅ **Zero Maintenance** - Runs automatically via launchd
- ✅ **Logs in /tmp** - No clutter in your repos

---

## 📖 Usage

### Add Repository

```bash
# Basic
./git-auto-sync.sh set <repo-path>

# With options
./git-auto-sync.sh set ~/.openclaw --interval 60 --strategy ours --branch main --remote origin
```

**Options:**
| Flag | Default | Description |
|------|---------|-------------|
| `--interval <min>` | 60 | Sync interval in minutes |
| `--strategy <ours\|theirs>` | ours | Conflict resolution |
| `--branch <name>` | main | Branch to sync |
| `--remote <name>` | origin | Remote to use |

### Commands

```bash
./git-auto-sync.sh list              # Show all repos
./git-auto-sync.sh status            # Check service status
./git-auto-sync.sh sync --head       # Manual sync (interactive)
./git-auto-sync.sh sync --force      # Force sync (ignore quiet hours)
./git-auto-sync.sh logs              # View logs
./git-auto-sync.sh unset <repo>      # Remove repo
./git-auto-sync.sh restart           # Restart service
```

---

## ⏰ Schedule

| Trigger | Action |
|---------|--------|
| **Boot** | Sync all repos |
| **Every 30-60 min** | Auto-sync (per repo) |
| **24/7** | Always sync (no quiet hours) |

---

## 📁 Files

```
~/Projects/git-auto-sync/     # Tool location
~/Library/LaunchAgents/       # launchd service
/tmp/git-auto-sync/           # Logs (not committed)
```

---

## 🔧 Requirements

- **macOS** (uses launchd)
- **Git 2.37+** (for `--force-if-includes`)
- **Python 3.6+**

---

## 🐛 Troubleshooting

```bash
# Check status
./git-auto-sync.sh status

# View logs
./git-auto-sync.sh logs

# Force sync
./git-auto-sync.sh sync --force --head

# Restart service
./git-auto-sync.sh restart
```

---

## 📝 Example: Multiple Repos

```bash
# OpenClaw (60 min)
./git-auto-sync.sh set ~/.openclaw --interval 60

# Keepass (30 min)
./git-auto-sync.sh set ~/Sync/keepass --interval 30

# Workspace with custom branch
./git-auto-sync.sh set ~/workspace --interval 45 --branch develop

# List all
./git-auto-sync.sh list
```

---

## 🚀 Uninstall

```bash
./git-auto-sync.sh stop
rm -rf ~/Projects/git-auto-sync
rm ~/Library/LaunchAgents/com.git-auto-sync.plist
rm -rf /tmp/git-auto-sync
```

---

**Version**: 2.0 | **License**: MIT | **Author**: Zhafron Kautsar (@tickernelz)

Made for macOS • No telemetry • Zero config after setup
