# claude-switch

Manage multiple Claude Code accounts on one machine by swapping the live credentials file in and out of a per-account store.

Claude Code reads auth from `~/.claude/.credentials.json`. `claude-switch` keeps a parked copy of each account's credentials under `~/.claude-switch/` and copies the right one into place when you switch. Before every swap it copies the live file back to the outgoing account's slot so any OAuth token refresh that happened mid-session is preserved.

## Install

```bash
chmod +x switch.sh
ln -s "$PWD/switch.sh" ~/.local/bin/claude-switch
```

Requires `jq`, `gum`, and the [Claude Code CLI](https://claude.ai/code) (`claude` on `$PATH`):

```bash
# macOS
brew install jq gum

# Debian/Ubuntu
sudo apt install jq
go install github.com/charmbracelet/gum@latest
```

The script aborts if `jq` or `gum` is missing.

## Usage

```bash
claude-switch              # interactive menu (gum)
claude-switch <N>          # switch to account N
claude-switch status       # list accounts, mark active
```

After switching, **start a new Claude session** — a running `claude` process holds its credentials in memory and won't pick up the swap until restarted.

## Commands

| Command | Description |
|---|---|
| `claude-switch` | Interactive account menu |
| `claude-switch <N>` | Switch to account N |
| `claude-switch status` | Show all accounts and active |
| `claude-switch info` / `sync` | Fetch and display active account info |
| `claude-switch login <N>` | Login/refresh account N credentials |
| `claude-switch import` | Import current logged-in session as an account |
| `claude-switch add` | Add a new account (prompts metadata, runs login) |
| `claude-switch edit <N>` | Edit account N metadata |
| `claude-switch remove <N>` | Remove account N (cannot be active) |
| `claude-switch help` | Show help |

`info` and `sync` are aliases. The interactive menu also exposes Sync / Import / Add / Edit / Remove entries.

## Data layout

```
~/.claude-switch/
├── accounts.json                  # metadata map, keyed by numeric id
├── active                         # single line: id of currently-active account
├── account1.credentials.json      # parked copy for account 1
├── account2.credentials.json
└── ...

~/.claude/.credentials.json        # live file Claude reads (regular file, not a symlink)
```

`accounts.json`:

```json
{
  "1": {
    "identifier": "Work",
    "username": "you@company.com",
    "description": "Acme Corp · pro",
    "lastUsed": "2026-04-17T10:30:00+00:00"
  }
}
```

Metadata is auto-filled from `claude auth status` after each switch/login: `username` from email, `description` from `orgName · subscriptionType`, and `identifier` from `orgName` if still the default `Account <N>`.

## How it works

The live file is a regular file, not a symlink. On every switch:

1. Copy `~/.claude/.credentials.json` back over the outgoing account's parked copy (preserves token refreshes).
2. Copy the incoming account's parked copy over `~/.claude/.credentials.json` and `chmod 600`.
3. Write the new id to `~/.claude-switch/active` and bump `lastUsed`.
4. Run `claude auth status` to refresh metadata.

`login <N>` seeds the live file with the account's existing creds (or `{}`), points `active` at it, runs `claude login` so OAuth writes through to the live file, then copies the result back to the parked slot.

`import` copies the live `~/.claude/.credentials.json` into a new `account<N+1>.credentials.json` slot and registers it. The script refuses to import if the live file is a symlink (legacy state from older versions).

`remove` refuses to delete the active account — switch elsewhere first.

Because each account is a separate file copy, IDs are append-only: deleting account 3 and adding a new one yields account 4, not a reused 3.

## Caveats

- One Claude session at a time. Existing processes keep the old credentials until restarted.
- Credential files are plain JSON. `chmod 700 ~/.claude-switch` is recommended.
- Compatible with GNU and BSD `date` (relative-time display detects at runtime).
