# claude-switch

Manage multiple Claude Code accounts by swapping which credentials file is active.

Claude Code stores authentication in `~/.claude/.credentials.json`. `claude-switch`
keeps one credential file per account under `~/.claude-switch/` and maintains that
path as a symlink, letting you flip between accounts in one command and start a
fresh Claude session on the new identity.

## Install

```bash
chmod +x tools/switch/switch.sh
ln -s "$PWD/tools/switch/switch.sh" ~/.local/bin/claude-switch
```

Requires `jq` and `gum`:

```bash
# macOS
brew install jq gum

# Debian/Ubuntu
sudo apt install jq
go install github.com/charmbracelet/gum@latest
```

Also requires the [Claude Code CLI](https://claude.ai/code) (`claude` on `$PATH`, authenticated).

## Usage

```bash
claude-switch              # interactive account picker
claude-switch <N>          # switch to account N immediately
claude-switch status       # list all accounts and which is active
```

After switching, start a new Claude Code session — the running process keeps the
old credentials until restarted.

## Commands

| Command | Description |
|---|---|
| `claude-switch` | Interactive menu |
| `claude-switch <N>` | Switch to account N |
| `claude-switch status` | Show all accounts |
| `claude-switch info` / `sync` | Fetch live auth info and sync metadata |
| `claude-switch login <N>` | Run OAuth login flow for account N |
| `claude-switch import` | Import the current logged-in session as a new account |
| `claude-switch add` | Add a new account slot and run login |
| `claude-switch edit <N>` | Edit identifier, username, or description for account N |
| `claude-switch remove <N>` | Delete account N (cannot be the active account) |
| `claude-switch help` | Show help |

## Data Layout

```
~/.claude-switch/
├── accounts.json               # registry of all accounts
├── account1.credentials.json
├── account2.credentials.json
└── ...

~/.claude/.credentials.json     # symlink → active account file
```

`accounts.json` maps numeric string IDs to metadata:

```json
{
  "1": {
    "identifier": "Work",
    "username": "you@company.com",
    "description": "Acme Corp · pro",
    "lastUsed": "2025-04-17T10:30:00+00:00"
  }
}
```

## How It Works

1. **Switch** — updates the symlink to point at the target account's credential file,
   then calls `claude auth status` (with a spinner) to refresh stored metadata.
2. **Import** — copies the live credential file into `~/.claude-switch/account{N}.credentials.json`,
   records a metadata entry, and re-points the symlink at the copy.
3. **Login** — creates an empty credential file, points the symlink at it, then runs
   `claude login` so OAuth tokens write through the symlink into the right file.
4. **Remove** — prompts for confirmation, deletes the credential file, and removes
   the entry from `accounts.json`. Refuses if the account is currently active.

## Caveats

- **IDs never reuse.** After removing account 3 and adding a new one, the new account
  becomes account 4. This keeps historical symlink targets unambiguous.
- **One session at a time.** Only one Claude Code process should be running when you
  switch. Existing sessions keep the old credentials until restarted.
- **No encryption.** Credential files are plain JSON. Apply appropriate permissions:
  `chmod 700 ~/.claude-switch`.
- **macOS compatible.** `relative_time` detects GNU vs BSD `date` at runtime.

## Requirements

- bash 4+
- [jq](https://jqlang.org)
- [gum](https://github.com/charmbracelet/gum)
- [Claude Code CLI](https://claude.ai/code)
