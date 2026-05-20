# CCS - Claude Code Switch

> Quick switch between multiple AI provider profiles for Claude Code.

CCS is a lightweight CLI tool (bash script) that lets you instantly switch Claude Code's `settings.json` between different AI providers — Anthropic, Kimi, DeepSeek, Google Gemini, Microsoft Azure Foundry, and more. Fully local, no server required.

## Features

- **Instant profile switching** — one command to swap provider, API key, and models
- **Project-level profiles** — assign different providers per project via `-p` / `--project` flag (optional, defaults to global)
- **Multi-provider support** — Anthropic, Kimi, DeepSeek, Gemini, Azure Foundry, or any OpenAI-compatible API
- **Safe** — auto-backup `settings.json` before every switch (keeps last 10); only CCS-managed keys are touched, everything else (theme, hooks, permissions, custom env vars) is left untouched
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
ccs <profile_name>       # Global scope (default)
ccs -p <profile_name>    # Project scope (current project)
```

```bash
ccs opus        # Switch global profile to Anthropic Opus
ccs kimi        # Switch global profile to Kimi AI
ccs deepseek    # Switch global profile to DeepSeek
ccs -p foundry  # Switch current project to Azure Foundry
```

### Scope: Global vs Project

CCS supports two scopes:

| Scope   | Flag         | Settings file                                  | Default |
|---------|--------------|------------------------------------------------|---------|
| global  | _(none)_     | `~/.claude/settings.json`                      | yes     |
| project | `-p, --project` | `<project_root>/.claude/settings.local.json` | —       |

- **Global** — applies to all Claude Code sessions regardless of working directory
- **Project** — overrides global settings for a specific project; useful when different repos need different providers or API keys
- Project scope auto-detects the project root by looking for `.git/` or `.claude/` directory
- The `-p` flag works with: `<profile>`, `list`, `current`, `status`, `reload`, `backup`, `restore`, `clear`
- Use `ccs -p clear` to remove project-level config and fall back to the global profile

```bash
# Set a project-specific provider
cd ~/work-repo
ccs -p foundry    # Work repo uses corporate Foundry

cd ~/side-project
ccs -p opus       # Side project uses personal Anthropic key

# Check which profile is active per scope
ccs current       # → global active profile
ccs -p current    # → project active profile
```

### Commands

| Command              | Description                                      |
|----------------------|--------------------------------------------------|
| `ccs list`           | List all available profiles                      |
| `ccs current`        | Show the currently active profile                |
| `ccs status`         | Full status overview (profile + paths + platform) |
| `ccs reload`         | Re-apply the active profile after editing its config |
| `ccs clear`          | Remove project provider config, fall back to global (requires `-p`) |
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

| Flag              | Description                              |
|-------------------|------------------------------------------|
| `-p, --project`   | Apply to project-level settings          |
| `-y, --yes`       | Skip confirmation prompts                |
| `--no-color`      | Disable colored output                   |

## Configuration

### Directory structure

```
~/.ccs/
├── ccs.sh                  # Main script (symlinked to /usr/local/bin/ccs)
├── provider.conf           # Your profiles (chmod 600, contains API keys)
├── provider.conf.example   # Template for reference
├── config.env              # CCS state (global active profile)
├── projects/               # Per-project state files
│   └── <md5_hash>.env      # Active profile for a specific project
├── ccs-completion.bash     # Bash tab completion
├── ccs-completion.zsh      # Zsh tab completion
├── .update_check           # Auto-update check cache
└── backups/                # settings.json backups
    └── settings.backup.{timestamp}.json
```

### Profile format (`provider.conf`)

Uses INI format. Each `[section]` is a profile name. The optional `PROVIDER_TYPE` key selects the shape of the profile (`anthropic` by default, or `foundry` for Microsoft Azure Foundry).

#### Type: `anthropic` (default — Anthropic API, Kimi, DeepSeek, Gemini, OpenAI-compatible proxies)

```ini
[opus]
ANTHROPIC_AUTH_TOKEN=sk-ant-your-key-here
ANTHROPIC_BASE_URL=https://api.anthropic.com
ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5-20251001
ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-7
ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6-20250514

[kimi]
ANTHROPIC_AUTH_TOKEN=sk-your-kimi-key
ANTHROPIC_BASE_URL=https://api.kimi.ai/v1
ANTHROPIC_DEFAULT_HAIKU_MODEL=kimi-latest
ANTHROPIC_DEFAULT_OPUS_MODEL=kimi-latest
ANTHROPIC_DEFAULT_SONNET_MODEL=kimi-latest
```

#### Type: `foundry` (Microsoft Azure Foundry)

```ini
[foundry]
PROVIDER_TYPE=foundry
ANTHROPIC_FOUNDRY_RESOURCE=your-foundry-resource
ANTHROPIC_FOUNDRY_API_KEY=your-foundry-project-api-key
ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5
ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-6
ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6
```

`ANTHROPIC_FOUNDRY_RESOURCE` is the Azure resource name; CCS derives the endpoint
`https://<resource>.services.ai.azure.com/anthropic`. If you need a custom host, use
`ANTHROPIC_FOUNDRY_BASE_URL=<full-url>` instead (the two are mutually exclusive).
Model names must match the deployment names you created in the Foundry portal.

