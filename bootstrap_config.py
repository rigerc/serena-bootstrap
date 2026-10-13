#!/usr/bin/env python3
"""Resolve bootstrap preferences and apply explicit Serena settings safely."""
from __future__ import annotations

import argparse
import copy
import io
import json
import math
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time
import tomllib

CLIENTS = ['claude-code', 'codex', 'grok', 'codebuddy', 'opencode', 'pi']
DEFAULTS = dict(clients=['claude-code'], profile='standard', hooks=False,
                auto_approve=False, skill=True, skill_global=False, per_project=False,
                detect=True, sync_languages=False, min_files=3, max_languages=5,
                languages=[], ignore=[], workspace=[], name='')
LIST_KEYS = {'default_modes', 'added_modes', 'base_modes', 'excluded_tools',
             'included_optional_tools', 'fixed_tools', 'included_apis', 'excluded_apis',
             'ignored_paths', 'read_only_memory_patterns', 'ignored_memory_patterns'}
COMMON_KEYS = LIST_KEYS - {'base_modes'} | {'agent_interface', 'language_backend', 'ls_specific_settings'}
PROJECT_KEYS = COMMON_KEYS | {'read_only', 'initial_prompt', 'initial_prompt_file', 'inherit'}
GLOBAL_KEYS = (COMMON_KEYS - {'added_modes'}) | {'base_modes', 'tool_timeout', 'log_level', 'web_dashboard',
                             'web_dashboard_open_on_launch', 'gui_log_window', 'trace_lsp_communication'}
STARTUP_KEYS = {'context', 'modes', 'add_modes', 'agent_interface', 'language_backend',
                'tool_timeout', 'log_level', 'web_dashboard', 'web_dashboard_open_on_launch',
                'gui_log_window', 'trace_lsp_communication'}
INHERIT = {'$inherit': True}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_section(section, values):
    allowed = {'bootstrap': set(DEFAULTS) | {'index', 'health_check', 'prepare_lsp', 'check_memories'},
               'project': PROJECT_KEYS, 'global': GLOBAL_KEYS, 'startup': STARTUP_KEYS}[section]
    require(isinstance(values, dict), f'{section} must be a table')
    for key, value in values.items():
        require(key in allowed, f'Unknown {section} setting: {key}')
        if value == INHERIT:
            require(section == 'project', 'Inheritance resets are project-only')
            continue
        if key in LIST_KEYS | {'clients', 'languages', 'ignore', 'workspace', 'modes', 'add_modes', 'inherit'}:
            require(isinstance(value, list) and all(isinstance(x, str) and x for x in value),
                    f'{section}.{key} must be an array of nonempty strings')
        elif key == 'ls_specific_settings':
            require(isinstance(value, dict), f'{section}.{key} must be a table')
        elif key in {'min_files', 'max_languages'}:
            require(type(value) is int and value >= (1 if key == 'max_languages' else 0), f'Invalid {key}')
        elif key == 'tool_timeout':
            require(type(value) in (int, float) and math.isfinite(value) and value > 0, 'tool_timeout must be positive')
        elif key in {'read_only', 'hooks', 'auto_approve', 'skill', 'skill_global', 'per_project', 'detect',
                     'sync_languages', 'index', 'health_check', 'prepare_lsp', 'check_memories',
                     'web_dashboard', 'web_dashboard_open_on_launch', 'gui_log_window', 'trace_lsp_communication'}:
            require(type(value) is bool, f'{section}.{key} must be a boolean')
        else:
            require(isinstance(value, str), f'{section}.{key} must be a string')
        if key == 'clients':
            require(all(x in CLIENTS for x in value), 'Unknown client in configuration; use [] for no clients')
        if key == 'profile':
            require(value in ('minimal', 'standard', 'advanced'), 'Unknown bootstrap profile')
        if key == 'agent_interface':
            require(value.lower() in ('tools', 'repl'), 'agent_interface must be tools or repl')
        if key == 'language_backend':
            require(value in ('LSP', 'JetBrains'), 'language_backend must be LSP or JetBrains')
        if key == 'log_level':
            require(value in ('DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'), 'Invalid log_level')
        if key in {'context', 'initial_prompt_file'}:
            require(bool(value.strip()), f'{key} cannot be empty')

    if values.get('fixed_tools'):
        require(not values.get('excluded_tools') and not values.get('included_optional_tools'),
                'fixed_tools cannot be combined with tool inclusion/exclusion lists')


