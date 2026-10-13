#!/usr/bin/env bash
# setup-serena.sh — install, configure, validate and maintain Serena for a project.
# https://github.com/oraios/serena
set -euo pipefail

SERENA_PKG="serena-agent"
SERENA_BIN="serena"
SERENA_SKILL_REPO="https://github.com/rigerc/skills"
SERENA_SKILL_NAME="serena-usage"
PYTHON_VERSION="3.13"
PROJECT_DIR="."
PROJECT_NAME=""
PROJECT_ARG_SET=0
LANGUAGES=()
RESOLVED_LANGS=()
IGNORE_PATTERNS=()
WORKSPACE_FOLDERS=()
CLIENTS=("claude-code")
CLIENTS_SET=0
PROFILE="standard"
DO_INDEX=1; INDEX_SET=0
DO_HEALTH=1; HEALTH_SET=0
DO_PREPARE=0; PREPARE_SET=0
DO_MEMORY_CHECK=0; MEMORY_SET=0
DO_HOOKS=0; HOOKS_SET=0
DO_SKILL=1
SKILL_GLOBAL=0
AUTO_APPROVE=0
PER_PROJECT=0
JETBRAINS=0
EFFECTIVE_JETBRAINS=0
DETECT=1
SYNC_LANGUAGES=0
MIN_FILES=3
MAX_LANGUAGES=5
UPGRADE=0
ASSUME_YES=0
DRY_RUN=0
DOCTOR_ONLY=0
UNINSTALL=0
PURGE=0
REMOVE_TOOL=0
REINDEX=0
PROJECT_CREATED=0
SCOPE_CHANGED=0
READ_ONLY=0
READ_ONLY_SET=0
AGENT_INTERFACE=""
DASHBOARD_OPEN=false  # Dashboard stays available; browser/tab will NOT auto-open.
DASHBOARD_ENABLED=true
CONFIG_PYTHON=""
FAILED=()

if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'; C_YEL=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_OFF=$'\033[0m'
else
  C_BLUE=""; C_YEL=""; C_RED=""; C_GRN=""; C_OFF=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()   { printf '%s ✓%s  %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s !%s  %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
run()  { if (( DRY_RUN )); then printf '    [dry-run]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }
confirm() {
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || return 1
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

usage() {
  cat <<EOF
Usage: ${0##*/} [options] [project_dir]

Idempotently configure Serena for a project. Default client: claude-code.
The web dashboard remains enabled, but never automatically opens by default.

  -c, --client NAME       Repeatable: claude-code, codex, grok, codebuddy,
                          opencode, pi, none
  -l, --language LANG     Repeatable language-server identifiers
      --no-detect         Don't auto-detect languages
      --sync-languages    Add missing LSPs to existing language_servers config
      --min-files N       Minimum source files per detected language ($MIN_FILES)
      --max-languages N   Max detected languages ($MAX_LANGUAGES)
  -n, --name NAME         Project name for initial creation
      --ignore PATTERN    Add a project ignored_paths glob (repeatable)
      --workspace PATH    Limit indexed monorepo folders (repeatable, replaces ".");
                          folders must not match ignore rules
      --interface NAME    tools or repl (project-level agent interface)
      --read-only         Set project read_only: true (not a security sandbox)
      --profile NAME      minimal, standard (default), or advanced
      --prepare-lsp      Prefetch managed dependencies of detected/selected LSPs
      --no-prepare-lsp   Do not prefetch LSP dependencies
      --health-check      Run Serena health-check after setup (default)
      --no-health-check   Skip the health check
      --check-memories    Check memory references (if memories exist)
      --no-index         Skip indexing
      --reindex          Run indexing for existing projects (fresh projects index on create)
      --per-project      Claude Code: register an MCP server scoped to the project
      --hooks            Install/update project-local Serena hooks for supported clients
      --auto-approve     Add Claude Code / CodeBuddy auto-approve hook (opt-in)
      --no-skill         Skip installing the Serena agent skill (default: install)
      --skill-global     Install the Serena skill to user-level agent dirs
      --jetbrains        Use JetBrains backend; skip LSP index and prefetch
      --open-dashboard   Opt IN to browser auto-open on Serena startup
      --no-dashboard     Disable dashboard entirely (instead of just auto-open)
      --upgrade          Upgrade Serena and reinstall the selected agent skill
      --doctor           Check installed tools/config/health; do not set up
      --uninstall        Remove Serena MCP/hooks/skill wiring for a project
      --purge            With --uninstall: also delete .serena (incl. memories)
      --remove-tool      With --uninstall: also uninstall the serena-agent uv
                         tool (global; affects all projects)
  -y, --yes               Confirm optional uv installation without prompting
      --dry-run           Show intended steps without writing or prompting
  -h, --help              Show this message

Profiles: minimal = no index or health check; standard = index and health check;
advanced = standard + LSP dependency prefetch + memory check. Explicit
--no-* flags override profile defaults regardless of argument order.

Examples:
  ${0##*/} . --sync-languages --hooks
  ${0##*/} --profile advanced -c claude-code -c codex --hooks .
  ${0##*/} --ignore 'generated/**' --interface repl .
  ${0##*/} --workspace services/api --workspace packages/shared .
  ${0##*/} --workspace services/api --workspace packages/shared --ignore '**/generated/**' .
  ${0##*/} --client claude-code --client codex --skill-global .
  ${0##*/} --no-skill .
  ${0##*/} --doctor .
  ${0##*/} --uninstall -c claude-code -c codex .
EOF
}

while (( $# )); do
  case "$1" in
    -c|--client)
      [[ $# -ge 2 && "$2" != -* ]] || die "$1 requires a client"
      case "$2" in claude-code|codex|grok|codebuddy|opencode|pi|none) ;; *) die "Unknown client: $2" ;; esac
      if (( ! CLIENTS_SET )); then CLIENTS=(); CLIENTS_SET=1; fi
      [[ "$2" == none ]] || CLIENTS+=("$2")
      shift 2 ;;
    -l|--language) [[ $# -ge 2 && "$2" != -* ]] || die "$1 requires a language"; LANGUAGES+=("$2"); shift 2 ;;
    -n|--name) [[ $# -ge 2 && "$2" != -* ]] || die "$1 requires a name"; PROJECT_NAME="$2"; shift 2 ;;
    --ignore) [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a pattern"; IGNORE_PATTERNS+=("$2"); shift 2 ;;
    --workspace) [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a path"; WORKSPACE_FOLDERS+=("$2"); shift 2 ;;
    --interface)
      [[ $# -ge 2 ]] || die "$1 requires tools or repl"
      case "${2,,}" in tools) AGENT_INTERFACE=tools ;; repl) AGENT_INTERFACE=REPL ;; *) die "Unknown interface: $2" ;; esac
      shift 2 ;;
    --profile) [[ $# -ge 2 ]] || die "$1 requires a profile"; PROFILE="$2"; shift 2 ;;
    --read-only) READ_ONLY=1; READ_ONLY_SET=1; shift ;;
    --no-detect) DETECT=0; shift ;;
    --sync-languages) SYNC_LANGUAGES=1; shift ;;
    --min-files) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || die "$1 requires an integer"; MIN_FILES="$2"; shift 2 ;;
    --max-languages) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ && "$2" -gt 0 ]] || die "$1 requires a positive integer"; MAX_LANGUAGES="$2"; shift 2 ;;
    --no-index) DO_INDEX=0; INDEX_SET=1; shift ;;
    --reindex) REINDEX=1; DO_INDEX=1; INDEX_SET=1; shift ;;
    --health-check) DO_HEALTH=1; HEALTH_SET=1; shift ;;
    --no-health-check) DO_HEALTH=0; HEALTH_SET=1; shift ;;
    --prepare-lsp) DO_PREPARE=1; PREPARE_SET=1; shift ;;
    --no-prepare-lsp) DO_PREPARE=0; PREPARE_SET=1; shift ;;
    --check-memories) DO_MEMORY_CHECK=1; MEMORY_SET=1; shift ;;
    --per-project) PER_PROJECT=1; shift ;;
    --hooks) DO_HOOKS=1; HOOKS_SET=1; shift ;;
    --auto-approve) AUTO_APPROVE=1; DO_HOOKS=1; HOOKS_SET=1; shift ;;
    --no-skill) DO_SKILL=0; shift ;;
    --skill-global) SKILL_GLOBAL=1; shift ;;
    --jetbrains) JETBRAINS=1; shift ;;
    --open-dashboard) DASHBOARD_OPEN=true; shift ;;
    --no-dashboard) DASHBOARD_ENABLED=false; DASHBOARD_OPEN=false; shift ;;
    --upgrade) UPGRADE=1; shift ;;
    --doctor) DOCTOR_ONLY=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge) PURGE=1; shift ;;
    --remove-tool) REMOVE_TOOL=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "Unknown option: $1 (try --help)" ;;
    *) (( ! PROJECT_ARG_SET )) || die "Specify just one project directory"; PROJECT_DIR="$1"; PROJECT_ARG_SET=1; shift ;;
  esac
