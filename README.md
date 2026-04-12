# CCS - Claude Code Switch

> Quick switch between multiple AI provider profiles for Claude Code.

CCS is a lightweight CLI tool (bash script) that lets you instantly switch Claude Code's `settings.json` between different AI providers — Anthropic, Kimi, DeepSeek, Google Gemini, and more. Fully local, no server required.

## Features

- **Instant profile switching** — one command to swap provider, API key, and models
- **Multi-provider support** — Anthropic, Kimi, DeepSeek, Gemini, or any OpenAI-compatible API
- **Safe** — auto-backup `settings.json` before every switch (keeps last 10)
- **Cross-platform** — Linux, macOS, WSL
- **Tab completion** — Bash and Zsh
- **Self-update** — `ccs update` to pull the latest version
- **Zero dependencies** beyond `jq` and `curl`

## Installation

### One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/buivankim2020/claude-code-switch/main/install.sh | bash
```

### What the installer does

1. Checks for required dependencies (`jq`, `curl`)
2. Creates `~/.ccs/` directory
3. Downloads `ccs.sh`, `provider.conf.example`, and shell completions
4. Creates a symlink at `/usr/local/bin/ccs` (or `~/.local/bin/ccs` if no sudo)
5. Sets up tab completion for your shell

### Manual install

```bash
git clone https://github.com/buivankim2020/claude-code-switch.git
cd claude-code-switch
bash install.sh
```

### Dependencies

| Dependency | Purpose              | Install                          |
|------------|----------------------|----------------------------------|
| `jq`       | JSON manipulation    | `sudo apt install jq` / `brew install jq` |
| `curl`     | HTTP requests        | `sudo apt install curl` / `brew install curl` |

## Quick Start

```bash
# 1. Run ccs for the first time — it will guide you to add your first profile
ccs

# 2. Add more profiles
ccs add kimi
ccs add deepseek

# 3. Switch to a profile
ccs opus

# 4. Verify
ccs current
```

## Usage

### Switch profile

```bash
ccs <profile_name>
```

```bash
ccs opus        # Switch to Anthropic Opus
ccs kimi        # Switch to Kimi AI
ccs deepseek    # Switch to DeepSeek
ccs gemini      # Switch to Google Gemini
```

### Commands

| Command              | Description                                      |
|----------------------|--------------------------------------------------|
| `ccs list`           | List all available profiles                      |
| `ccs current`        | Show the currently active profile                |
| `ccs edit`           | Open `provider.conf` in your editor (`$EDITOR`)  |
| `ccs add <name>`     | Add a new profile interactively                  |
| `ccs remove <name>`  | Remove a profile from `provider.conf`            |
| `ccs test [name]`    | Test API key/endpoint (default: test all)        |
| `ccs backup`         | Backup current `settings.json`                   |
| `ccs restore`        | Restore from the most recent backup              |
| `ccs update`         | Self-update CCS to the latest version            |
| `ccs uninstall`      | Uninstall CCS completely                         |
| `ccs version`        | Show version                                     |
| `ccs help`           | Show help                                        |

### Options

| Flag           | Description             |
|----------------|-------------------------|
| `-y, --yes`    | Skip confirmation prompts |
| `--no-color`   | Disable colored output  |

## Configuration

### Directory structure

```
~/.ccs/
├── ccs.sh                  # Main script (symlinked to /usr/local/bin/ccs)
├── provider.conf           # Your profiles (chmod 600, contains API keys)
├── provider.conf.example   # Template for reference
├── config.env              # CCS state (active profile, version)
├── ccs-completion.bash     # Bash tab completion
├── ccs-completion.zsh      # Zsh tab completion
├── .update_check           # Auto-update check cache
└── backups/                # settings.json backups
    └── settings.backup.{timestamp}.json
```

### Profile format (`provider.conf`)

Uses INI format. Each `[section]` is a profile name:

```ini
[opus]
ANTHROPIC_AUTH_TOKEN=sk-ant-your-key-here
ANTHROPIC_BASE_URL=https://api.anthropic.com
ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5-20251001
ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-6-20250414
ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6-20250514

[kimi]
ANTHROPIC_AUTH_TOKEN=sk-your-kimi-key
ANTHROPIC_BASE_URL=https://api.kimi.ai/v1
ANTHROPIC_DEFAULT_HAIKU_MODEL=kimi-latest
ANTHROPIC_DEFAULT_OPUS_MODEL=kimi-latest
ANTHROPIC_DEFAULT_SONNET_MODEL=kimi-latest

```

### Managed keys

CCS only modifies these 5 keys in `settings.json` — everything else is left untouched:

| Key | Description |
|-----|-------------|
| `ANTHROPIC_AUTH_TOKEN` | API key for the provider |
| `ANTHROPIC_BASE_URL` | API endpoint URL |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | Model ID for the haiku tier |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | Model ID for the opus tier |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | Model ID for the sonnet tier |

## How It Works

When you run `ccs <profile>`:

1. Reads the profile from `provider.conf`
2. Backs up current `settings.json` to `~/.ccs/backups/`
3. Cleans up old backups (keeps the 10 most recent)
4. Updates **only** the 5 managed keys in `settings.json` using `jq`
5. Saves the active profile to `config.env`
6. Prompts to reload VSCode to apply changes

## Testing Profiles

```bash
# Test all profiles (runs in parallel, 5s timeout)
ccs test

# Test a specific profile
ccs test kimi

# Custom timeout for slow networks
CCS_TEST_TIMEOUT=10 ccs test
```

Example output:

```
Testing all profiles (timeout: 5s)...
  [opus]      ✓ OK (0.8s)
  [kimi]      ✗ 401 Unauthorized
  [deepseek]  ✓ OK (1.2s)
  [gemini]    ✗ TIMEOUT (>5s)

Result: 2/4 profiles working.
```

## Platform Support

| Platform     | `settings.json` path                              |
|--------------|----------------------------------------------------|
| Linux        | `~/.claude/settings.json`                          |
| macOS        | `~/.claude/settings.json`                          |
| WSL (native) | `~/.claude/settings.json`                          |
| WSL (Windows)| `/mnt/c/Users/<WinUser>/.claude/settings.json`     |

CCS auto-detects the platform and resolves the correct path. You can also override it:

```bash
export CCS_SETTINGS_PATH="/custom/path/to/settings.json"
```

## Security

- `provider.conf` is set to `chmod 600` (owner read/write only)
- **Never** commit `provider.conf` to git — it contains API keys
- The repo only includes `provider.conf.example` with placeholder values
- If a key is leaked, rotate it at the provider and update `provider.conf`

## Uninstall

```bash
# Via the CLI
ccs uninstall

# Or via the install script
bash install.sh --uninstall
```

This removes `~/.ccs/`, the `ccs` symlink, and shell completion entries.

## License

MIT
