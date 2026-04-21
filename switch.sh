#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$HOME/.claude-switch"
CRED_LINK="$HOME/.claude/.credentials.json"
ACCOUNTS_FILE="$DATA_DIR/accounts.json"

# Ensure data directory exists
mkdir -p "$DATA_DIR"

# Colors
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
RESET='\033[0m'

has_jq() { command -v jq &>/dev/null; }
has_gum() { command -v gum &>/dev/null; }

die() { echo -e "${BOLD}Error:${RESET} $1" >&2; exit 1; }

has_jq  || die "jq is required. Install: brew install jq  /  sudo apt install jq"
has_gum || die "gum is required. Install: brew install gum  /  go install github.com/charmbracelet/gum@latest"

# Bootstrap accounts.json on first run
if [[ ! -f "$ACCOUNTS_FILE" ]]; then
    echo '{}' > "$ACCOUNTS_FILE"
    echo -e "${CYAN}First run — created $ACCOUNTS_FILE${RESET}"
    echo -e "${DIM}Run 'claude-switch import' to import your current session, or 'claude-switch add' to add a new account.${RESET}"
fi

# Get the currently active account number from symlink
get_active() {
    if [[ -L "$CRED_LINK" ]]; then
        local target
        target=$(readlink "$CRED_LINK")
        if [[ "$target" =~ account([0-9]+)\.credentials\.json$ ]]; then
            echo "${BASH_REMATCH[1]}"
            return
        fi
    fi
    echo ""
}

# Get account metadata field
get_meta() {
    local id="$1" field="$2"
    jq -r --arg id "$id" --arg f "$field" '.[$id][$f] // ""' "$ACCOUNTS_FILE"
}

# Update lastUsed timestamp
touch_account() {
    local id="$1"
    local now
    now=$(date -Iseconds)
    local tmp
    tmp=$(jq --arg id "$id" --arg now "$now" '.[$id].lastUsed = $now' "$ACCOUNTS_FILE")
    echo "$tmp" > "$ACCOUNTS_FILE"
}

# Pull metadata from claude auth status and update accounts.json
sync_metadata() {
    local id="$1"
    local auth_json
    auth_json=$(gum spin --title "Syncing account info…" --show-output -- claude auth status 2>/dev/null) || return 0

    local email org_name sub_type
    email=$(echo "$auth_json" | jq -r '.email // ""')
    org_name=$(echo "$auth_json" | jq -r '.orgName // ""')
    sub_type=$(echo "$auth_json" | jq -r '.subscriptionType // ""')

    # Auto-fill username from email
    [[ -n "$email" ]] && {
        local tmp
        tmp=$(jq --arg id "$id" --arg v "$email" '.[$id].username = $v' "$ACCOUNTS_FILE")
        echo "$tmp" > "$ACCOUNTS_FILE"
    }

    # Auto-fill description from org + subscription if description is empty
    local current_desc
    current_desc=$(get_meta "$id" "description")
    if [[ -z "$current_desc" && ( -n "$org_name" || -n "$sub_type" ) ]]; then
        local desc=""
        [[ -n "$org_name" ]] && desc="$org_name"
        [[ -n "$sub_type" ]] && desc="${desc:+$desc · }$sub_type"
        local tmp
        tmp=$(jq --arg id "$id" --arg v "$desc" '.[$id].description = $v' "$ACCOUNTS_FILE")
        echo "$tmp" > "$ACCOUNTS_FILE"
    fi

    # Auto-fill identifier from org if still default
    local current_name
    current_name=$(get_meta "$id" "identifier")
    if [[ "$current_name" == "Account $id" && -n "$org_name" ]]; then
        local tmp
        tmp=$(jq --arg id "$id" --arg v "$org_name" '.[$id].identifier = $v' "$ACCOUNTS_FILE")
        echo "$tmp" > "$ACCOUNTS_FILE"
    fi
}

# Get list of account IDs
get_account_ids() {
    jq -r 'keys[]' "$ACCOUNTS_FILE" | sort -n
}

# Get credential info from the credentials file
get_cred_info() {
    local id="$1"
    local cred_file="$DATA_DIR/account${id}.credentials.json"
    if [[ -f "$cred_file" ]]; then
        jq -r '.claudeAiOauth | "\(.subscriptionType // "unknown") · \(.rateLimitTier // "default")"' "$cred_file"
    else
        echo "no credentials"
    fi
}