def merge(target, patch, sources, source, prefix=''):
    """Recursively merge maps; higher-layer lists replace lower-layer lists."""
    for key, value in patch.items():
        path = prefix + key
        if isinstance(value, dict) and value != INHERIT:
            if not isinstance(target.get(key), dict) or target.get(key) == INHERIT:
                target[key] = {}
            merge(target[key], value, sources, source, path + '.')
        else:
            target[key] = copy.deepcopy(value)
            # Replacing a parent must remove obsolete nested provenance.
            for old in list(sources):
                if old.startswith(path + '.'):
                    del sources[old]
            sources[path] = source


def normalize(document, base):
    require(isinstance(document, dict), 'Configuration must be a table')
    require(set(document) <= {'bootstrap', 'global', 'project', 'startup', 'presets'}, 'Unknown configuration section')
    result = copy.deepcopy(document)
    for section in ('bootstrap', 'global', 'project', 'startup'):
        values = result.get(section, {})
        validate_section(section, values)
        if isinstance(values.get('agent_interface'), str):
            values['agent_interface'] = 'REPL' if values['agent_interface'].lower() == 'repl' else 'tools'
        if section == 'startup':
            for key in ('modes', 'add_modes', 'context'):
                if key not in values:
                    continue
                def expand(value):
                    if '/' in value or value.endswith(('.yml', '.yaml')):
                        path = Path(value).expanduser()
                        return str((path if path.is_absolute() else base / path).resolve())
                    return value
                values[key] = [expand(x) for x in values[key]] if isinstance(values[key], list) else expand(values[key])
        if section == 'project':
            if 'initial_prompt_file' in values:
                require('initial_prompt' not in values, 'Use initial_prompt or initial_prompt_file, not both')
                path = Path(values.pop('initial_prompt_file')).expanduser()
                values['initial_prompt'] = (path if path.is_absolute() else base / path).read_text()
            for key in values.pop('inherit', []):
                require(key in PROJECT_KEYS - {'inherit', 'initial_prompt_file'}, f'Cannot inherit {key}')
                require(key not in values, f'{key} is both set and inherited')
                values[key] = copy.deepcopy(INHERIT)
        result[section] = values
    presets = result.get('presets', {})
    require(isinstance(presets, dict), 'presets must be a table')
    for name, preset in presets.items():
        require('presets' not in preset, f'Nested presets are not supported: {name}')
        presets[name] = normalize(preset, base)
        presets[name].pop('presets', None)
    return result


