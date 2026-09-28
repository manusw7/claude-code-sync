#!/bin/bash
# Claude Code Sync - Config sync helpers
# Sourced by lib-claude-sync.sh. Syncs settings, skills, rules, hooks, etc.
#
# Conversations only accumulate (rsync --update, no deletes). Config can't
# work that way: a skill deleted on one machine would come back from the
# other, and settings.json edits would silently clobber each other. So config
# trees are *mirrored* (rsync --delete) with a three-way check against the
# state recorded at the last successful sync on this machine:
#
#   local == repo            -> in sync, nothing to do
#   local == base            -> only the repo changed: repo -> local
#   repo  == base            -> only local changed:    local -> repo (push only)
#   otherwise                -> conflict, stop (CLAUDE_SYNC_CONFIG_FORCE decides)
#
# "base" is a hash of the tree, stored in $SCRIPT_DIR/.sync-state/ (never
# synced, one per machine).

# Parse the semicolon-separated config lists into arrays.
parse_config_lists() {
    CONFIG_PATHS=(); CONFIG_EXTRA_DIRS=(); CONFIG_EXCLUDES=()
    local IFS=';' entry
    for entry in $CLAUDE_SYNC_CONFIG_PATHS; do [ -n "$entry" ] && CONFIG_PATHS+=("$entry"); done
    for entry in $CLAUDE_SYNC_CONFIG_EXTRA_DIRS; do [ -n "$entry" ] && CONFIG_EXTRA_DIRS+=("$entry"); done
    for entry in $CLAUDE_SYNC_CONFIG_EXCLUDES; do [ -n "$entry" ] && CONFIG_EXCLUDES+=("$entry"); done
}

if command -v sha256sum >/dev/null 2>&1; then SHA256_CMD=(sha256sum); else SHA256_CMD=(shasum -a 256); fi