# Format relative time (GNU date and BSD date compatible)
relative_time() {
    local ts="$1"
    [[ -z "$ts" ]] && echo "never" && return
    local then_epoch now_epoch diff
    if then_epoch=$(date -d "$ts" +%s 2>/dev/null); then
        :
    else
        local ts_stripped="${ts%+*}"; ts_stripped="${ts_stripped%Z}"
        then_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$ts_stripped" +%s 2>/dev/null) || { echo "unknown"; return; }
    fi
    now_epoch=$(date +%s)
    diff=$(( now_epoch - then_epoch ))
    if (( diff < 60 )); then echo "just now"
    elif (( diff < 3600 )); then echo "$(( diff / 60 ))m ago"
    elif (( diff < 86400 )); then echo "$(( diff / 3600 ))h ago"
    else echo "$(( diff / 86400 ))d ago"
    fi
}

# Build display line for an account
account_line() {
    local id="$1"
    local active
    active=$(get_active)
    local name username desc last_used cred_info marker
    name=$(get_meta "$id" "identifier")
    username=$(get_meta "$id" "username")
    desc=$(get_meta "$id" "description")
    last_used=$(get_meta "$id" "lastUsed")
    cred_info=$(get_cred_info "$id")
    [[ -z "$name" ]] && name="Account $id"

    if [[ "$id" == "$active" ]]; then
        marker="* "
    else
        marker="  "
    fi

    local line="${marker}${id}: ${name}"
    [[ -n "$username" ]] && line+=" (${username})"
    [[ -n "$desc" ]] && line+=" — ${desc}"
    line+=" - ${cred_info}"
    line+=" · $(relative_time "$last_used")"
    echo "$line"
}

# Switch to account N
do_switch() {
    local id="$1"
    local cred_file="$DATA_DIR/account${id}.credentials.json"
    [[ -f "$cred_file" ]] || die "Credentials file not found: $cred_file"

    # Check if already active
    if [[ "$(get_active)" == "$id" ]]; then
        echo -e "${YELLOW}Already on account $id ($(get_meta "$id" "identifier"))${RESET}"
        sync_metadata "$id"
        return
    fi

    rm -f "$CRED_LINK"
    ln -s "$cred_file" "$CRED_LINK"
    touch_account "$id"
    sync_metadata "$id"

    local name
    name=$(get_meta "$id" "identifier")
    echo -e "${GREEN}Switched to account $id${RESET} (${name})"
    echo -e "${DIM}Start a new Claude session to use this account.${RESET}"
}

# Show status
do_status() {
    local active
    active=$(get_active)
    echo -e "${BOLD}Claude Account Switcher${RESET}"
    echo "────────────────────────────────────"
    for id in $(get_account_ids); do
        local line
        line=$(account_line "$id")
        if [[ "$id" == "$active" ]]; then
            echo -e "${GREEN}${line}${RESET}"
        else
            echo -e "  ${line}"
        fi
    done
    echo "────────────────────────────────────"
    if [[ -n "$active" ]]; then
        echo -e "Active: ${BOLD}$(get_meta "$active" "identifier")${RESET} (account $active)"
    else
        echo -e "${YELLOW}No active account (not managed by claude-switch)${RESET}"
    fi
}

# Fetch and display auth info for active account
do_sync_info() {
    local active
    active=$(get_active)
    [[ -z "$active" ]] && die "No active account"

    local auth_json
    auth_json=$(gum spin --title "Fetching account info…" --show-output -- claude auth status 2>/dev/null) || die "Failed to get auth status"

    sync_metadata "$active"

    echo ""
    echo -e "${BOLD}Account $active — $(get_meta "$active" "identifier")${RESET}"
    echo "────────────────────────────────────"
    echo "$auth_json" | jq -r '
        "  Email:        \(.email // "n/a")",
        "  Org:          \(.orgName // "n/a")",
        "  Subscription: \(.subscriptionType // "n/a")",
        "  Auth method:  \(.authMethod // "n/a")",
        "  Provider:     \(.apiProvider // "n/a")"
    '
    echo "────────────────────────────────────"
}

