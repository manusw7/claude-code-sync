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

    # Codex CLI data directory (usually ~/.codex)
    CODEX_DATA_DIR="${CODEX_DATA_DIR:-$HOME/.codex}"
    # Semicolon-separated list of Codex data dirs to sync, same idea as
    # CLAUDE_SYNC_PROFILES. Empty by default: Codex sync is opt-in, since not
    # everyone running this tool has Codex CLI installed.
    CLAUDE_SYNC_CODEX_PROFILES="${CLAUDE_SYNC_CODEX_PROFILES:-}"

    # Files larger than this are not pushed (rsync --max-size syntax).
    # GitHub rejects files over 100 MB; git-crypt adds a few bytes.
    # Empty = no limit.
    CLAUDE_SYNC_MAX_FILE_SIZE="${CLAUDE_SYNC_MAX_FILE_SIZE-95M}"

    # Config sync (settings, skills, rules, hooks, ...). Opt-in. Unlike
    # conversations, config is mirrored with deletes - see lib-config-sync.sh.
    CLAUDE_SYNC_CONFIG="${CLAUDE_SYNC_CONFIG:-false}"
    # Paths relative to each Claude profile dir. Missing ones are skipped.
    CLAUDE_SYNC_CONFIG_PATHS="${CLAUDE_SYNC_CONFIG_PATHS:-settings.json;CLAUDE.md;RTK.md;statusline.sh;keybindings.json;rules;commands;agents;output-styles;hooks;workflows;skills}"
    # Extra dirs mirrored whole, e.g. ~/.agents (target of skills symlinks).
    CLAUDE_SYNC_CONFIG_EXTRA_DIRS="${CLAUDE_SYNC_CONFIG_EXTRA_DIRS:-}"
    # rsync-style patterns never synced. A pattern with / matches a path.
    CLAUDE_SYNC_CONFIG_EXCLUDES="${CLAUDE_SYNC_CONFIG_EXCLUDES:-.git;node_modules;.venv;venv;__pycache__;*.pyc;.DS_Store;.cc-writes;skills/synced}"
    # Install plugins listed in the repo that are missing locally, on pull.
    CLAUDE_SYNC_CONFIG_PLUGINS="${CLAUDE_SYNC_CONFIG_PLUGINS:-true}"

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

# Config sync helpers (config_reconcile, sync_all_config, ...)
source "$(dirname "${BASH_SOURCE[0]}")/lib-config-sync.sh"

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

# Parse CLAUDE_SYNC_CODEX_PROFILES into the global array CODEX_SYNC_PROFILES.
# Same format and trimming rules as parse_profiles(). Left empty when Codex
# sync isn't configured, so callers can just iterate an empty array.
parse_codex_profiles() {
    CODEX_SYNC_PROFILES=()
    local IFS=';'
    local entry
    for entry in $CLAUDE_SYNC_CODEX_PROFILES; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [ -n "$entry" ] && CODEX_SYNC_PROFILES+=("$entry")
    done
}

# Merge a conversation dir into the repo, skipping files over
# CLAUDE_SYNC_MAX_FILE_SIZE (they would make the whole push fail).
#   $1 source dir   $2 destination dir
push_merge_dir() {
    local src="$1" dst="$2" limit=()
    [ -n "$CLAUDE_SYNC_MAX_FILE_SIZE" ] && limit=(--max-size="$CLAUDE_SYNC_MAX_FILE_SIZE")
    rsync -av --update "${limit[@]}" "$src/" "$dst/"
    if [ -n "$CLAUDE_SYNC_MAX_FILE_SIZE" ]; then
        local big
        big="$(find "$src" -type f -size +"$CLAUDE_SYNC_MAX_FILE_SIZE" 2>/dev/null)"
        if [ -n "$big" ]; then
            echo "Skipped (over $CLAUDE_SYNC_MAX_FILE_SIZE, stays on this machine only):"
            echo "$big" | sed 's/^/  /'
        fi
    fi
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

    # Codex profiles are optional: only validate the ones the user configured.
    parse_codex_profiles
    local codex_profile
    for codex_profile in "${CODEX_SYNC_PROFILES[@]}"; do
        if [ ! -d "$codex_profile" ]; then
            echo "Error: Codex profile data directory not found: $codex_profile"
            echo ""
            errors=1
        fi
    done

    if [ "$CLAUDE_SYNC_CONFIG" = "true" ] && ! command -v rsync >/dev/null 2>&1; then
        echo "Error: config sync needs rsync."
        echo ""
        errors=1
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
    parse_codex_profiles
    if [ "${#CODEX_SYNC_PROFILES[@]}" -gt 0 ]; then
        echo "  Codex sync profiles:"
        for profile in "${CODEX_SYNC_PROFILES[@]}"; do
            echo "    - $profile -> conversations/$(profile_subdir "$profile")"
        done
    else
        echo "  Codex sync profiles: none configured"
    fi
    if [ "$CLAUDE_SYNC_CONFIG" = "true" ]; then
        parse_config_lists
        echo "  Config sync: enabled"
        echo "    Paths: ${CONFIG_PATHS[*]}"
        echo "    Extra dirs: ${CONFIG_EXTRA_DIRS[*]:-none}"
        echo "    Excludes: ${CONFIG_EXCLUDES[*]}"
        echo "    Plugin install on pull: $CLAUDE_SYNC_CONFIG_PLUGINS"
    else
        echo "  Config sync: disabled (set CLAUDE_SYNC_CONFIG=true)"
    fi
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