# List "<hash>  <path>" for every file under $1, limited to the paths in the
# array named by $2, skipping CONFIG_EXCLUDES. Prints nothing if $1 is missing.
# Symlinks are listed by target, not followed, so relative links into
# ~/.agents survive the round trip.
config_filelist() {
    local root="$1" paths_var="$2[@]" p
    [ -d "$root" ] || return 0
    (
        cd "$root" || exit 0
        local existing=()
        for p in "${!paths_var}"; do
            { [ -e "$p" ] || [ -L "$p" ]; } && existing+=("$p")
        done
        [ "${#existing[@]}" -eq 0 ] && exit 0

        local prune=() pat
        for pat in "${CONFIG_EXCLUDES[@]}"; do
            [ "${#prune[@]}" -gt 0 ] && prune+=(-o)
            if [[ $pat == */* ]]; then prune+=(-path "$pat" -o -path "*/$pat")
            else prune+=(-name "$pat"); fi
        done
        [ "${#prune[@]}" -eq 0 ] && prune=(-false)

        # /dev/null keeps xargs portable when there are no files (BSD has no -r)
        find "${existing[@]}" \( "${prune[@]}" \) -prune -o -type f -print0 | sort -z | xargs -0 "${SHA256_CMD[@]}" /dev/null
        find "${existing[@]}" \( "${prune[@]}" \) -prune -o -type l -print | sort | while IFS= read -r p; do
            printf 'link:%s  %s\n' "$(readlink "$p")" "$p"
        done
    ) | grep -v '  /dev/null$'
}

# One hash for the whole tree (same arguments as config_filelist).
# Empty output when the tree has no files, so "" means "nothing there".
config_manifest() {
    local list
    list="$(config_filelist "$@")"
    [ -n "$list" ] && printf '%s\n' "$list" | "${SHA256_CMD[@]}" | cut -d' ' -f1
}

# Mirror the config paths (array named by $3) from $1 to $2.
# Paths missing from the source are removed from the destination.
config_mirror() {
    local src="$1" dst="$2" paths_var="$3[@]" p
    local srcs=() excl=()
    mkdir -p "$dst"
    for p in "${!paths_var}"; do
        if [ -e "$src/$p" ] || [ -L "$src/$p" ]; then
            srcs+=("$src/./$p")
        elif [ -e "$dst/$p" ] || [ -L "$dst/$p" ]; then
            rm -rf "${dst:?}/$p"
        fi
    done
    for p in "${CONFIG_EXCLUDES[@]}"; do excl+=(--exclude="$p"); done
    if [ "${#srcs[@]}" -gt 0 ]; then
        # --checksum: git resets mtimes on checkout, so size+mtime can match
        # for a same-size edit and rsync would silently skip it.
        rsync -aR --checksum --delete "${excl[@]}" "${srcs[@]}" "$dst/" >/dev/null || return 1
    fi
    [ "$(config_manifest "$src" "$3")" = "$(config_manifest "$dst" "$3")" ] || {
        echo "Error: $dst does not match $src after copy."
        return 1
    }
}

# Tar the current local config before overwriting it. Local only.
config_backup() {
    local root="$1" paths_var="$2[@]" label="$3" p
    local existing=() excl=()
    for p in "${!paths_var}"; do
        { [ -e "$root/$p" ] || [ -L "$root/$p" ]; } && existing+=("$p")
    done
    [ "${#existing[@]}" -eq 0 ] && return 0
    for p in "${CONFIG_EXCLUDES[@]}"; do excl+=(--exclude="$p"); done
    mkdir -p "$SCRIPT_DIR/backups"
    local file="$SCRIPT_DIR/backups/config-${label}-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$file" "${excl[@]}" -C "$root" "${existing[@]}"
    echo "Backed up local config to $file"
}

# Print the paths that differ between two trees, for conflicts.
config_diff_summary() {
    diff <(config_filelist "$1" "$3") <(config_filelist "$2" "$3") \
        | sed -n 's/^[<>] [^ ]*  /  /p' | sort -u | head -20
}

# Reconcile one config tree.
#   $1 local root   $2 repo root   $3 array name of paths
#   $4 state key    $5 mode: push | pull | status
# Returns 0 on success, 1 on copy failure, 2 on conflict.
config_reconcile() {
    local local_root="$1" repo_root="$2" paths="$3" key="$4" mode="$5"
    local state_dir="$SCRIPT_DIR/.sync-state"
    local state_file="$state_dir/config-$key.base"
    local L R B
    L="$(config_manifest "$local_root" "$paths")"
    R="$(config_manifest "$repo_root" "$paths")"
    B="$(cat "$state_file" 2>/dev/null)"

    local action
    if [ "$L" = "$R" ]; then action=insync
    elif [ -z "$R" ] && [ -z "$B" ]; then action=local   # first machine, repo empty
    elif [ "$L" = "$B" ]; then action=remote
    elif [ "$R" = "$B" ]; then action=local
    else action=conflict; fi

    if [ "$action" = conflict ]; then
        case "$CLAUDE_SYNC_CONFIG_FORCE" in
            local) action=local ;;
            remote) action=remote ;;
        esac
    fi

    if [ "$mode" = status ]; then
        case "$action" in
            insync) echo "  Config: in sync" ;;
            remote) echo "  Config: remote changes (run claude-sync-pull)" ;;
            local) echo "  Config: local changes (run claude-sync-push)" ;;
            conflict) echo "  Config: CONFLICT (changed on both sides since last sync)" ;;
        esac
        return 0
    fi

    mkdir -p "$state_dir"
    case "$action" in
        insync)
            echo "Config: in sync."
            [ -n "$L" ] && echo "$L" > "$state_file"
            ;;
        remote)
            echo "Config: applying remote changes..."
            config_backup "$local_root" "$paths" "$key"
            config_mirror "$repo_root" "$local_root" "$paths" || { echo "Error: config copy failed."; return 1; }
            echo "$R" > "$state_file"
            ;;
        local)
            if [ "$mode" = pull ]; then
                echo "Config: local changes not pushed yet. Run claude-sync-push."
            else
                echo "Config: pushing local changes..."
                config_mirror "$local_root" "$repo_root" "$paths" || { echo "Error: config copy failed."; return 1; }
                echo "$L" > "$state_file"
            fi
            ;;
        conflict)
            echo "Config: CONFLICT - changed both here and on another machine since the last sync."
            echo "Files that differ (local vs repo):"
            config_diff_summary "$local_root" "$repo_root" "$paths"
            echo ""
            echo "Pick a side and re-run:"
            echo "  CLAUDE_SYNC_CONFIG_FORCE=local  claude-sync-push   # keep this machine's config"
            echo "  CLAUDE_SYNC_CONFIG_FORCE=remote claude-sync-pull   # take the repo's config"
            return 2
            ;;
    esac
    return 0
}