def parser():
    p = argparse.ArgumentParser(add_help=False, argument_default=argparse.SUPPRESS)
    p.add_argument('project_dir', nargs='?', default='.')
    p.add_argument('--config', action='append')
    p.add_argument('--no-config', action='store_true')
    p.add_argument('--preset')
    p.add_argument('--scope', choices=['project', 'global'], default='project')
    for flag in ['show-config', 'list-modes', 'list-contexts', 'dry-run', 'doctor', 'uninstall',
                 'purge', 'remove-tool', 'upgrade', 'reindex']:
        p.add_argument('--' + flag, action='store_true')
    p.add_argument('-y', '--yes', action='store_true')
    for key, positive, negative in [('detect', 'detect', 'no-detect'), ('index', 'index', 'no-index'),
            ('health_check', 'health-check', 'no-health-check'), ('prepare_lsp', 'prepare-lsp', 'no-prepare-lsp'),
            ('check_memories', 'check-memories', 'no-check-memories'), ('hooks', 'hooks', 'no-hooks'),
            ('skill', 'skill', 'no-skill'), ('skill_global', 'skill-global', 'skill-local'),
            ('per_project', 'per-project', 'user-registration'), ('auto_approve', 'auto-approve', 'no-auto-approve')]:
        p.add_argument('--' + positive, dest=key, action='store_true')
        p.add_argument('--' + negative, dest=key, action='store_false')
    p.add_argument('--sync-languages', action='store_true')
    p.add_argument('--profile', choices=['minimal', 'standard', 'advanced'])
    p.add_argument('--min-files', type=int)
    p.add_argument('--max-languages', type=int)
    p.add_argument('-n', '--name')
    for flags, dest in [(('-c', '--client'), 'clients'), (('-l', '--language'), 'languages'),
                        (('--ignore',), 'ignore'), (('--workspace',), 'workspace')]:
        p.add_argument(*flags, dest=dest, action='append')
    p.add_argument('--interface', dest='agent_interface', choices=['tools', 'repl', 'REPL'])
    p.add_argument('--backend', dest='language_backend', choices=['LSP', 'JetBrains'])
    p.add_argument('--jetbrains', dest='language_backend', action='store_const', const='JetBrains')
    p.add_argument('--read-only', dest='read_only', action='store_true')
    p.add_argument('--read-write', dest='read_only', action='store_false')
    for flag, dest in [('default-mode', 'default_modes'), ('add-mode', 'added_modes'), ('base-mode', 'base_modes'),
                       ('exclude-tool', 'excluded_tools'), ('include-tool', 'included_optional_tools'),
                       ('include-api', 'included_apis'), ('exclude-api', 'excluded_apis')]:
        p.add_argument('--' + flag, dest=dest, action='append')
    p.add_argument('--initial-prompt-file')
    p.add_argument('--set', action='append')
    p.add_argument('--clear', action='append')
    p.add_argument('--inherit', action='append')
    p.add_argument('--context')
    p.add_argument('--mode', dest='modes', action='append')
    p.add_argument('--startup-add-mode', dest='add_modes', action='append')
    p.add_argument('--tool-timeout', type=float)
    p.add_argument('--log-level')
    for key, positive, negative in [('web_dashboard', 'dashboard', 'no-dashboard'),
                                   ('web_dashboard_open_on_launch', 'open-dashboard', 'no-open-dashboard'),
                                   ('gui_log_window', 'gui-log-window', 'no-gui-log-window'),
                                   ('trace_lsp_communication', 'trace-lsp', 'no-trace-lsp')]:
        p.add_argument('--' + positive, dest=key, action='store_true')
        p.add_argument('--' + negative, dest=key, action='store_false')
    return p