# Interactive menu
do_menu() {
    local active
    active=$(get_active)
    local lines=()
    local ids=()

    for id in $(get_account_ids); do
        ids+=("$id")
        lines+=("$(account_line "$id")")
    done

    lines+=("──────────────────────────────────")
    lines+=("⟳ Sync account info")
    lines+=("⬇ Import current session")
    lines+=("+ Add new account")
    lines+=("✎ Edit account")
    lines+=("✗ Remove account")

    local header="Claude Account Switcher"
    [[ -n "$active" ]] && header+=" │ Active: $(get_meta "$active" "identifier")"

    local choice
    choice=$(printf '%s\n' "${lines[@]}" | gum choose --header "$header" --cursor-prefix "▸ " --unselected-prefix "  ") || exit 0

    case "$choice" in
        *"Sync account info"*)
            do_sync_info
            ;;
        *"Import current session"*)
            do_import
            ;;
        *"Add new account"*)
            do_add
            ;;
        *"Edit account"*)
            local edit_choice edit_id
            edit_choice=$(printf '%s\n' "${lines[@]}" | grep -P '^\s*\*?\s*\d+:' | gum choose --header "Edit which account?" --cursor-prefix "▸ " --unselected-prefix "  ") || return
            edit_id=$(echo "$edit_choice" | grep -oP '^\s*\*?\s*\K\d+(?=:)')
            [[ -n "$edit_id" ]] && do_edit "$edit_id"
            ;;
        *"Remove account"*)
            local remove_choice remove_id
            remove_choice=$(printf '%s\n' "${lines[@]}" | grep -P '^\s*\*?\s*\d+:' | gum choose --header "Remove which account?" --cursor-prefix "▸ " --unselected-prefix "  ") || return
            remove_id=$(echo "$remove_choice" | grep -oP '^\s*\*?\s*\K\d+(?=:)')
            [[ -n "$remove_id" ]] && do_remove "$remove_id"
            ;;
        *"─"*)
            ;;
        *)
            local selected_id
            selected_id=$(echo "$choice" | grep -oP '^\s*\*?\s*\K\d+(?=:)')
            [[ -n "$selected_id" ]] && do_switch "$selected_id"
            ;;
    esac
}

# Login flow — setup or refresh credentials for an account
do_login() {
    local id="$1"
    local cred_file="$DATA_DIR/account${id}.credentials.json"

    [[ -f "$cred_file" ]] || echo '{}' > "$cred_file"

    rm -f "$CRED_LINK"
    ln -s "$cred_file" "$CRED_LINK"

    echo -e "${CYAN}Launching Claude login for account $id…${RESET}"
    echo -e "${DIM}Complete the OAuth flow in your browser.${RESET}"

    # Tokens write through the symlink into the account file
    claude login

    touch_account "$id"
    sync_metadata "$id"
    echo -e "${GREEN}Account $id credentials updated.${RESET}"
}

# Add a new account
do_add() {
    local max_id=0
    for id in $(get_account_ids); do
        (( id > max_id )) && max_id=$id
    done
    local new_id=$(( max_id + 1 ))

    local name username description
    name=$(gum input --placeholder "Identifier (e.g. Work, Personal)" --header "New Account #$new_id")
    username=$(gum input --placeholder "Username/email (optional)" --header "Username")
    description=$(gum input --placeholder "Description (optional)" --header "Description")

    [[ -z "$name" ]] && name="Account $new_id"

    local tmp
    tmp=$(jq --arg id "$new_id" --arg name "$name" --arg user "$username" --arg desc "$description" \
        '.[$id] = {"identifier": $name, "username": $user, "description": $desc, "lastUsed": ""}' "$ACCOUNTS_FILE")
    echo "$tmp" > "$ACCOUNTS_FILE"

    echo -e "${GREEN}Created account $new_id ($name)${RESET}"
    do_login "$new_id"
}