See [Azure Foundry setup](#azure-foundry-setup) for a walkthrough.

### Managed keys

CCS only modifies the provider-specific keys in `settings.json`'s `env` block —
**everything else** (theme, model, permissions, hooks, statusLine, custom env vars
like `HTTP_PROXY`, etc.) is left untouched. Switching between `anthropic` and
`foundry` profiles automatically clears the keys of the other type so there is no
stale configuration.

| Type       | Keys written                                                                                                     | Keys cleared on switch                    |
|------------|------------------------------------------------------------------------------------------------------------------|-------------------------------------------|
| anthropic  | `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_DEFAULT_{HAIKU,OPUS,SONNET}_MODEL`                       | `CLAUDE_CODE_USE_FOUNDRY`, `ANTHROPIC_FOUNDRY_*` |
| foundry    | `CLAUDE_CODE_USE_FOUNDRY=1`, `ANTHROPIC_FOUNDRY_{RESOURCE\|BASE_URL}`, `ANTHROPIC_FOUNDRY_API_KEY`, 3 model keys | `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL` |

## How It Works

When you run `ccs <profile>`:

1. Reads the profile from `provider.conf` and determines its `PROVIDER_TYPE`
2. Backs up the current settings file to `~/.ccs/backups/`
3. Cleans up old backups (keeps the 10 most recent)
4. Updates **only** the managed keys in the settings file using `jq`, clearing any stale keys left over from a different provider type
5. Saves the active profile to the state file (`config.env` for global, `projects/<hash>.env` for project)
6. Prompts to reload VSCode to apply changes

With `ccs -p <profile>` (project scope):

1. Detects the project root by walking up from `$PWD` looking for `.git/` or `.claude/`
2. Targets `<project_root>/.claude/settings.local.json` instead of the global file
3. Tracks the active profile independently per project in `~/.ccs/projects/<md5_hash>.env`
4. Preserves existing project-level settings (permissions, hooks, etc.) — only the `.env` block is modified

## Azure Foundry setup

Microsoft Azure Foundry hosts Claude models on Azure infrastructure with enterprise
security and private networking. Claude Code supports Foundry natively via a
different set of environment variables than the direct Anthropic API.

### Prerequisites

1. Azure subscription with access to [Microsoft Foundry](https://ai.azure.com/).
2. A Foundry project in a [supported region](https://aka.ms/supported_anthropic_regions) (East US 2 or Sweden Central at the time of writing).
3. Deployments for the Claude models you want Claude Code to use — typically `claude-sonnet-4-6`, `claude-haiku-4-5`, and `claude-opus-4-6`. The deployment names are what you put in `ANTHROPIC_DEFAULT_*_MODEL`.
4. A **Project API key** — copy it from the Foundry portal home page (**Project API key** field), or from a deployment's **Details** tab.

### Add a Foundry profile

Interactive:

```bash
ccs add foundry
# Select type: 2 (foundry)
# ANTHROPIC_FOUNDRY_RESOURCE: your-foundry-resource
# ANTHROPIC_FOUNDRY_API_KEY:  <paste project key>
# (model names default to claude-*-4-*)
```

Or paste into `ccs edit`:

```ini
[foundry]
PROVIDER_TYPE=foundry
ANTHROPIC_FOUNDRY_RESOURCE=my-foundry
ANTHROPIC_FOUNDRY_API_KEY=xxxxxxxxxxxxxxxx
ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5
ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-6
ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6
```

Then:

```bash
ccs foundry
ccs test foundry    # verify endpoint + API key
```

CCS writes `CLAUDE_CODE_USE_FOUNDRY=1` and the Foundry env vars into
`settings.json`. Reload your VSCode window to pick them up. Once active,
Claude Code's `/status` should report `API provider: Microsoft Foundry`.

### Notes

- CCS currently only supports **API key** authentication in Foundry profiles. If you prefer Microsoft Entra ID (`az login`), remove `ANTHROPIC_FOUNDRY_API_KEY` from the profile *after* switching and rely on Claude Code's built-in Azure CLI fallback. Note that `ccs test` skips the probe when no key is present.
- The Foundry anthropic-compat endpoint path `/anthropic` is appended automatically when you use `ANTHROPIC_FOUNDRY_RESOURCE`. Use `ANTHROPIC_FOUNDRY_BASE_URL` for the full URL only if you have a non-standard host.
- Official references: [Microsoft Foundry docs](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/configure-claude-code) · [Claude Code docs](https://code.claude.com/docs/en/microsoft-foundry).

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
Testing all profiles (timeout: 5s, parallel)...
  [opus]      ✓ OK   820ms   api.anthropic.com                   (anthropic)
  [kimi]      ✗ HTTP 401   450ms   api.kimi.ai
  [deepseek]  ✓ OK   1200ms  api.deepseek.com                     (openai)
  [foundry]   ✓ OK   950ms   my-foundry.services.ai.azure.com    (foundry)
```

## Platform Support

| Platform     | Global settings path                              | Project settings path                       |
|--------------|----------------------------------------------------|---------------------------------------------|
| Linux        | `~/.claude/settings.json`                          | `<project>/.claude/settings.local.json`     |
| macOS        | `~/.claude/settings.json`                          | `<project>/.claude/settings.local.json`     |
| WSL (native) | `~/.claude/settings.json`                          | `<project>/.claude/settings.local.json`     |
| WSL (Windows)| `/mnt/c/Users/<WinUser>/.claude/settings.json`     | `<project>/.claude/settings.local.json`     |

CCS auto-detects the platform and resolves the correct path for global settings. Project settings always use `.claude/settings.local.json` within the project root. You can also override the settings path:

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