def resolve(argv):
    cli = vars(parser().parse_args(argv))
    project = Path(cli['project_dir']).expanduser().resolve()
    require(project.is_dir(), f'Project directory not found: {project}')
    state = {'bootstrap': copy.deepcopy(DEFAULTS), 'project': {}, 'global': {},
             'startup': {'web_dashboard': True, 'web_dashboard_open_on_launch': False}, 'sources': {}}
    for section in ('bootstrap', 'startup'):
        state['sources'].update({f'{section}.{k}': 'built-in' for k in state[section]})
    files = []
    if not cli.get('no_config'):
        files = [Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home() / '.config'))) / 'serena-bootstrap/config.toml',
                 project / '.serena/bootstrap.toml']
    extra = [Path(x).expanduser().resolve() for x in cli.get('config', [])]
    require(all(x.is_file() for x in extra), '--config file does not exist')
    files += extra
    presets = {}
    preset_sources = {}
    for file in files:
        if not file.exists():
            continue
        with file.open('rb') as handle:
            doc = normalize(tomllib.load(handle), file.parent)
        merge(state, {k: doc[k] for k in ('bootstrap', 'global', 'project', 'startup')}, state['sources'], str(file))
        merge(presets, doc.get('presets', {}), preset_sources, str(file))
    if 'preset' in cli:
        name = cli['preset']
        require(name in presets, f'Unknown preset: {name}')
        # Presets apply after all file defaults, then the CLI applies last.
        merge(state, presets[name], state['sources'], f'preset:{name}')
        for key, source in preset_sources.items():
            if key.startswith(name + '.'):
                state['sources'][key[len(name) + 1:]] = f'preset:{name} ({source})'
    b = {k: cli[k] for k in DEFAULTS.keys() | {'index', 'health_check', 'prepare_lsp', 'check_memories'} if k in cli}
    if 'clients' in b:
        require(all(x in CLIENTS + ['none'] for x in b['clients']), 'Unknown client')
        require('none' not in b['clients'] or b['clients'] == ['none'], '--client none cannot be combined with other clients')
        b['clients'] = [x for x in b['clients'] if x != 'none']
    settings = {k: cli[k] for k in PROJECT_KEYS | GLOBAL_KEYS if k in cli and k not in STARTUP_KEYS and k != 'inherit'}
    # Interface/backend are persisted at the chosen scope; server-only CLI options go to startup.
    for key in ('agent_interface', 'language_backend'):
        if key in cli:
            settings[key] = cli[key]
    for item in cli.get('set', []):
        key, sep, value = item.partition('=')
        require(bool(sep), '--set requires KEY=JSON')
        require(key not in settings, f'Duplicate CLI setting: {key}')
        settings[key] = json.loads(value)
    for key in cli.get('clear', []):
        require(key in LIST_KEYS, '--clear requires a list setting')
        require(key not in settings, f'Duplicate CLI setting: {key}')
        settings[key] = []
    for key in cli.get('inherit', []):
        require(cli['scope'] == 'project', '--inherit is project-only')
        require(key in PROJECT_KEYS - {'inherit', 'initial_prompt_file'}, f'Cannot inherit {key}')
        require(key not in settings, f'Duplicate CLI setting: {key}')
        settings[key] = copy.deepcopy(INHERIT)
    doc = normalize({cli['scope']: settings}, Path.cwd())
    merge(state, {'bootstrap': b, cli['scope']: doc[cli['scope']]}, state['sources'], 'CLI')
    startup = {k: cli[k] for k in STARTUP_KEYS - {'agent_interface', 'language_backend'} if k in cli}
    startup = normalize({'startup': startup}, Path.cwd())['startup']
    merge(state, {'startup': startup}, state['sources'], 'CLI')
    for section in ('bootstrap', 'project', 'global', 'startup'):
        validate_section(section, state[section])
    b = state['bootstrap']
    if b['auto_approve']:
        require(not ('hooks' in cli and not cli['hooks']), '--auto-approve requires hooks')
        b['hooks'] = True
        state['sources']['bootstrap.hooks'] = 'auto_approve'
    # Resolve profile-derived actions once, with explicit values taking precedence.
    for key, default in dict(index=b['profile'] != 'minimal', health_check=b['profile'] != 'minimal',
                             prepare_lsp=b['profile'] == 'advanced', check_memories=b['profile'] == 'advanced').items():
        if key not in b:
            b[key] = default
            state['sources']['bootstrap.' + key] = 'profile:' + b['profile']
    args = ['--profile', b['profile'], '--min-files', str(b['min_files']), '--max-languages', str(b['max_languages'])]
    for key, positive, negative in [('detect', None, '--no-detect'), ('index', '--index', '--no-index'),
            ('health_check', '--health-check', '--no-health-check'), ('prepare_lsp', '--prepare-lsp', '--no-prepare-lsp'),
            ('check_memories', '--check-memories', '--no-check-memories'), ('hooks', '--hooks', None),
            ('skill', None, '--no-skill'), ('skill_global', '--skill-global', None),
            ('per_project', '--per-project', None), ('auto_approve', '--auto-approve', None)]:
        flag = positive if b[key] else negative
        if flag:
            args.append(flag)
    for key, flag in [('clients', '--client'), ('languages', '--language'), ('ignore', '--ignore'), ('workspace', '--workspace')]:
        values = b[key]
        if key == 'clients':
            # Preserve legacy uninstall's all-clients default when no layer selected clients.
            if cli.get('uninstall') and state['sources']['bootstrap.clients'] == 'built-in':
                values = CLIENTS
            elif not values:
                values = ['none']
        for value in values:
            args += [flag, value]
    if b['name']:
        args += ['--name', b['name']]
    if b['sync_languages']:
        args.append('--sync-languages')
    for flag in ('dry_run', 'doctor', 'uninstall', 'purge', 'remove_tool', 'upgrade', 'reindex', 'yes'):
        if cli.get(flag):
            args.append('--' + flag.replace('_', '-'))
    args += ['--', str(project)]
    state['args'] = args
    state['project_dir'] = str(project)
    state['actions'] = {k: cli.get(k, False) for k in ('show_config', 'list_modes', 'list_contexts')}
    return state