# Edit account metadata
do_edit() {
    local id="$1"
    [[ $(jq --arg id "$id" 'has($id)' "$ACCOUNTS_FILE") == "true" ]] || die "Account $id not found"

    local name username description
    name=$(gum input --value "$(get_meta "$id" "identifier")" --header "Identifier for account $id")
    username=$(gum input --value "$(get_meta "$id" "username")" --header "Username")
    description=$(gum input --value "$(get_meta "$id" "description")" --header "Description")

    local tmp
    tmp=$(jq --arg id "$id" --arg name "$name" --arg user "$username" --arg desc "$description" \
        '.[$id].identifier = $name | .[$id].username = $user | .[$id].description = $desc' "$ACCOUNTS_FILE")
    echo "$tmp" > "$ACCOUNTS_FILE"

    echo -e "${GREEN}Updated account $id${RESET}"
}

# Remove an account
do_remove() {
    local id="$1"
    [[ $(jq --arg id "$id" 'has($id)' "$ACCOUNTS_FILE") == "true" ]] || die "Account $id not found"

    local active
    active=$(get_active)
    [[ "$id" == "$active" ]] && die "Account $id is currently active — switch to another account first."

    local name
    name=$(get_meta "$id" "identifier")

    gum confirm "Remove account $id ($name)?" || { echo "Aborted."; return; }

    local cred_file="$DATA_DIR/account${id}.credentials.json"
    [[ -f "$cred_file" ]] && rm -f "$cred_file"

    local tmp
    tmp=$(jq --arg id "$id" 'del(.[$id])' "$ACCOUNTS_FILE")
    echo "$tmp" > "$ACCOUNTS_FILE"

    echo -e "${GREEN}Removed account $id ($name)${RESET}"
}

# Import current active session as a new account
do_import() {
    local src="$CRED_LINK"
    [[ -f "$src" ]] || die "No credentials found at $src — are you logged in?"

    local max_id=0
    for id in $(get_account_ids); do
        (( id > max_id )) && max_id=$id
    done
    local new_id=$(( max_id + 1 ))

    local name
    name=$(gum input --placeholder "Identifier (e.g. Work, Personal)" --header "Import current session as Account #$new_id")
    [[ -z "$name" ]] && name="Account $new_id"

    local cred_file="$DATA_DIR/account${new_id}.credentials.json"
    cp "$src" "$cred_file"

    local tmp
    tmp=$(jq --arg id "$new_id" --arg name "$name" \
        '.[$id] = {"identifier": $name, "username": "", "description": "", "lastUsed": ""}' "$ACCOUNTS_FILE")
    echo "$tmp" > "$ACCOUNTS_FILE"

    rm -f "$CRED_LINK"
    ln -s "$cred_file" "$CRED_LINK"

    touch_account "$new_id"
    sync_metadata "$new_id"

    name=$(get_meta "$new_id" "identifier")
    echo -e "${GREEN}Imported current session as account $new_id ($name)${RESET}"
}

# --- Main ---

case "${1:-}" in
    "")
        do_menu
        ;;
    status)
        do_status
        ;;
    info|sync)
        do_sync_info
        ;;
    login)
        [[ -z "${2:-}" ]] && die "Usage: claude-switch login <account-number>"
        do_login "$2"
        ;;
    add)
        do_add
        ;;
    import)
        do_import
        ;;
    edit)
        [[ -z "${2:-}" ]] && die "Usage: claude-switch edit <account-number>"
        do_edit "$2"
        ;;
    remove)
        [[ -z "${2:-}" ]] && die "Usage: claude-switch remove <account-number>"
        do_remove "$2"
        ;;
    help|-h|--help)
        echo -e "${BOLD}claude-switch${RESET} — Claude account manager"
        echo ""
        echo "  claude-switch              Interactive account menu"
        echo "  claude-switch <N>          Switch to account N"
        echo "  claude-switch status       Show all accounts and active"
        echo "  claude-switch info/sync    Fetch and display active account info"
        echo "  claude-switch login <N>    Login/refresh account N credentials"
        echo "  claude-switch import       Import current logged-in session as an account"
        echo "  claude-switch add          Add a new account"
        echo "  claude-switch edit <N>     Edit account N metadata"
        echo "  claude-switch remove <N>   Remove account N (cannot be active)"
        echo "  claude-switch help         Show this help"
        ;;
    [0-9]*)
        do_switch "$1"
        ;;
    *)
        die "Unknown command: $1. Run 'claude-switch help' for usage."
        ;;
esac