# Write the plugin manifest (marketplace sources + installed plugin names)
# for a profile into the repo. Install paths and SHAs are machine-specific,
# so only what's needed to reinstall is kept.
plugins_export() {
    local profile="$1" dest="$2"
    local known="$profile/plugins/known_marketplaces.json"
    local installed="$profile/plugins/installed_plugins.json"
    [ -f "$known" ] && [ -f "$installed" ] || return 0
    command -v jq >/dev/null 2>&1 || { echo "Note: jq not found, skipping plugin list."; return 0; }
    mkdir -p "$dest"
    jq -n --slurpfile k "$known" --slurpfile i "$installed" '{
        marketplaces: ($k[0] | with_entries(.value |= .source)),
        plugins: ($i[0].plugins | keys)
    }' > "$dest/plugins.json"
}

# Install plugins listed in the repo manifest that are missing locally.
# Additive only: never uninstalls anything.
plugins_install_missing() {
    local profile="$1" manifest="$2/plugins.json"
    [ -f "$manifest" ] || return 0
    [ "$CLAUDE_SYNC_CONFIG_PLUGINS" = "true" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    if ! command -v claude >/dev/null 2>&1; then
        echo "Note: 'claude' not on PATH, skipping plugin install."
        return 0
    fi

    # The default profile must not set CLAUDE_CONFIG_DIR: that also moves
    # .claude.json, which would look like a fresh install.
    local env_prefix=()
    [ "$profile" != "$HOME/.claude" ] && env_prefix=(env "CLAUDE_CONFIG_DIR=$profile")

    local known="$profile/plugins/known_marketplaces.json"
    local installed="$profile/plugins/installed_plugins.json"
    local name src
    while IFS=$'\t' read -r name src; do
        [ -n "$src" ] || continue
        if [ -f "$known" ] && jq -e --arg n "$name" 'has($n)' "$known" >/dev/null; then continue; fi
        echo "Adding plugin marketplace: $name ($src)"
        "${env_prefix[@]}" claude plugin marketplace add "$src" || echo "  Warning: could not add $name"
    done < <(jq -r '.marketplaces | to_entries[] | [.key, (
        if .value.source == "github" then .value.repo
        elif .value.source == "git" or .value.source == "url" then .value.url
        else empty end)] | @tsv' "$manifest")

    local plugin
    while IFS= read -r plugin; do
        if [ -f "$installed" ] && jq -e --arg p "$plugin" '.plugins | has($p)' "$installed" >/dev/null; then continue; fi
        echo "Installing plugin: $plugin"
        "${env_prefix[@]}" claude plugin install "$plugin" || echo "  Warning: could not install $plugin"
    done < <(jq -r '.plugins[]' "$manifest")
}

# Run config sync for every Claude profile and extra dir.
#   $1 repo dir   $2 mode: push | pull | status
# Returns non-zero if any tree failed (2 = conflict).
sync_all_config() {
    local repo="$1" mode="$2" rc=0 profile subdir dir name
    [ "$CLAUDE_SYNC_CONFIG" = "true" ] || return 0
    parse_config_lists
    EXTRA_ALL=(".")

    for profile in "${SYNC_PROFILES[@]}"; do
        subdir="$(profile_subdir "$profile")"
        echo "--- Config: $profile -> $subdir/config/ ---"
        config_reconcile "$profile" "$repo/$subdir/config" CONFIG_PATHS "$subdir" "$mode" || rc=$?
        case "$mode" in
            push) plugins_export "$profile" "$repo/$subdir/config" ;;
            pull) plugins_install_missing "$profile" "$repo/$subdir/config" ;;
        esac
        [ "$mode" = status ] || echo ""
    done

    for dir in "${CONFIG_EXTRA_DIRS[@]}"; do
        name="$(basename "$dir")"
        echo "--- Config: $dir -> extra/$name/ ---"
        config_reconcile "$dir" "$repo/extra/$name" EXTRA_ALL "extra-$name" "$mode" || rc=$?
        [ "$mode" = status ] || echo ""
    done
    return $rc
}