def yaml_parser():
    from ruamel.yaml import YAML
    y = YAML()
    y.preserve_quotes = True
    y.width = 4096
    return y


def write_atomic(path, text):
    if path.exists() and path.read_text() == text:
        return False
    if path.exists():
        backup = path.with_name(path.name + f'.bak.{time.time_ns()}')
        shutil.copy2(path, backup)
    fd, temp = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as out:
            out.write(text)
            out.flush()
            os.fsync(out.fileno())
        if path.exists():
            shutil.copymode(path, temp)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
    return True


def patch_yaml(path, patch, dry=False, inherit_defaults=None):
    """Round-trip a mapping, keeping comments and keys outside the requested patch."""
    y = yaml_parser()
    path = Path(path)
    data = y.load(path.read_text()) if path.exists() else {}
    require(isinstance(data, dict), f'YAML must be a mapping: {path}')
    before = copy.deepcopy(data)

    def update(node, changes):
        for key, value in changes.items():
            if value == INHERIT:
                if inherit_defaults is not None and key in inherit_defaults:
                    node[key] = copy.deepcopy(inherit_defaults[key])
                else:
                    node.pop(key, None)
            elif isinstance(value, dict):
                if not isinstance(node.get(key), dict):
                    node[key] = {}
                update(node[key], value)
            else:
                node[key] = value
    update(data, patch)
    if data == before:
        return False
    buf = io.StringIO()
    y.dump(data, buf)
    if dry:
        import difflib
        original = path.read_text() if path.exists() else ''
        print(''.join(difflib.unified_diff(original.splitlines(True), buf.getvalue().splitlines(True),
                                         fromfile=str(path), tofile=str(path))), end='')
    else:
        require(path.exists(), f'Config not found: {path}')
        write_atomic(path, buf.getvalue())
    return True


