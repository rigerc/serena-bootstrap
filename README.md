# serena-bootstrap

A Bash script to install, configure, validate, and maintain [Serena](https://github.com/oraios/serena) for a project, including MCP client registration and optional agent hooks.

## Quick start

Requires Bash 4+ and an existing project directory. Serena is installed through [uv](https://docs.astral.sh/uv/) using Python 3.13. If uv is missing, the script offers to install it (requires `curl`). Install the CLI for each agent client you select. The default agent skill installation also requires Node.js and `npx`; use `--no-skill` to skip it.

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

Check shell syntax and the help output before submitting a change:

```bash
bash -n serena.sh
./serena.sh --help
```

Report bootstrap issues through [GitHub Issues](https://github.com/rigerc/serena-bootstrap/issues). For Serena itself, see the [upstream documentation](https://oraios.github.io/serena/).
