# serena-bootstrap

A Bash script to install, configure, validate, and maintain [Serena](https://github.com/oraios/serena) for a project, including MCP client registration and optional agent hooks.

## Quick start

Requires Bash 4+, Python 3.11+ on `PATH`, and an existing project directory. Keep `serena.sh` and its companion `bootstrap_config.py` together; symlinks to the script are supported. Serena is installed through [uv](https://docs.astral.sh/uv/) using Python 3.13. If uv is missing, the script offers to install it (requires `curl`). Install the CLI for each agent client you select. The default agent skill installation also requires Node.js and `npx`; use `--no-skill` to skip it.

```bash
git clone https://github.com/rigerc/serena-bootstrap.git
cd serena-bootstrap

# Preview setup for your project.
./serena.sh --dry-run /path/to/project

# Set up Serena for Claude Code (the default client).
./serena.sh /path/to/project
```

Restart your agent client afterward and check its Serena MCP connection. Ask the agent to activate the project and complete Serena onboarding.

## What it does

- Installs `serena-agent` with uv and initializes Serena configuration.
- Detects source languages and creates project configuration, with optional ignore patterns and workspace folders.
- Indexes the project and runs a health check by default.
- Registers Serena for Claude Code, Codex, Grok, CodeBuddy, OpenCode, or Pi; repeat `--client` to select multiple clients.
- Optionally installs project hooks and prefetches language server dependencies.
- Installs the `serena-usage` agent skill from [rigerc/skills](https://github.com/rigerc/skills) for selected clients by default.
- Keeps the web dashboard enabled without automatically opening a browser tab.

Existing installations and configuration are reused where possible. Global settings live in `${SERENA_HOME:-$HOME/.serena}/serena_config.yml`; project settings live in `.serena/project.yml`.

## Usage

```bash
./serena.sh [options] [project_dir]
./serena.sh --help
```

The project directory defaults to the current directory.

```bash
# Configure multiple clients and project hooks.
./serena.sh --client claude-code --client codex --hooks /path/to/project

# Register Claude Code's MCP server at project scope.
./serena.sh --per-project /path/to/project

# Prefetch language server dependencies and check existing memory references.
./serena.sh --profile advanced /path/to/project

# Add detected language servers to an existing configuration.
./serena.sh --sync-languages /path/to/project

# Select languages explicitly.
./serena.sh --no-detect --language python /path/to/project

# Limit a monorepo's indexing scope and exclude generated files.
./serena.sh --workspace services/api --workspace packages/shared \
  --ignore '**/generated/**' /path/to/project

# Configure Serena without registering an agent client.
./serena.sh --client none /path/to/project
```

### Profiles

- `minimal`: skips indexing and health checks.
- `standard` (default): enables indexing and health checks.
- `advanced`: adds language server dependency prefetch and memory reference checks.

Explicit flags such as `--no-index` and `--no-health-check` override profile defaults regardless of argument order. Existing projects normally skip indexing unless `--reindex`, `--upgrade`, `--sync-languages`, or a scope change requires it.

## Saved defaults and presets

Configuration is loaded in this order, with later layers taking precedence:

1. Built-in bootstrap defaults.
2. User defaults: `${XDG_CONFIG_HOME:-$HOME/.config}/serena-bootstrap/config.toml`.
3. Project overrides: `<project>/.serena/bootstrap.toml`.
4. Additional files supplied with repeatable `--config PATH`.
5. The named `--preset`.
6. Explicit CLI options.

`--no-config` skips automatic user/project files but still loads explicit `--config` files. TOML tables merge recursively; arrays from higher layers replace arrays from lower layers. An empty array is an explicit empty value. Files are parsed as data, never sourced as shell scripts. Unknown keys and incorrect types are rejected.

Save the following as your user configuration, or use it as a project-specific starting point:

```toml
[bootstrap]
clients = ["claude-code", "codex"]
profile = "standard"
hooks = true
skill = true
skill_global = false
per_project = false
index = true
health_check = true
prepare_lsp = false
check_memories = false
detect = true
sync_languages = false
min_files = 3
max_languages = 5
languages = []
ignore = ["**/generated/**"]
workspace = []
# name = "my-project"
# auto_approve = false

[project]
default_modes = ["interactive", "editing"]
added_modes = []
agent_interface = "tools"
read_only = false
excluded_tools = []
included_optional_tools = []
included_apis = []
excluded_apis = []
read_only_memory_patterns = ["global/.*"]
ignored_memory_patterns = []
# language_backend = "LSP"
# initial_prompt = "Read the coding conventions before editing."
# initial_prompt_file = "prompts/project.txt"

# Nested language-server overrides merge with existing settings.
# [project.ls_specific_settings.python]
# request_timeout = 90

[startup]
web_dashboard = true
web_dashboard_open_on_launch = false
# context = "ide"                  # Otherwise use each client's usual context.
# modes = ["planning"]             # Replace default modes for the server.
# add_modes = ["query-projects"]    # Add modes at startup.
# tool_timeout = 300
# log_level = "INFO"
# gui_log_window = false
# trace_lsp_communication = false

# Global settings are opt-in and affect all Serena projects.
# [global]
# base_modes = ["no-onboarding"]
# default_modes = ["interactive", "editing"]
# tool_timeout = 300
# log_level = "INFO"               # Written as Serena's numeric log level.

[presets.review.project]
default_modes = ["planning", "one-shot"]
read_only = true

[presets.review.bootstrap]
profile = "minimal"
index = false
health_check = false
```

Only settings explicitly present in `[project]` or `[global]` are written to Serena's YAML configuration. Existing unrelated settings and comments are preserved; nested maps merge, persistent arrays replace, and changed files receive backups before atomic replacement. Bootstrap `ignore` remains additive to existing `ignored_paths`; `workspace` replaces indexing folders when supplied. Use `[project].ignored_paths` or `--set` to replace ignore rules exactly.

A user defaults file can contain `[project]` settings: these are applied to each project you bootstrap, without modifying global Serena preferences. `--scope project|global` selects the destination of persistent **CLI** settings; it does not change the meaning of TOML sections. The default scope is `project`. MCP registration scope is independent: `--per-project` selects Claude Code's project registration.

```bash
# Inspect requested settings and their sources without installing or writing.
./serena.sh --show-config /path/to/project

# Preview YAML changes and client registration commands.
./serena.sh --preset review --dry-run /path/to/project

# Override a saved preset for this setup.
./serena.sh --preset review --read-write --default-mode editing /path/to/project

# Apply an additional defaults file.
./serena.sh --config ./team-defaults.toml /path/to/project
```

Profiles supply defaults for indexing, health checks, prefetch, and memory checks. Explicit TOML or CLI booleans win over profile defaults, including `false`. For example, a preset changing only `profile` will retain an explicitly configured `index`; include `index = false` in the preset to override it. Use `clients = []` or `--client none` to select no clients.

## Serena modes and extended settings

Bootstrap profiles control setup work. Serena modes control agent behavior. They are independent.

- Global `base_modes` are always active.
- Global `default_modes` can be replaced by project `default_modes` or startup `--mode`.
- Project `added_modes` and startup `--startup-add-mode` add modes on top.

Multiple modes can be selected. Choose compatible combinations; Serena does not prohibit combinations such as `interactive` and `one-shot`. See the [upstream configuration guide](https://oraios.github.io/serena/02-usage/050_configuration.html#modes).

```bash
# Persist replaceable project defaults and added modes.
./serena.sh --default-mode interactive --default-mode editing \
  --add-mode query-projects /path/to/project

# Set modes which are always included globally.
./serena.sh --scope global --base-mode no-onboarding /path/to/project

# Register server startup overrides for the selected clients.
./serena.sh --mode planning --startup-add-mode one-shot \
  --context ide --tool-timeout 300 --log-level DEBUG /path/to/project

# Inspect installed modes and contexts.
./serena.sh --list-modes
./serena.sh --list-contexts

# Configure tool access or REPL APIs at the selected scope.
./serena.sh --exclude-tool execute_shell_command /path/to/project
./serena.sh --interface repl --exclude-api shell /path/to/project

# Explicitly clear defaults, then restore inheritance on a later run.
./serena.sh --clear default_modes /path/to/project
./serena.sh --inherit default_modes /path/to/project

# Set typed persistent settings. JSON strings require inner quotes.
./serena.sh --scope global --set 'tool_timeout=300' /path/to/project
./serena.sh --set 'ignored_paths=["generated/**"]' /path/to/project
./serena.sh --initial-prompt-file ./prompts/project.txt /path/to/project
```

`--default-mode`, `--add-mode`, `--base-mode`, and tool/API flags are repeatable and replace the selected list with the specified values. `--clear KEY` writes an empty list; `--inherit KEY` restores the native project default: `null` for inheritable fields such as modes and interface, or the template default for other settings. Keys are retained because Serena rewrites incomplete project files. In TOML, use `[project]` with `inherit = ["default_modes", "agent_interface"]`. A setting cannot be both set and inherited in the same layer.

Use registered mode/context names for persistent settings. Startup `--mode`, `--startup-add-mode`, and `--context` also accept custom YAML paths. An empty startup `modes` array removes a startup override and leaves persistent mode selection in effect; use an empty project `default_modes` array to explicitly clear replaceable defaults. Paths in configuration files, including `initial_prompt_file`, resolve relative to that file; paths supplied on the CLI resolve relative to the current directory. Installed Serena templates and available startup flags are checked before configuration writes. Global `added_modes` and global `read_only` are not supported.

Startup arguments are saved in the selected clients' MCP registrations. For user-level registrations (Claude Code by default, Codex, Grok, and CodeBuddy), those arguments apply across projects until changed. Use persistent project defaults for behavior which should follow one project, or use Claude Code's `--per-project` registration. OpenCode and Pi registrations are project-local. Existing `.serena/project.local.yml` settings retain Serena's normal precedence over `project.yml`. Restart the client after changing its registration.

The dashboard defaults are now passed as server arguments, so ordinary setup no longer overwrites global dashboard preferences. Persist a global preference with `[global]` or `--scope global --set 'web_dashboard=false'`; runtime `[startup]` preferences take precedence for the registered server. `--dry-run` never installs tools, edits configuration, or registers clients. Without an installed Serena it shows intended changes; installed-version checks and YAML diffs require Serena's Python environment and its `ruamel.yaml` dependency.

### Additional options

- `--skill-global`: install the agent skill in user-level agent directories.
- `--no-skill`: skip agent skill installation.
- `--jetbrains`: use the JetBrains backend and skip LSP indexing and prefetch.
- `--interface tools|repl`: choose the project agent interface.
- `--read-only`: set Serena's project read-only flag. This is not a security sandbox; the REPL can execute arbitrary Python.
- `--open-dashboard`: opt into opening the dashboard automatically.
- `--no-dashboard`: disable the dashboard.
- `--auto-approve`: opt into Claude Code or CodeBuddy auto-approve hooks.
- `--yes`: approve optional uv installation without prompting.

Run `./serena.sh --help` for the complete option list.

## Maintenance

```bash
# Inspect installed tools, configuration, and project health.
./serena.sh --doctor /path/to/project

# Upgrade Serena, reinstall the selected agent skill, and reindex.
./serena.sh --upgrade /path/to/project

# Force indexing without upgrading.
./serena.sh --reindex /path/to/project

# Remove wiring for the selected clients, preserving project memories.
./serena.sh --uninstall --client claude-code --client codex /path/to/project
```

With `--uninstall`, `--purge` also deletes the project's `.serena` directory, including memories. `--remove-tool` also uninstalls the global `serena-agent` uv tool, affecting all projects.

## Development and support

Check shell syntax, lint, and the configuration tests before submitting a change:

```bash
bash -n serena.sh
shellcheck serena.sh
./serena.sh --help
# Run tests in Serena's uv tool environment (Python 3.11+, ruamel.yaml).
"$(uv tool dir)/serena-agent/bin/python" -m unittest discover -s tests -v
```

Report bootstrap issues through [GitHub Issues](https://github.com/rigerc/serena-bootstrap/issues). For Serena itself, see the [upstream documentation](https://oraios.github.io/serena/).