done
# Correctly consume positional args appearing after --.
for positional in "$@"; do
  (( ! PROJECT_ARG_SET )) || die "Specify just one project directory"
  PROJECT_DIR="$positional"; PROJECT_ARG_SET=1
done
[[ -d "$PROJECT_DIR" ]] || die "Project directory not found: $PROJECT_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"
SERENA_CONFIG="${SERENA_HOME:-$HOME/.serena}/serena_config.yml"
PROJECT_CONFIG="$PROJECT_DIR/.serena/project.yml"
case "$PROFILE" in
  minimal)
    (( INDEX_SET )) || DO_INDEX=0
    (( HEALTH_SET )) || DO_HEALTH=0 ;;
  standard) : ;;
  advanced)
    (( PREPARE_SET )) || DO_PREPARE=1
    (( MEMORY_SET )) || DO_MEMORY_CHECK=1 ;;
  *) die "Unknown profile: $PROFILE (minimal|standard|advanced)" ;;
esac
if (( JETBRAINS )); then
  DO_PREPARE=0
  (( ${#WORKSPACE_FOLDERS[@]} )) && warn "--workspace is ignored by the JetBrains backend"
fi
(( UPGRADE )) && REINDEX=1
if (( (PURGE || REMOVE_TOOL) && ! UNINSTALL )); then
  die "--purge and --remove-tool require --uninstall"
fi
if (( UNINSTALL )) && (( ! CLIENTS_SET )); then
  # Every removal step is idempotent and reports "already absent",
  # so default to all known clients; pass -c to narrow the scope.
  CLIENTS=(claude-code codex grok codebuddy opencode pi)
fi
if (( READ_ONLY )) && [[ "$AGENT_INTERFACE" == REPL ]]; then
  warn "Serena REPL executes arbitrary Python; --read-only is NOT an enforcement boundary."
fi

ensure_uv() {
  log "Checking for uv"
  if have uv; then ok "uv: $(command -v uv)"; return 0; fi
  if (( DRY_RUN )); then log "[dry-run] would install uv (with confirmation)"; return 0; fi
  have curl || die "Install uv first: https://docs.astral.sh/uv/getting-started/installation/"
  warn "uv is required to install Serena"
  if confirm "Install uv using https://astral.sh/uv/install.sh?"; then
    # Avoid a pipeline that could mask curl failure; download then execute.
    local install_sh
    install_sh="$(mktemp)"
    if ! curl -fsSL https://astral.sh/uv/install.sh -o "$install_sh"; then rm -f "$install_sh"; die "Could not download uv installer"; fi
    sh "$install_sh"; rm -f "$install_sh"
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    have uv || die "uv installed, but executable not on PATH"
  else
    die "uv is required. Install it and rerun."
  fi
}

ensure_tool_bin_on_path() {
  (( DRY_RUN )) && return 0
  local bin_dir
  bin_dir="$(uv tool dir --bin 2>/dev/null || true)"
  [[ -z "$bin_dir" ]] && return 0
  case ":$PATH:" in
    *":$bin_dir:"*) : ;;
    *) export PATH="$bin_dir:$PATH"; warn "Added $bin_dir to PATH for this run; use 'uv tool update-shell' permanently" ;;
  esac
}

install_serena() {
  log "Checking Serena installation"
  if (( DRY_RUN )); then
    if uv tool list 2>/dev/null | grep -q "^${SERENA_PKG} "; then
      (( UPGRADE )) && run uv tool upgrade "$SERENA_PKG" || :
    else
      run uv tool install -p "$PYTHON_VERSION" "$SERENA_PKG"
    fi
  elif uv tool list 2>/dev/null | grep -q "^${SERENA_PKG} "; then
    if (( UPGRADE )); then run uv tool upgrade "$SERENA_PKG"; else ok "Serena already installed"; fi
  else
    run uv tool install -p "$PYTHON_VERSION" "$SERENA_PKG"
  fi
  ensure_tool_bin_on_path
  if (( ! DRY_RUN )); then
    have serena || die "'serena' missing from PATH after installation"
    SERENA_BIN="$(command -v serena)"
  fi
}

# `serena init` writes the global language backend on EVERY invocation, even if
# a config exists. Run it only for initial creation; select JetBrains at the
# project level to avoid changing the backend for other projects.
init_serena() {
  if [[ -f "$SERENA_CONFIG" ]]; then
    ok "Global Serena configuration already exists; preserving its backend"
    return 0
  fi
  if (( DRY_RUN )); then
    run serena init
  else
    run serena init
    [[ -f "$SERENA_CONFIG" ]] || die "Serena did not create global config: $SERENA_CONFIG"
  fi
}

choose_python() {
  if have python3; then CONFIG_PYTHON="$(command -v python3)"
  elif have uv; then CONFIG_PYTHON="$(uv python find "$PYTHON_VERSION" 2>/dev/null || true)"
  fi
  [[ -n "$CONFIG_PYTHON" ]] || die "Python 3 is required for safe YAML/JSON config merges"
}

# Small, dependency-free, conservative YAML config editor for Serena's known
# top-level scalars and simple lists. Supports flow and block lists and legacy
# 'languages'. Refuses unsupported YAML instead of corrupting it.
# Invoked only on explicitly requested changes, after 'serena init/create'.
edit_yaml() {
  local op="$1" file="$2"; shift 2
  if (( DRY_RUN )); then printf '    [dry-run] %s %s:' "$op" "$file"; printf ' %q' "$@"; printf '\n'; return 0; fi
  choose_python
  "$CONFIG_PYTHON" - "$op" "$file" "$@" <<'PY'
import csv, json, os, pathlib, re, shutil, sys, tempfile, time
op, filename, *args = sys.argv[1:]
path = pathlib.Path(filename)
if not path.is_file():
    raise SystemExit(f"Config not found: {path}")
original = path.read_text(encoding="utf-8")
lines = original.splitlines(keepends=True)

def locate(key):
    for i, line in enumerate(lines):
        m = re.match(rf"^{re.escape(key)}\s*:(.*)$", line)
        if m:
            j = i + 1
            while j < len(lines):
                s = lines[j]
                if re.match(r"^[A-Za-z_][A-Za-z0-9_-]*\s*:", s):
                    break
                j += 1
            return i, j, m.group(1).strip()
    return None

def read_list(key):
    loc = locate(key)
    if loc is None:
        return []
    i, j, value = loc
    # Inline comments after a flow list aren't supported, to avoid rewriting
    # complex YAML or accidentally eating a '#'-containing pattern.
    if value and value != 'null' and value != '~':
        if not (value.startswith('[') and value.endswith(']')):
            raise ValueError(f"{key} must be a block or inline list: {value!r}")
        content = value[1:-1].strip()
        if not content:
            return []
        try:
            v = json.loads(value)
            if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
                raise ValueError("not a string list")
            return v
        except (ValueError, TypeError):
            # Also accept valid YAML lists of bare identifiers and single quotes.
            parts = next(csv.reader([content], skipinitialspace=True))
            if not all(re.fullmatch(r"(?:[A-Za-z][A-Za-z0-9_.+-]*|'[^']*'|\"[^\"]*\")", s.strip()) for s in parts):
                raise ValueError(f"Unsupported inline YAML syntax in {key}")
            return [s.strip().strip("'\"") for s in parts]
    found = []
    for line in lines[i+1:j]:
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        m = re.match(r'^\s*-\s+(.*?)\s*(?:#.*)?$', line.rstrip('\n'))
        if not m:
            raise ValueError(f"Unsupported block YAML syntax in {key}: {line.strip()}")
        value = m.group(1).strip()
        if value[:1] in "'\"" and value[-1:] == value[:1]:
            value = value[1:-1]
        found.append(value)
    return found

def set_scalar(key, value):
    loc = locate(key)
    newline = f'{key}: {value}\n'
    if loc is None:
        if lines and not lines[-1].endswith('\n'): lines[-1] += '\n'
        lines.append(newline)
    else:
        i, _j, _old = loc
        # Preserve trailing comments for top-level scalar keys.
        suffix = ''
        if ' #' in lines[i]: suffix = ' #' + lines[i].split(' #', 1)[1].rstrip('\n')
        lines[i] = f'{key}: {value}{suffix}\n'

def set_list(key, additions):
    current = read_list(key)
    merged = list(dict.fromkeys(current + additions))
    if merged == current and len(current) == len(set(current)): return
    loc = locate(key)
    if loc is None:
        if lines and not lines[-1].endswith('\n'): lines[-1] += '\n'
        lines.append(f'{key}:\n')
        lines.extend(f'- {json.dumps(x, ensure_ascii=False)}\n' for x in merged)
        return
    i, j, value = loc
    if len(current) != len(set(current)):
        # Repair duplicate entries without leaving an ambiguous list behind.
        lines[i:j] = [f'{key}:\n'] + [f'- {json.dumps(x, ensure_ascii=False)}\n' for x in merged]
    elif value.startswith('[') or value in ('', 'null', '~'):
        # Flow list or null/empty list: rewrite the scalar before adding items.
        lines[i] = f'{key}:\n'
        lines[i+1:i+1] = [f'- {json.dumps(x, ensure_ascii=False)}\n' for x in merged]
    else:
        indent = ''
        for line in lines[i+1:j]:
            m = re.match(r'^(\s*)-\s+', line)
            if m: indent = m.group(1); break
        # Insert after last existing item, before the next YAML section.
        insertion = i + 1
        for k in range(i+1, j):
            if re.match(r'^\s*-\s+', lines[k]): insertion = k + 1
        lines[insertion:insertion] = [f'{indent}- {json.dumps(x, ensure_ascii=False)}\n' for x in merged[len(current):]]

try:
    if op == 'scalar':
        key, value = args
        set_scalar(key, value)
    elif op == 'list':
        key, *items = args
        set_list(key, items)
    elif op == 'replace-list':
        key, *items = args
        merged = list(dict.fromkeys(items))
        loc = locate(key)
        replacement = [f'{key}:\n'] + [f'- {json.dumps(x, ensure_ascii=False)}\n' for x in merged]
        if loc is None:
            if lines and not lines[-1].endswith('\n'): lines[-1] += '\n'
            lines.extend(replacement)
        else:
            i, j, _ = loc
            # Keep comments attached to the existing section.
            comments = [line for line in lines[i+1:j] if line.lstrip().startswith('#')]
            lines[i:j] = replacement + comments
    elif op == 'languages':
        # Rename legacy key and merge values if both keys are present.
        old = read_list('languages')
        wanted = list(dict.fromkeys(old + args))
        legacy = locate('languages')
        if legacy:
            i, j, _ = legacy
            # Preserve unrelated comments in the legacy section.
            comments = [s for s in lines[i+1:j] if s.lstrip().startswith('#')]
            lines[i:j] = comments
        set_list('language_servers', wanted)
    else:
        raise ValueError(f"Unknown edit operation: {op}")
except (ValueError, IndexError) as exc:
    raise SystemExit(f"Refusing unsafe YAML edit in {path}: {exc}")
updated = ''.join(lines)
if updated == original:
    print(f"Unchanged: {path}")
    sys.exit(0)
backup = path.with_name(path.name + '.bak.' + time.strftime('%Y%m%d-%H%M%S') + f'.{time.time_ns() % 1000000000:09d}')
shutil.copy2(path, backup)
fd, tmp = tempfile.mkstemp(prefix=path.name+'.', dir=path.parent)
try:
    with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as out:
        out.write(updated)
        out.flush(); os.fsync(out.fileno())
    shutil.copymode(path, tmp)
    os.replace(tmp, path)
except BaseException:
    if os.path.exists(tmp): os.unlink(tmp)
    raise
print(f"Updated: {path} (backup: {backup})")
PY
}

edit_scope_yaml() {
  local output
  output="$(edit_yaml "$@")" || return 1
  printf '%s\n' "$output"
  [[ "$output" == Updated:* ]] && SCOPE_CHANGED=1
  return 0
}

config_dashboard() {
  local file="$SERENA_CONFIG"
  log "Dashboard: enabled=$DASHBOARD_ENABLED, open_on_launch=$DASHBOARD_OPEN (global config)"
  if (( DRY_RUN )); then
    edit_yaml scalar "$file" web_dashboard "$DASHBOARD_ENABLED"
    edit_yaml scalar "$file" web_dashboard_open_on_launch "$DASHBOARD_OPEN"
    return 0
  fi
  [[ -f "$file" ]] || { warn "Global Serena config not found: $file"; return 1; }
  edit_yaml scalar "$file" web_dashboard "$DASHBOARD_ENABLED" || return 1
  edit_yaml scalar "$file" web_dashboard_open_on_launch "$DASHBOARD_OPEN"
}

# Source-file detection uses 'git ls-files' when available to ignore generated
# files. Data/markup LSPs require explicit --language.
detect_languages() {
  local dir list="" files
  for dir in "$@"; do
    if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      files="$(git -C "$dir" ls-files -co --exclude-standard 2>/dev/null || true)"
    else
      files="$(cd "$dir" && find . \( -name .git -o -name node_modules -o -name .venv -o -name venv \
                   -o -name target -o -name dist -o -name build -o -name __pycache__ -o -name .serena \) \
                   -prune -o -type f -print 2>/dev/null || true)"
    fi
    list+="$files"$'\n'
  done
  printf '%s\n' "$list" | awk -v min="$MIN_FILES" '
    function add(exts, lang, a,n,i) { n=split(exts,a," "); for(i=1;i<=n;i++) map[a[i]]=lang }
    BEGIN {
      add("py pyi", "python"); add("ts tsx js jsx mjs cjs mts cts", "typescript")
      add("go", "go"); add("rs", "rust"); add("java", "java")
      add("kt kts", "kotlin"); add("scala sc", "scala"); add("cs", "csharp")
      add("fs fsx fsi", "fsharp"); add("c h cc cpp cxx hh hpp hxx", "cpp")
      add("rb", "ruby"); add("php", "php"); add("swift", "swift")
      add("dart", "dart"); add("ex exs", "elixir"); add("erl hrl", "erlang")
      add("hs", "haskell"); add("lua", "lua"); add("zig", "zig")
      add("sh bash", "bash"); add("ps1 psm1", "powershell")
      add("tf", "terraform"); add("vue", "vue"); add("svelte", "svelte")
      add("clj cljs cljc", "clojure"); add("ml mli", "ocaml")
      add("jl", "julia"); add("r", "r"); add("pl pm", "perl")
      add("nix", "nix"); add("sol", "solidity"); add("elm", "elm")
      add("groovy", "groovy"); add("cr", "crystal")
    }
    {
      if ($0 ~ /(^|\/)(node_modules|vendor|third_party|dist|build|target|\.venv|venv|__pycache__|\.serena)\//) next
      n=split($0,parts,"/"); f=parts[n]
      if (f !~ /\./) next
      ext=tolower(f); sub(/^.*\./,"",ext)
      if (ext in map) cnt[map[ext]]++
    }
    END { for (l in cnt) if (cnt[l]>=min) print cnt[l], l }
  ' | sort -k1,1nr -k2,2 | head -n "$MAX_LANGUAGES" | awk '{print $2}'
}
resolve_languages() {
  RESOLVED_LANGS=()
  if (( ${#LANGUAGES[@]} )); then RESOLVED_LANGS=("${LANGUAGES[@]}")
  elif (( DETECT && ! JETBRAINS )); then
    local l
    local detection_dirs=("$PROJECT_DIR") rel abs
    if (( ${#WORKSPACE_FOLDERS[@]} )); then
      detection_dirs=()
      for rel in "${WORKSPACE_FOLDERS[@]}"; do
        [[ -d "$PROJECT_DIR/$rel" ]] || die "Workspace directory missing: $rel"
        abs="$(cd "$PROJECT_DIR/$rel" && pwd -P)"
        case "$abs" in "$PROJECT_DIR"|"$PROJECT_DIR"/*) ;; *) die "Workspace must be inside the project: $rel" ;; esac
        detection_dirs+=("$abs")
      done
    fi
    while IFS= read -r l; do [[ -n "$l" ]] && RESOLVED_LANGS+=("$l"); done < <(detect_languages "${detection_dirs[@]}")
  fi
  if (( ${#RESOLVED_LANGS[@]} )); then log "Language servers: ${RESOLVED_LANGS[*]}"
  else log "No explicit/detected language servers — Serena will use its defaults"; fi
}

prepare_ls_dependencies() {
  (( JETBRAINS || ! DO_PREPARE )) && return 0
  (( ${#RESOLVED_LANGS[@]} )) || { log "Skipping LSP prefetch (no languages resolved)"; return 0; }
  log "Prefetching Serena-managed language server dependencies"
  run serena download-ls-dependencies "${RESOLVED_LANGS[@]}"
}

create_project() {
  local file="$PROJECT_CONFIG"
  local valid_workspaces=() rel abs
  # Validate every workspace BEFORE creating a project or changing its config.
  if (( ${#WORKSPACE_FOLDERS[@]} && ! JETBRAINS )); then
    for rel in "${WORKSPACE_FOLDERS[@]}"; do
      [[ -d "$PROJECT_DIR/$rel" ]] || { warn "Workspace directory missing: $rel"; return 1; }
      abs="$(cd "$PROJECT_DIR/$rel" && pwd -P)" || return 1
      case "$abs" in
        "$PROJECT_DIR") rel="." ;;
        "$PROJECT_DIR"/*) rel="./${abs#"$PROJECT_DIR"/}" ;;
        *) warn "Workspace must be inside the project: $rel"; return 1 ;;
      esac
      valid_workspaces+=("$rel")
    done
  fi
  if [[ -f "$file" ]]; then
    ok "Serena project already exists"
    if (( SYNC_LANGUAGES )); then
      edit_yaml languages "$file" "${RESOLVED_LANGS[@]}" || return 1
    elif (( ${#RESOLVED_LANGS[@]} )) && (( ! JETBRAINS )); then
      log "Tip: --sync-languages adds detected language servers to an existing project"
    fi
  else
    local args=(project create)
    [[ -n "$PROJECT_NAME" ]] && args+=(--name "$PROJECT_NAME")
    local l
    for l in "${RESOLVED_LANGS[@]}"; do args+=(--language "$l"); done
    args+=("$PROJECT_DIR")
    log "Creating Serena project"
    run serena "${args[@]}" || return 1
    # Indexing happens after the config edits below via index_project(),
    # so the first index already sees ignored_paths/workspace settings.
    PROJECT_CREATED=1
  fi
  # Per-project configuration changes are opt-in; preserve other settings.
  if (( ${#IGNORE_PATTERNS[@]} )); then edit_scope_yaml list "$file" ignored_paths "${IGNORE_PATTERNS[@]}" || return 1; fi
  if (( ${#valid_workspaces[@]} )); then
    edit_scope_yaml replace-list "$file" ls_workspace_folders "${valid_workspaces[@]}" || return 1
  fi
  if (( JETBRAINS )); then edit_yaml scalar "$file" language_backend JetBrains || return 1; fi
  if [[ -n "$AGENT_INTERFACE" ]]; then edit_yaml scalar "$file" agent_interface "$AGENT_INTERFACE" || return 1; fi
  if (( READ_ONLY_SET )); then edit_yaml scalar "$file" read_only true || return 1; fi
}

# Honor the effective backend even when it was configured before this setup
# invocation (project settings override the global setting). Do not run the LSP
# index or health-check against a JetBrains-backed project.
detect_effective_backend() {
  choose_python
  local backend
  backend="$("$CONFIG_PYTHON" - "$PROJECT_CONFIG" "$SERENA_CONFIG" <<'PY'
import pathlib, re, sys

def read_backend(filename):
    path = pathlib.Path(filename)
    if not path.exists():
        return None
    # Only recognize a simple top-level scalar; unknown syntax is left for
    # Serena's own config parser to validate during subsequent commands.
    for line in path.read_text(encoding='utf-8').splitlines():
        m = re.match(r"^language_backend:\s*['\"]?(LSP|JetBrains)['\"]?\s*(?:#.*)?$", line, re.I)
        if m:
            return m.group(1)
    return None

print(read_backend(sys.argv[1]) or read_backend(sys.argv[2]) or 'LSP')
PY
)" || return 1
  EFFECTIVE_JETBRAINS=0
  if [[ "${backend,,}" == jetbrains ]]; then
    EFFECTIVE_JETBRAINS=1
    log "Effective language backend: JetBrains (skipping LSP-only checks)"
  fi
}

# Upstream indexing is one-shot: `serena project index` once after creation,
# then Serena auto-updates the index on file change. So there is no local
# cache/stamp here: fresh projects index once (after the config edits in
# create_project), existing projects skip unless --reindex (implied by
# --upgrade), --sync-languages, or an indexing scope change requires it. Validation is the
# command's exit code plus `serena project health-check` afterwards.
index_project() {
  (( DO_INDEX )) || { log "Skipping indexing"; return 0; }
  (( EFFECTIVE_JETBRAINS )) && { log "Skipping indexing (JetBrains backend)"; return 0; }
  local reason=""
  if (( REINDEX )); then
    reason="reindex requested"
  elif (( PROJECT_CREATED )); then
    reason="fresh project"
  elif (( SYNC_LANGUAGES )) && (( ${#RESOLVED_LANGS[@]} )) && (( ! JETBRAINS )); then
    reason="language list synced"
  elif (( SCOPE_CHANGED )); then
    reason="workspace or ignore settings changed"
  else
    log "Skipping indexing (already indexed; Serena auto-updates on file change; use --reindex to force)"
    return 0
  fi
  if (( DRY_RUN )); then run serena project index; return 0; fi
  log "Indexing project ($reason)"
  if (cd "$PROJECT_DIR" && serena project index); then
    ok "Project indexed"
  else
    return 1
  fi
}

health_check() {
  (( DO_HEALTH )) || { log "Skipping health-check"; return 0; }
  (( EFFECTIVE_JETBRAINS )) && { log "Skipping LSP health-check (JetBrains backend)"; return 0; }
  log "Running Serena project health-check"
  (cd "$PROJECT_DIR" && run serena project health-check)
}

check_memories() {
  (( DO_MEMORY_CHECK )) || return 0
  local folder="$PROJECT_DIR/.serena/memories"
  if [[ ! -d "$folder" ]] || [[ -z "$(find "$folder" -type f -print -quit 2>/dev/null)" ]]; then
    log "No project memories found — skipping reference check"
    return 0
  fi
  log "Checking Serena memory references"
  (cd "$PROJECT_DIR" && run serena memories check)
}

# Ensure explicit MCP registrations NEVER auto-open unless opted in.
server_args() {
  local context="$1"; shift
  MCP_SERVER_ARGS=(start-mcp-server --context "$context" --open-web-dashboard "$DASHBOARD_OPEN")
  [[ -n "$AGENT_INTERFACE" ]] && MCP_SERVER_ARGS+=(--agent-interface "$AGENT_INTERFACE")
  MCP_SERVER_ARGS+=("$@")
}

# Return: 0 = exact project registration, 1 = absent, 2 = differs,
# 3 = unreadable/invalid JSON. This does NOT confuse user-level registrations
# with this project's .mcp.json entry.
claude_project_registration_status() {
  local file="$PROJECT_DIR/.mcp.json"
  [[ -f "$file" ]] || return 1
  choose_python
  "$CONFIG_PYTHON" - "$file" "$SERENA_BIN" "${MCP_SERVER_ARGS[@]}" <<'PY'
import json, pathlib, sys
file, executable, *wanted = sys.argv[1:]
try:
    obj = json.loads(pathlib.Path(file).read_text(encoding='utf-8'))
    found = obj.get('mcpServers', {}).get('serena')
except (ValueError, OSError, AttributeError):
    sys.exit(3)
if found is None: sys.exit(1)
if not isinstance(found, dict): sys.exit(3)
if found.get('command') in (executable, 'serena') and found.get('args') == wanted:
    sys.exit(0)
sys.exit(2)
PY
}

setup_client() {
  local client="$1"
  log "Configuring MCP client: $client"
  case "$client" in
    claude-code)
      if (( PER_PROJECT )); then
        if (( ! DRY_RUN )) && ! have claude; then warn "Claude CLI missing"; return 1; fi
        server_args claude-code --project "$PROJECT_DIR"
        if (( ! DRY_RUN )); then
          local status=0
          claude_project_registration_status || status=$?
          case "$status" in
            0) ok "Claude project MCP registration already matches"; return 0 ;;
            1) : ;;
            2) warn "Replacing outdated project-scoped Serena MCP registration"
               (cd "$PROJECT_DIR" && claude mcp remove --scope project serena) || return 1 ;;
            *) warn "Could not inspect $PROJECT_DIR/.mcp.json; refusing to overwrite"; return 1 ;;
          esac
        fi
        (cd "$PROJECT_DIR" && run claude mcp add --scope project serena -- "$SERENA_BIN" "${MCP_SERVER_ARGS[@]}")
      else
        # Serena native setup registers its own command. Global dashboard
        # configuration above controls whether it opens on startup.
        run serena setup claude-code
      fi ;;
    codex|grok|codebuddy)
      run serena setup "$client" ;;
    opencode|pi)
      if (( ! DRY_RUN )) && ! have "$client"; then warn "$client CLI missing"; return 1; fi
      server_args agent --project "$PROJECT_DIR"
      local args=(mcp add serena)
      [[ "$client" == pi ]] && args+=(--local)
      (cd "$PROJECT_DIR" && run "$client" "${args[@]}" -- "$SERENA_BIN" "${MCP_SERVER_ARGS[@]}") ;;
    *) warn "Unsupported client: $client"; return 1 ;;
  esac
}

# Install hooks per client, preserving non-Serena hooks and filling in only
# missing commands (not just checking whether any Serena hook exists).
install_hooks() {
  local client="$1" file
  case "$client" in
    claude-code) file="$PROJECT_DIR/.claude/settings.json" ;;
    codebuddy) file="$PROJECT_DIR/.codebuddy/settings.json" ;;
    grok) file="$PROJECT_DIR/.grok/hooks/serena-hooks.json" ;;
    codex) file="$PROJECT_DIR/.codex/hooks.json" ;;
    *) warn "No hook integration for $client"; return 0 ;;
  esac
  log "Reconciling $client hooks: $file"
  if (( DRY_RUN )); then printf '    [dry-run] would merge Serena hooks into %s\n' "$file"; return 0; fi
  choose_python
  "$CONFIG_PYTHON" - "$client" "$file" "$AUTO_APPROVE" <<'PY'
import json, os, pathlib, shutil, sys, tempfile, time
client, filename, auto = sys.argv[1:]
path = pathlib.Path(filename)
auto = auto == '1'
def hook(command, matcher=None, timeout=None, status=None):
    obj = {'hooks': [{'type':'command', 'command':f'serena-hooks {command} --client={client}'}]}
    if matcher is not None: obj['matcher'] = matcher
    if timeout is not None: obj['hooks'][0]['timeout'] = timeout
    if status: obj['hooks'][0]['statusMessage'] = status
    return obj
wanted = {}
def add(event, *hooks): wanted.setdefault(event, []).extend(hooks)
if client == 'claude-code':
    add('PreToolUse', hook('remind', ''))
    if auto: add('PreToolUse', hook('auto-approve', 'mcp__serena__*'))
    add('SessionStart', hook('activate', ''))
    add('SessionEnd', hook('cleanup', ''))
elif client == 'codebuddy':
    add('PostToolUse', hook('remind', ''))
    if auto: add('Notification', hook('auto-approve', ''))
    add('SessionStart', hook('activate', ''))
    add('Stop', hook('cleanup', ''))
elif client == 'grok':
    add('PreToolUse', hook('remind', 'grep|read_file|run_terminal_command', 5))
    add('Stop', hook('cleanup', timeout=5))
elif client == 'codex':
    add('PreToolUse', hook('remind', 'Bash', 5, 'Checking Serena tool usage'),
        hook('plan-guard', '^mcp__serena__', 5, 'Checking Serena plan-mode permissions'))
    add('PostToolUse', hook('reset', '^mcp__serena__.*$'))
    add('SessionStart', hook('activate', 'startup|resume', 5, 'Activating Serena project'))
    add('UserPromptSubmit', hook('plan-context', timeout=5, status='Applying Serena plan context'))
    add('SessionEnd', hook('cleanup', timeout=3, status='Cleaning up Serena hook state'))
else:
    raise SystemExit(f'Unsupported hook client: {client}')
if path.exists():
    try: data = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError) as ex: raise SystemExit(f'Invalid hooks JSON at {path}: {ex}')
else: data = {}
if not isinstance(data, dict): raise SystemExit(f'Expected object at {path}')
hooks = data.setdefault('hooks', {})
if not isinstance(hooks, dict): raise SystemExit(f'Expected hooks object in {path}')
changed = False
for event, entries in wanted.items():
    existing = hooks.setdefault(event, [])
    if not isinstance(existing, list): raise SystemExit(f'Expected list of hooks for {event} in {path}')
    # A single Serena command may be inside a group of hooks. Match command
    # and matcher, without treating unrelated Serena commands as duplicates.
    for proposed in entries:
        name = proposed['hooks'][0]['command']
        matcher = proposed.get('matcher', '')
        exists = any(isinstance(item, dict) and item.get('matcher', '') == matcher and
                     any(isinstance(h, dict) and h.get('command') == name for h in item.get('hooks', []))
                     for item in existing)
        if not exists: existing.append(proposed); changed = True
if not changed:
    print(f'Unchanged: {path}')
    sys.exit(0)
path.parent.mkdir(parents=True, exist_ok=True)
if path.exists():
    backup = path.with_name(path.name + '.bak.' + time.strftime('%Y%m%d-%H%M%S') + f'.{time.time_ns()%1000000000:09d}')
    shutil.copy2(path, backup)
fd, tmp = tempfile.mkstemp(prefix=path.name+'.', dir=path.parent)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as out:
        json.dump(data, out, indent=2, ensure_ascii=False)
        out.write('\n'); out.flush(); os.fsync(out.fileno())
    if path.exists(): shutil.copymode(path, tmp)
    os.replace(tmp, path)
except BaseException:
    if os.path.exists(tmp): os.unlink(tmp)
    raise
print(f'Updated: {path}')
PY
}

# Paths used by the official `skills` CLI for project/global agent skills.
# Codex, OpenCode and Pi use the same project-local .agents/skills location.
skill_dir_for_client() {
  local client="$1"
  if (( SKILL_GLOBAL )); then
    case "$client" in
      claude-code) printf '%s' "$HOME/.claude/skills" ;;
      codex) printf '%s' "$HOME/.codex/skills" ;;
      grok) printf '%s' "$HOME/.grok/skills" ;;
      codebuddy) printf '%s' "$HOME/.codebuddy/skills" ;;
      opencode) printf '%s' "$HOME/.config/opencode/skills" ;;
      pi) printf '%s' "$HOME/.agents/skills" ;;
      *) return 1 ;;
    esac
  else
    case "$client" in
      claude-code) printf '%s' "$PROJECT_DIR/.claude/skills" ;;
      grok) printf '%s' "$PROJECT_DIR/.grok/skills" ;;
      codebuddy) printf '%s' "$PROJECT_DIR/.codebuddy/skills" ;;
      codex|opencode|pi) printf '%s' "$PROJECT_DIR/.agents/skills" ;;
      *) return 1 ;;
    esac
  fi
}

# Installs only the `serena-usage` skill from the requested repository, never every
# skill in that repository. Target only explicitly selected/active MCP clients.
# --yes is applied to npx (CLI package download) and -y to skills (install).
# The upstream skill must exist; a missing skill is an explicit setup failure.
install_serena_skill() {
  (( DO_SKILL )) || { log "Skipping Serena agent skill (--no-skill)"; return 0; }
  (( ${#CLIENTS[@]} )) || { log "Skipping agent skill (no MCP clients selected)"; return 0; }
  local client dir path
  local need_agents=() args=()
  local seen=" "
  for client in "${CLIENTS[@]}"; do
    # Clients may be specified more than once. Avoid duplicate -a arguments.
    [[ "$seen" == *" $client "* ]] && continue
    seen+="$client "
    dir="$(skill_dir_for_client "$client")" || { warn "Unsupported skill client: $client"; return 1; }
    path="$dir/$SERENA_SKILL_NAME/SKILL.md"
    if (( ! UPGRADE )) && [[ -f "$path" ]]; then
      ok "Serena skill already installed for $client: $path"
    else
      need_agents+=("$client")
    fi
  done
  (( ${#need_agents[@]} )) || { ok "Serena skill already installed for all selected clients"; return 0; }
  args=(--yes skills add "$SERENA_SKILL_REPO" --skill "$SERENA_SKILL_NAME")
  for client in "${need_agents[@]}"; do args+=(--agent "$client"); done
  (( SKILL_GLOBAL )) && args+=(--global)
  args+=(-y)
  log "Installing Serena skill from $SERENA_SKILL_REPO for: ${need_agents[*]}"
  if (( ! DRY_RUN )) && ! have npx; then
    warn "npx not found. Install Node.js and npm, or use --no-skill."
    return 1
  fi
  if ! (cd "$PROJECT_DIR" && run npx "${args[@]}"); then
    warn "Serena skill install failed. Check that '$SERENA_SKILL_NAME' exists at $SERENA_SKILL_REPO."
    return 1
  fi
  (( DRY_RUN )) && return 0
  local missing=0
  for client in "${need_agents[@]}"; do
    dir="$(skill_dir_for_client "$client")"
    path="$dir/$SERENA_SKILL_NAME/SKILL.md"
    if [[ -f "$path" ]]; then
      ok "Serena skill installed for $client: $path"
    else
      warn "Skill CLI completed, but no Serena SKILL.md found for $client at $path"
      missing=1
    fi
  done
  (( missing == 0 ))
}

doctor() {
  local config="${SERENA_HOME:-$HOME/.serena}/serena_config.yml" bad=0
  log "Serena diagnostics for: $PROJECT_DIR"
  for cmd in uv serena; do
    if have "$cmd"; then ok "$cmd: $(command -v "$cmd")"; else warn "$cmd missing"; bad=1; fi
  done
  if [[ -f "$config" ]]; then
    ok "Global config: $config"
    grep -E '^web_dashboard(_open_on_launch)?:' "$config" || true
  else warn "Global config missing: $config"; bad=1; fi
  if [[ -f "$PROJECT_CONFIG" ]]; then
    ok "Project config present"
    if have serena; then
      if detect_effective_backend && (( EFFECTIVE_JETBRAINS )); then
        log "Skipping LSP health-check (JetBrains backend)"
      else
        (cd "$PROJECT_DIR" && serena project health-check) || bad=1
      fi
    fi
  else warn "No project.yml (run setup first)"; bad=1; fi
  for client in "${CLIENTS[@]}"; do
    case "$client" in claude-code) tool=claude ;; codex) tool=codex ;; *) tool="$client" ;; esac
    if have "$tool"; then ok "$tool available"; else warn "$tool missing"; fi
    if (( DO_SKILL )); then
      local skill_path
      skill_path="$(skill_dir_for_client "$client")/$SERENA_SKILL_NAME/SKILL.md"
      if [[ -f "$skill_path" ]]; then ok "Serena skill installed: $skill_path"; else warn "Serena skill missing: $skill_path"; bad=1; fi
    fi
  done
  (( bad == 0 ))
}

# True when the project-scoped Claude config registers a serena server.
project_has_claude_serena() {
  choose_python
  "$CONFIG_PYTHON" - "$PROJECT_DIR/.mcp.json" <<'PY'
import json, pathlib, sys
try:
    obj = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
    sys.exit(0 if isinstance(obj.get('mcpServers', {}).get('serena'), dict) else 1)
except (ValueError, OSError, AttributeError):
    sys.exit(1)
PY
}

# True when the project-local pi config mentions a serena server anywhere.
# (Recursive key search: the exact nesting is pi-version-dependent.)
project_has_pi_serena() {
  choose_python
  "$CONFIG_PYTHON" - "$PROJECT_DIR/.pi/mcp.json" <<'PY'
import json, pathlib, sys
try:
    obj = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
except (ValueError, OSError):
    sys.exit(1)
def found(node):
    if isinstance(node, dict):
        return any(k == 'serena' or found(v) for k, v in node.items())
    if isinstance(node, list):
        return any(found(x) for x in node)
    return False
sys.exit(0 if found(obj) else 1)
PY
}

# Delete one [dotted.section] from a TOML file. Reverses the user-global
# `serena setup codex/grok` registrations. Keeps everything else
# byte-identical, backs up before writing, and deletes the file only when
# nothing but blanks would remain.
remove_toml_section() {
  local file="$1" section="$2"
  log "Stripping [$section] from $file"
  if (( DRY_RUN )); then printf '    [dry-run] would delete [%s] from %s\n' "$section" "$file"; return 0; fi
  choose_python
  "$CONFIG_PYTHON" - "$file" "$section" <<'PY'
import os, pathlib, shutil, sys, tempfile, time
filename, section = sys.argv[1:]
path = pathlib.Path(filename)
if not path.is_file():
    print(f"Absent: {path} (nothing to strip)")
    sys.exit(0)
first, last = section.split('.', 1)
headers = {f'[{section}]', f'[{first}."{last}"]'}
def is_header(s):
    s = s.strip()
    if s in headers:
        return True
    return any(s.startswith(h) and s[len(h):].lstrip().startswith('#') for h in headers)
lines = path.read_text(encoding='utf-8').splitlines(keepends=True)
start = next((i for i, line in enumerate(lines) if is_header(line)), None)
if start is None:
    print(f"Absent: [{section}] not found in {path}")
    sys.exit(0)
end = next((j for j in range(start + 1, len(lines)) if lines[j].strip().startswith('[')), len(lines))
kept = lines[:start] + lines[end:]
backup = path.with_name(path.name + '.bak.' + time.strftime('%Y%m%d-%H%M%S') + f'.{time.time_ns() % 1000000000:09d}')
shutil.copy2(path, backup)
if not any(line.strip() for line in kept):
    path.unlink()
    print(f"Removed: {path} (only held [{section}])")
    sys.exit(0)
fd, tmp = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
try:
    with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as out:
        out.write(''.join(kept))
        out.flush(); os.fsync(out.fileno())
    shutil.copymode(path, tmp)
    os.replace(tmp, path)
except BaseException:
    if os.path.exists(tmp): os.unlink(tmp)
    raise
print(f"Updated: {path} (backup: {backup})")
PY
}

# `opencode mcp add` (without --global) writes the project config, and
# opencode offers no `mcp remove`, so strip the serena entry by hand. Only
# touches files that parse as plain JSON; anything else is left for the user.
remove_opencode_mcp() {
  local cfg rc=0 tried=0
  for cfg in "$PROJECT_DIR/opencode.json" "$PROJECT_DIR/.opencode.json"; do
    [[ -f "$cfg" ]] || continue
    tried=1
    if (( DRY_RUN )); then printf '    [dry-run] would delete the serena MCP entry from %s\n' "$cfg"; continue; fi
    choose_python
    "$CONFIG_PYTHON" - "$cfg" <<'PY' || rc=1
import json, os, pathlib, shutil, sys, tempfile, time
path = pathlib.Path(sys.argv[1])
try:
    obj = json.loads(path.read_text(encoding='utf-8'))
except (OSError, ValueError) as ex:
    raise SystemExit(f"Cannot parse {path} as JSON (comments?); remove the serena entry under mcp by hand: {ex}")
if not isinstance(obj, dict):
    raise SystemExit(f"Expected object at {path}")
mcp = obj.get('mcp')
if not isinstance(mcp, dict) or 'serena' not in mcp:
    print(f"Absent: serena MCP entry in {path}")
    sys.exit(0)
del mcp['serena']
if not mcp:
    del obj['mcp']
backup = path.with_name(path.name + '.bak.' + time.strftime('%Y%m%d-%H%M%S') + f'.{time.time_ns() % 1000000000:09d}')
shutil.copy2(path, backup)
if not obj:
    path.unlink()
    print(f"Removed: {path} (only held the serena entry)")
    sys.exit(0)
fd, tmp = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as out:
        json.dump(obj, out, indent=2, ensure_ascii=False)
        out.write('\n'); out.flush(); os.fsync(out.fileno())
    shutil.copymode(path, tmp)
    os.replace(tmp, path)
except BaseException:
    if os.path.exists(tmp): os.unlink(tmp)
    raise
print(f"Updated: {path} (backup: {backup})")
PY
  done
  (( tried )) || log "No project opencode.json (nothing to strip)"
  return $rc
}

# Reverse of install_hooks: strip every `serena-hooks ...` command from the
# client's hooks file, preserving non-Serena hooks. Deletes the file when it
# holds nothing but Serena hooks and no other settings.
remove_hooks() {
  local client="$1" file
  case "$client" in
    claude-code) file="$PROJECT_DIR/.claude/settings.json" ;;
    codebuddy) file="$PROJECT_DIR/.codebuddy/settings.json" ;;
    grok) file="$PROJECT_DIR/.grok/hooks/serena-hooks.json" ;;
    codex) file="$PROJECT_DIR/.codex/hooks.json" ;;
    *) log "Skipping hooks removal for $client (no hook integration)"; return 0 ;;
  esac
  log "Stripping Serena hooks: $file"
  if (( DRY_RUN )); then printf '    [dry-run] would strip serena-hooks entries from %s\n' "$file"; return 0; fi
  [[ -f "$file" ]] || { ok "No hooks file for $client (already absent)"; return 0; }
  choose_python
  "$CONFIG_PYTHON" - "$file" <<'PY'
import json, os, pathlib, shutil, sys, tempfile, time
path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding='utf-8'))
except (OSError, json.JSONDecodeError) as ex:
    raise SystemExit(f"Invalid hooks JSON at {path}; remove serena-hooks entries by hand: {ex}")
if not isinstance(data, dict):
    raise SystemExit(f"Expected object at {path}")
hooks = data.get('hooks')
if not isinstance(hooks, dict) or not hooks:
    print(f"Absent: no hooks in {path}")
    sys.exit(0)
def is_serena(entry):
    inner = entry.get('hooks') if isinstance(entry, dict) else None
    if not isinstance(inner, list):
        return False
    return any(isinstance(h, dict) and isinstance(h.get('command'), str)
               and h['command'].startswith('serena-hooks ') for h in inner)
changed = False
for event in list(hooks.keys()):
    entries = hooks[event]
    if not isinstance(entries, list):
        raise SystemExit(f"Expected list of hooks for {event} in {path}")
    kept = [e for e in entries if not is_serena(e)]
    if len(kept) != len(entries):
        changed = True
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
if not changed:
    print(f"Unchanged: {path} (no Serena hooks)")
    sys.exit(0)
backup = path.with_name(path.name + '.bak.' + time.strftime('%Y%m%d-%H%M%S') + f'.{time.time_ns() % 1000000000:09d}')
shutil.copy2(path, backup)
if not hooks and len(data) == 1:
    path.unlink()
    print(f"Removed: {path} (only held Serena hooks)")
    sys.exit(0)
if not hooks:
    del data['hooks']
fd, tmp = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as out:
        json.dump(data, out, indent=2, ensure_ascii=False)
        out.write('\n'); out.flush(); os.fsync(out.fileno())
    shutil.copymode(path, tmp)
    os.replace(tmp, path)
except BaseException:
    if os.path.exists(tmp): os.unlink(tmp)
    raise
print(f"Updated: {path} (backup: {backup})")
PY
}

# Reverse of install_serena_skill: delete the installed skill directory per
# selected client (deduped; codex/opencode/pi share .agents/skills).
remove_serena_skill() {
  local client dir path seen=" "
  for client in "${CLIENTS[@]}"; do
    [[ "$seen" == *" $client "* ]] && continue
    seen+="$client "
    dir="$(skill_dir_for_client "$client")" || { warn "Unsupported skill client: $client"; return 1; }
    path="$dir/$SERENA_SKILL_NAME"
    if [[ ! -e "$path" ]]; then
      ok "Serena skill already absent for $client"
    elif (( DRY_RUN )); then
      printf '    [dry-run] would delete %s\n' "$path"
    else
      run rm -rf "$path" || return 1
      ok "Removed Serena skill for $client: $path"
    fi
  done
}

remove_serena_tool() {
  warn "The serena-agent uv tool is global; removal affects all projects"
  if (( DRY_RUN )); then run uv tool uninstall "$SERENA_PKG"; return 0; fi
  if uv tool list 2>/dev/null | grep -q "^${SERENA_PKG} "; then
    run uv tool uninstall "$SERENA_PKG"
  else
    ok "Serena tool already absent"
  fi
}

remove_client() {
  local client="$1"
  log "Removing MCP registration: $client"
  case "$client" in
    claude-code)
      if (( ! DRY_RUN )) && ! have claude; then warn "Claude CLI missing"; return 1; fi
      if (( PER_PROJECT )); then
        if (( ! DRY_RUN )) && ! project_has_claude_serena; then
          ok "Claude project MCP registration already absent"; return 0
        fi
        (cd "$PROJECT_DIR" && run claude mcp remove --scope project serena)
      else
        # No scope: removes from whichever scope it exists in. Covers the
        # user-level registration written by `serena setup claude-code`.
        if (cd "$PROJECT_DIR" && run claude mcp remove serena); then
          ok "Claude MCP registration removed"
        elif ! project_has_claude_serena && ! claude mcp list 2>/dev/null | grep -q '^serena:'; then
          ok "Claude MCP registration already absent"
        else
          warn "Could not remove the Claude MCP registration; remove it by hand (claude mcp remove serena)"
          return 1
        fi
      fi ;;
    codex)
      warn "Codex MCP registration is user-level; removal affects all projects"
      remove_toml_section "$HOME/.codex/config.toml" mcp_servers.serena ;;
    grok)
      warn "Grok MCP registration is user-level; removal affects all projects"
      remove_toml_section "$HOME/.grok/config.toml" mcp_servers.serena ;;
    codebuddy)
      if (( ! DRY_RUN )) && ! have codebuddy; then warn "CodeBuddy CLI missing; remove the serena server by hand (codebuddy mcp remove serena)"; return 1; fi
      (cd "$PROJECT_DIR" && run codebuddy mcp remove --scope user serena) ;;
    opencode)
      # opencode has `mcp add` but no `mcp remove`; strip the project config.
      remove_opencode_mcp ;;
    pi)
      if (( ! DRY_RUN )) && ! have pi; then warn "pi CLI missing"; return 1; fi
      if (( ! DRY_RUN )) && ! project_has_pi_serena; then
        ok "pi MCP registration already absent (.pi/mcp.json)"
      else
        (cd "$PROJECT_DIR" && run pi mcp remove serena --local)
      fi ;;
    *) warn "Unsupported client: $client"; return 1 ;;
  esac
}

uninstall_project() {
  (( DRY_RUN )) && warn "Dry-run mode — nothing will be changed"
  log "Project directory: $PROJECT_DIR"
  if (( PURGE )); then
    if [[ ! -d "$PROJECT_DIR/.serena" ]]; then
      ok "No .serena directory (nothing to purge)"
    else
      if (( DRY_RUN )); then
        log "[dry-run] would delete $PROJECT_DIR/.serena (including memories)"
      else
        warn "This deletes $PROJECT_DIR/.serena, including memories and index caches."
        confirm "Delete the .serena directory?" || die "Aborted (re-run with -y to confirm)."
      fi
      run rm -rf "$PROJECT_DIR/.serena" || FAILED+=("purge")
      (( DRY_RUN )) || ok "Deleted $PROJECT_DIR/.serena"
    fi
  fi
  local client
  for client in "${CLIENTS[@]}"; do
    remove_client "$client" || FAILED+=("$client")
    remove_hooks "$client" || FAILED+=("$client-hooks")
  done
  remove_serena_skill || FAILED+=("serena-skill")
  if (( REMOVE_TOOL )); then remove_serena_tool || FAILED+=("tool"); fi
  printf '\n'
  if (( ${#FAILED[@]} )); then
    warn "Uninstall finished with issues: ${FAILED[*]}"
  else
    ok "Serena removed from project: $PROJECT_DIR"
  fi
  cat <<EOF

Next steps:
  - Restart your MCP client, then verify serena is gone (/mcp or equivalent).
  - .serena directory: $( (( PURGE )) && printf 'deleted' || printf 'kept (memories preserved; re-run with --purge to delete)' ).
  - serena-agent uv tool: $( (( REMOVE_TOOL )) && printf 'uninstalled' || printf 'kept (re-run with --remove-tool to uninstall)' ).
  - To re-add later: ${0##*/} [options] "$PROJECT_DIR"
EOF
  (( ${#FAILED[@]} == 0 ))
}

main() {
  (( DRY_RUN )) && warn "Dry-run mode — nothing will be changed"
  if (( DOCTOR_ONLY )); then doctor; return $?; fi
  if (( UNINSTALL )); then uninstall_project; return $?; fi
  log "Project directory: $PROJECT_DIR"
  ensure_uv
  install_serena
  init_serena || die "Serena initialization failed"
  config_dashboard || FAILED+=("dashboard-config")
  resolve_languages
  if create_project; then
    detect_effective_backend || FAILED+=("backend-detection")
    if (( ! EFFECTIVE_JETBRAINS )); then
      prepare_ls_dependencies || FAILED+=("lsp-prefetch")
    fi
    index_project || FAILED+=("index")
    health_check || FAILED+=("health-check")
    check_memories || FAILED+=("memories")
    local client
    for client in "${CLIENTS[@]}"; do
      setup_client "$client" || FAILED+=("$client")
      if (( DO_HOOKS )); then install_hooks "$client" || FAILED+=("$client-hooks"); fi
    done
    install_serena_skill || FAILED+=("serena-skill")
  else
    FAILED+=("project-config")
    warn "Project configuration failed; skipping indexing, health checks and client registration"
  fi
  printf '\n'
  if (( ${#FAILED[@]} )); then
    warn "Finished with issues: ${FAILED[*]}"
  else
    ok "Serena setup complete: $PROJECT_DIR"
  fi
  cat <<EOF

Next steps:
EOF
  if (( ${#CLIENTS[@]} )); then
    cat <<EOF
  - Restart your MCP client in this project, then check its Serena MCP connection.
  - Ask your agent: "Use Serena in this project. Follow its project activation
    instructions and complete onboarding if needed. Read the memory_maintenance
    memory before writing project memories. Save useful project facts, then list
    the project memories and summarize what you learned."
  - Review the memories in $PROJECT_DIR/.serena/memories; start a new agent
    conversation after onboarding to free up context.
EOF
  else
    printf '  - To onboard with an agent, rerun setup with --client NAME.\n'
  fi
  cat <<EOF
  - The dashboard will $( [[ "$DASHBOARD_ENABLED" == false ]] && printf 'be disabled' || { [[ "$DASHBOARD_OPEN" == true ]] && printf 'auto-open' || printf 'remain available without opening a browser tab'; } ).
  - Global settings: ${SERENA_HOME:-$HOME/.serena}/serena_config.yml
  - Project settings: $PROJECT_DIR/.serena/project.yml
  - Serena agent skill: $SERENA_SKILL_REPO (skill: $SERENA_SKILL_NAME)
  - Diagnostics: ${0##*/} --doctor "$PROJECT_DIR"
  - Documentation: https://oraios.github.io/serena/
EOF
  (( ${#FAILED[@]} == 0 ))
}
main
