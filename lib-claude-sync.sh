#!/bin/bash
# Claude Code Sync - Shared Library Functions
# Source this file in other scripts to load configuration

# Load configuration with proper precedence
load_config() {
    local SCRIPT_DIR="$1"

    # Set defaults (env vars preserved via ${:-} syntax in config files)
    CLAUDE_SYNC_REMOTE="${CLAUDE_SYNC_REMOTE:-}"
    CLAUDE_SYNC_BRANCH="${CLAUDE_SYNC_BRANCH:-main}"
    CLAUDE_SYNC_ENCRYPTION="${CLAUDE_SYNC_ENCRYPTION:-false}"
    CLAUDE_BACKUP_RETENTION_DAYS="${CLAUDE_BACKUP_RETENTION_DAYS:-30}"
    CLAUDE_DATA_DIR="${CLAUDE_DATA_DIR:-$HOME/.claude}"
    CLAUDE_SYNC_VERBOSE="${CLAUDE_SYNC_VERBOSE:-false}"
    CLAUDE_SYNC_COMMIT_MSG="${CLAUDE_SYNC_COMMIT_MSG:-Sync conversations - {date} {time} - {hostname}}"
    # Semicolon-separated list of Claude data dirs to sync. Each profile is
    # stored under conversations/<basename>/ in the repo. Defaults to the single
    # CLAUDE_DATA_DIR for backward compatibility.
    CLAUDE_SYNC_PROFILES="${CLAUDE_SYNC_PROFILES:-}"

    # Load shared config if exists (won't override env vars due to ${:-} syntax)
    if [ -f "$SCRIPT_DIR/.claude-sync-config" ]; then
        source "$SCRIPT_DIR/.claude-sync-config"
    fi

    # Load local config if exists (won't override env vars due to ${:-} syntax)
    if [ -f "$SCRIPT_DIR/.claude-sync-config.local" ]; then
        source "$SCRIPT_DIR/.claude-sync-config.local"
    fi

    # Fall back to single-profile mode if not explicitly configured
    if [ -z "$CLAUDE_SYNC_PROFILES" ]; then
        CLAUDE_SYNC_PROFILES="$CLAUDE_DATA_DIR"
    fi
}

# Parse CLAUDE_SYNC_PROFILES into the global array SYNC_PROFILES.
# Each entry is an absolute path to a Claude data dir.
parse_profiles() {
    SYNC_PROFILES=()
    local IFS=';'
    local entry
    for entry in $CLAUDE_SYNC_PROFILES; do
        # Trim whitespace
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [ -n "$entry" ] && SYNC_PROFILES+=("$entry")
    done
}

# Subdir name within the conversations repo for a given data dir
profile_subdir() {
    basename "$1"
}

# Validate required configuration
validate_config() {
    local errors=0

    if [ -z "$CLAUDE_SYNC_REMOTE" ]; then
        echo "Error: CLAUDE_SYNC_REMOTE not configured."
        echo ""
        echo "Set it by:"
        echo "  1. Running: claude-config"
        echo "  2. Or set environment variable: export CLAUDE_SYNC_REMOTE=\"git@bitbucket.org:user/repo.git\""
        echo "  3. Or edit: .claude-sync-config.local"
        echo ""
        errors=1
    fi

    parse_profiles
    if [ "${#SYNC_PROFILES[@]}" -eq 0 ]; then
        echo "Error: No sync profiles configured."
        echo ""
        echo "Set CLAUDE_SYNC_PROFILES (semicolon-separated data dirs) or CLAUDE_DATA_DIR."
        echo ""
        errors=1
    else
        local profile
        for profile in "${SYNC_PROFILES[@]}"; do
            if [ ! -d "$profile" ]; then
                echo "Error: Profile data directory not found: $profile"
                echo ""
                errors=1
            fi
        done
    fi

    return $errors
}

# Show current configuration (for debugging)
show_config() {
    echo "Current configuration:"
    echo "  Remote: ${CLAUDE_SYNC_REMOTE:-<not set>}"
    echo "  Branch: $CLAUDE_SYNC_BRANCH"
    echo "  Encryption: $CLAUDE_SYNC_ENCRYPTION"
    echo "  Data directory: $CLAUDE_DATA_DIR"
    parse_profiles
    echo "  Sync profiles:"
    local profile
    for profile in "${SYNC_PROFILES[@]}"; do
        echo "    - $profile -> conversations/$(profile_subdir "$profile")"
    done
    echo "  Backup retention: $CLAUDE_BACKUP_RETENTION_DAYS days"
}

# Verbose output helper
log_verbose() {
    if [ "$CLAUDE_SYNC_VERBOSE" = "true" ]; then
        echo "$@"
    fi
}

# Show version from VERSION file
show_version() {
    local SCRIPT_DIR="$1"
    local COMMAND_NAME="$2"

    if [ -f "$SCRIPT_DIR/VERSION" ]; then
        local VERSION=$(cat "$SCRIPT_DIR/VERSION")
        echo "$COMMAND_NAME version $VERSION"
    else
        echo "$COMMAND_NAME version unknown (VERSION file not found)"
    fi
}