def validate_capabilities(state, help_text, resource_dir):
    # Validate against the installed version, not only the downloaded docs.
    y = yaml_parser()
    for file in [Path(os.environ.get('SERENA_HOME', str(Path.home() / '.serena'))) / 'serena_config.yml',
                 Path(state['project_dir']) / '.serena/project.yml']:
        if file.exists():
            current = y.load(file.read_text())
            require(isinstance(current, dict), f'YAML must be a mapping: {file}')
            section = 'global' if file.name == 'serena_config.yml' else 'project'
            future = dict(current)
            future.update(state[section])
            if future.get('fixed_tools') and future['fixed_tools'] != INHERIT:
                require(not future.get('excluded_tools') and not future.get('included_optional_tools'),
                        f'fixed_tools conflicts with tool inclusion/exclusion lists in {file}')
    templates = {'global': 'serena_config.template.yml', 'project': 'project.template.yml'}
    for section, template in templates.items():
        supported = y.load((Path(resource_dir) / template).read_text())
        for key in state[section]:
            require(key in supported, f'Installed Serena does not support {section}.{key}')
    if 'context' in state['startup']:
        require('--context' in help_text, 'Installed Serena does not support --context')
    # Do not instantiate SerenaPaths: it creates directories even in dry-run.
    user_home = Path(os.environ.get('SERENA_HOME', str(Path.home() / '.serena')))
    def validate_definition(name, kind, allow_path=False):
        candidates = [user_home / kind / (name + '.yml'), Path(resource_dir) / 'config' / kind / (name + '.yml')]
        if allow_path and Path(name).is_file():
            candidates.insert(0, Path(name))
        file = next((p for p in candidates if p.is_file()), None)
        require(file is not None, f'Unknown Serena {kind[:-1]}: {name}')
        definition = y.load(file.read_text())
        require(isinstance(definition, dict), f'{kind[:-1]} must contain a YAML mapping: {file}')
        from serena.config.context_mode import SerenaAgentMode, SerenaAgentContext
        loader = SerenaAgentMode if kind == 'modes' else SerenaAgentContext
        loader.from_yaml(file)
    for section in ('global', 'project'):
        for key in ('base_modes', 'default_modes', 'added_modes'):
            value = state[section].get(key, [])
            if value == INHERIT:
                continue
            for name in value:
                validate_definition(name, 'modes')
    for key in ('modes', 'add_modes'):
        for name in state['startup'].get(key, []):
            validate_definition(name, 'modes', allow_path=True)
    if 'context' in state['startup']:
        validate_definition(state['startup']['context'], 'contexts', allow_path=True)
    for flag in server_args(state):
        if flag.startswith('--'):
            require(flag in help_text, f'Installed Serena does not support {flag}')


def server_args(state):
    s = state['startup']
    args = []
    flags = {'agent_interface': '--agent-interface', 'language_backend': '--language-backend',
             'tool_timeout': '--tool-timeout', 'log_level': '--log-level', 'web_dashboard': '--enable-web-dashboard',
             'web_dashboard_open_on_launch': '--open-web-dashboard', 'gui_log_window': '--enable-gui-log-window',
             'trace_lsp_communication': '--trace-lsp-communication'}
    for key, flag in flags.items():
        if key in s:
            args += [flag, str(s[key]).lower() if isinstance(s[key], bool) else str(s[key])]
    for key, flag in [('modes', '--mode'), ('add_modes', '--add-mode')]:
        for value in s.get(key, []):
            args += [flag, value]
    return args


def main():
    command, *argv = sys.argv[1:]
    if command == 'resolve':
        print(json.dumps(resolve(argv)))
        return
    if command == 'claude-user-status':
        path, executable, *wanted = argv
        file = Path(path)
        if not file.exists():
            sys.exit(1)
        try:
            data = json.loads(file.read_text())
            found = data.get('mcpServers', {}).get('serena')
            if found is None:
                sys.exit(1)
            require(isinstance(found, dict), 'Invalid Claude MCP registration')
            sys.exit(0 if found.get('command') in (executable, 'serena') and found.get('args') == wanted else 2)
        except (ValueError, AttributeError):
            sys.exit(3)
    if command == 'edit-yaml':
        op, filename, *rest = argv
        dry = '--dry-run' in rest[:1]
        args = rest[rest.index('--') + 1:]
        y = yaml_parser()
        path = Path(filename)
        data = y.load(path.read_text()) if path.exists() else {}
        require(isinstance(data, dict), f'YAML must be a mapping: {path}')
        if op == 'scalar':
            key, value = args
            patch = {key: y.load(value)}
        elif op in ('list', 'replace-list'):
            key, *items = args
            current = data.get(key) or []
            require(isinstance(current, list), f'{key} must be a list')
            patch = {key: list(dict.fromkeys((current if op == 'list' else []) + items))}
        elif op == 'languages':
            current = (data.get('languages') or []) + (data.get('language_servers') or [])
            require(isinstance(current, list), 'language servers must be a list')
            patch = {'languages': INHERIT, 'language_servers': list(dict.fromkeys(current + args))}
        else:
            raise ValueError(f'Unsupported YAML operation: {op}')
        changed = patch_yaml(path, patch, dry)
        if not dry:
            print(f"{'Updated' if changed else 'Unchanged'}: {path}")
        return
    state = json.loads(argv[0])
    if command in ('args', 'server-args'):
        values = state['args'] if command == 'args' else server_args(state)
        for value in values:
            sys.stdout.buffer.write(value.encode() + b'\0')
    elif command == 'show':
        print(json.dumps({k: v for k, v in state.items() if k not in ('args', 'actions')}, indent=2))
    elif command == 'action':
        sys.exit(0 if state['actions'][argv[1]] else 1)
    elif command == 'context':
        print(state['startup'].get('context', argv[1]))
    elif command == 'preview':
        print('[dry-run] Requested persistent settings:')
        print(json.dumps({'global': state['global'], 'project': state['project']}, indent=2))
    elif command == 'backend-requested':
        print(next((state[s]['language_backend'] for s in ('startup', 'project', 'global')
                    if isinstance(state[s].get('language_backend'), str)), 'LSP'))
    elif command == 'backend':
        y = yaml_parser()
        project_file = Path(state['project_dir']) / '.serena/project.yml'
        global_file = Path(argv[1])
        project = y.load(project_file.read_text()) if project_file.exists() else {}
        glob = y.load(global_file.read_text()) if global_file.exists() else {}
        for section, values in [('project', project), ('global', glob)]:
            if 'language_backend' in state[section]:
                value = state[section]['language_backend']
                if value == INHERIT:
                    values.pop('language_backend', None)
                else:
                    values['language_backend'] = value
        local_file = project_file.with_name('project.local.yml')
        local = y.load(local_file.read_text()) if local_file.exists() else {}
        print(state['startup'].get('language_backend') or local.get('language_backend') or project.get('language_backend') or glob.get('language_backend') or 'LSP')
    elif command == 'scope-changed':
        file = Path(state['project_dir']) / '.serena/project.yml'
        if not file.exists():
            sys.exit(0)
        current = yaml_parser().load(file.read_text())
        for key in ('ignored_paths', 'ls_workspace_folders'):
            if key in state['project']:
                value = state['project'][key]
                if value == INHERIT:
                    import serena
                    defaults = yaml_parser().load((Path(serena.__file__).parent / 'resources/project.template.yml').read_text())
                    value = defaults[key]
                if value != current.get(key):
                    sys.exit(0)
        sys.exit(1)
    elif command == 'apply':
        root = Path(state['project_dir'])
        for section, path in [('global', Path(argv[1])), ('project', root / '.serena/project.yml')]:
            if state[section]:
                settings = copy.deepcopy(state[section])
                if section == 'global' and 'log_level' in settings:
                    import logging
                    settings['log_level'] = getattr(logging, settings['log_level'])
                import serena
                template = 'project.template.yml' if section == 'project' else 'serena_config.template.yml'
                defaults = yaml_parser().load((Path(serena.__file__).parent / 'resources' / template).read_text())
                patch_yaml(path, settings, '--dry-run' in argv, inherit_defaults=defaults)
    elif command == 'validate':
        import serena
        resources = Path(serena.__file__).parent / 'resources'
        validate_capabilities(state, Path(argv[1]).read_text(), resources)
    else:
        raise ValueError(f'Unknown helper operation: {command}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, ImportError, TypeError) as exc:
        print(f'Configuration error: {exc}', file=sys.stderr)
        sys.exit(1)
