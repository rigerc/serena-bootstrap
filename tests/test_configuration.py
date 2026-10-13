"""Configuration contract tests: isolated files and stub clients, no user writes."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bootstrap_config', ROOT / 'bootstrap_config.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / 'project with spaces'
        self.project.mkdir()
        self.user = self.root / 'config/serena-bootstrap'
        self.user.mkdir(parents=True)
        self.env = patch.dict(os.environ, {'XDG_CONFIG_HOME': str(self.root / 'config')})
        self.env.start()
        self.addCleanup(self.env.stop)

    def resolve(self, *args):
        return c.resolve([*args, str(self.project)])

    def test_precedence_and_list_replacement(self):
        (self.user / 'config.toml').write_text('[bootstrap]\nclients=["claude-code", "codex"]\nhooks=true\n[project]\ndefault_modes=["interactive", "editing"]\n')
        folder = self.project / '.serena'
        folder.mkdir()
        (folder / 'bootstrap.toml').write_text('[bootstrap]\nclients=["pi"]\nhooks=false\n[project]\ndefault_modes=[]\n')
        state = self.resolve('--client', 'grok', '--client', 'codex')
        self.assertEqual(state['bootstrap']['clients'], ['grok', 'codex'])
        self.assertFalse(state['bootstrap']['hooks'])
        self.assertEqual(state['project']['default_modes'], [])
        self.assertEqual(state['sources']['bootstrap.clients'], 'CLI')
        self.assertIn('bootstrap.toml', state['sources']['project.default_modes'])

    def test_explicit_config_and_no_config(self):
        (self.user / 'config.toml').write_text('[bootstrap]\nhooks=true\n')
        extra = self.root / 'extra.toml'
        extra.write_text('[bootstrap]\nprofile="minimal"\n')
        state = self.resolve('--no-config', '--config', str(extra))
        self.assertFalse(state['bootstrap']['hooks'])
        self.assertFalse(state['bootstrap']['index'])
        self.assertFalse(state['bootstrap']['health_check'])

    def test_preset_cli_override_and_nested_merge(self):
        (self.user / 'config.toml').write_text('''[bootstrap]
profile="standard"
[project.ls_specific_settings.python]
python_path="python3"
[presets.review.project]
default_modes=["planning", "one-shot"]
read_only=true
[presets.review.project.ls_specific_settings.python]
request_timeout=90
''')
        state = self.resolve('--preset', 'review', '--read-write')
        self.assertFalse(state['project']['read_only'])
        self.assertEqual(state['project']['default_modes'], ['planning', 'one-shot'])
        self.assertEqual(state['project']['ls_specific_settings']['python'], {'python_path': 'python3', 'request_timeout': 90})

    def test_profiles_preserve_explicit_false_and_true(self):
        state = self.resolve('--profile', 'advanced', '--no-check-memories', '--no-prepare-lsp')
        self.assertIn('--no-check-memories', state['args'])
        self.assertFalse(state['bootstrap']['check_memories'])
        state = self.resolve('--profile', 'minimal', '--index', '--health-check')
        self.assertTrue(state['bootstrap']['index'])
        self.assertIn('--index', state['args'])

    def test_modes_have_distinct_semantics(self):
        state = self.resolve('--scope', 'global', '--base-mode', 'no-onboarding',
                             '--default-mode', 'editing', '--mode', 'planning', '--startup-add-mode', 'one-shot')
        self.assertEqual(state['global']['base_modes'], ['no-onboarding'])
        self.assertEqual(state['global']['default_modes'], ['editing'])
        self.assertEqual(c.server_args(state)[-4:], ['--mode', 'planning', '--add-mode', 'one-shot'])
        self.assertEqual(state['project'], {})

    def test_typed_set_clear_and_inherit(self):
        state = self.resolve('--set', 'read_only=false', '--clear', 'default_modes', '--inherit', 'agent_interface')
        self.assertIs(state['project']['read_only'], False)
        self.assertEqual(state['project']['default_modes'], [])
        self.assertEqual(state['project']['agent_interface'], c.INHERIT)

    def test_prompt_and_custom_paths_relative_to_config(self):
        (self.user / 'prompt.txt').write_text('Read the coding conventions.\n')
        (self.user / 'mode.yml').write_text('prompt: review\n')
        (self.user / 'config.toml').write_text('[project]\ninitial_prompt_file="prompt.txt"\n[startup]\nmodes=["mode.yml"]\n')
        state = self.resolve()
        self.assertEqual(state['project']['initial_prompt'], 'Read the coding conventions.\n')
        self.assertEqual(state['startup']['modes'], [str(self.user / 'mode.yml')])

    def test_invalid_types_keys_and_scopes(self):
        for args in [('--base-mode', 'no-onboarding'), ('--set', 'read_only="false"'),
                     ('--scope', 'global', '--read-only'), ('--tool-timeout', 'nan'),
                     ('--clear', 'read_only'), ('--set', 'typo=true'),
                     ('--client', 'none', '--client', 'codex'), ('--preset', 'missing')]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                self.resolve(*args)
        (self.user / 'config.toml').write_text('[bootstrap]\nhooks="false"\n')
        with self.assertRaises(ValueError):
            self.resolve()

    def test_cli_values_are_data_not_shell(self):
        payload = '$(touch ' + str(self.root / 'oops') + ')\nquoted " value'
        state = self.resolve('--set', 'initial_prompt=' + json.dumps(payload))
        self.assertEqual(state['project']['initial_prompt'], payload)
        self.assertFalse((self.root / 'oops').exists())

    def test_round_trip_nested_settings_and_repeat_stability(self):
        file = self.root / 'project.yml'
        original = '''# Project comment
project_name: "my-project" # keep
read_only: false
ls_specific_settings:
  python:
    python_path: "python3" # keep interpreter
    request_timeout: 30
default_modes: [interactive, editing] # mode comment
initial_prompt: |
  Existing multiline prompt.
'''
        file.write_text(original)
        wanted = {'read_only': True, 'default_modes': [],
                  'ls_specific_settings': {'python': {'request_timeout': 90}}}
        self.assertTrue(c.patch_yaml(file, wanted))
        result = file.read_text()
        self.assertIn('# Project comment', result)
        self.assertIn('# keep interpreter', result)
        self.assertIn('Existing multiline prompt.', result)
        self.assertEqual(c.yaml_parser().load(result)['default_modes'], [])
        backups = list(self.root.glob('project.yml.bak.*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), original)
        self.assertFalse(c.patch_yaml(file, wanted))
        self.assertEqual(file.read_text(), result)
        self.assertEqual(len(list(self.root.glob('project.yml.bak.*'))), 1)
        c.patch_yaml(file, {'default_modes': c.INHERIT})
        self.assertNotIn('default_modes', c.yaml_parser().load(file.read_text()))

    def test_dry_run_diff_and_invalid_yaml_do_not_write(self):
        file = self.root / 'project.yml'
        file.write_text('read_only: false\n')
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertTrue(c.patch_yaml(file, {'read_only': True}, dry=True))
        self.assertIn('+read_only: true', output.getvalue())
        self.assertEqual(file.read_text(), 'read_only: false\n')
        self.assertFalse(list(self.root.glob('*.bak.*')))
        file.write_text('read_only: false\nread_only: true\n')
        with self.assertRaises(Exception):
            c.patch_yaml(file, {'read_only': False})
        self.assertEqual(file.read_text(), 'read_only: false\nread_only: true\n')

    def make_stubs(self):
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        (bin_dir / 'python').write_text('#!/bin/sh\nexec ' + sys.executable + ' \"$@\"\n')
        (bin_dir / 'python').chmod(0o755)
        code = '''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
name = pathlib.Path(sys.argv[0]).name
with open(os.environ['CALL_LOG'], 'a') as out:
    out.write(json.dumps([name, *args]) + '\\n')
if name == 'uv':
    if args[:2] == ['tool', 'list']: print('serena-agent v2.0')
    elif args[:3] == ['tool', 'dir', '--bin']: print(pathlib.Path(sys.argv[0]).parent)
elif name == 'serena':
    if args[:2] == ['start-mcp-server', '--help']:
        print('--context --mode --add-mode --language-backend --agent-interface --tool-timeout --log-level --enable-web-dashboard --open-web-dashboard --enable-gui-log-window --trace-lsp-communication')
    elif args == ['init']:
        p = pathlib.Path(os.environ['SERENA_HOME']) / 'serena_config.yml'
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text('language_backend: LSP\\nweb_dashboard: true\\nweb_dashboard_open_on_launch: true\\n')
    elif args[:2] == ['project', 'create']:
        p = pathlib.Path(args[-1]) / '.serena/project.yml'
        p.parent.mkdir(exist_ok=True)
        p.write_text('project_name: test\\nlanguage_backend: null\\ndefault_modes: null\\nread_only: false\\n')
'''
        for name in ['uv', 'serena', 'claude', 'codex', 'grok', 'codebuddy', 'opencode', 'pi']:
            file = bin_dir / name
            file.write_text(code)
            file.chmod(0o755)
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                   HOME=str(self.root / 'home'), SERENA_HOME=str(self.root / 'serena'),
                   CALL_LOG=str(self.root / 'calls.jsonl'))
        (self.root / 'home').mkdir()
        return env

    def run_script(self, env, *args):
        return subprocess.run(['bash', str(ROOT / 'serena.sh'), '--no-config', '--no-skill',
                               '--no-detect', *args, str(self.project)], env=env, capture_output=True, text=True)

    def test_all_clients_receive_same_startup_options(self):
        env = self.make_stubs()
        args = []
        for client in c.CLIENTS:
            args += ['--client', client]
        result = self.run_script(env, '--profile', 'minimal', '--mode', 'planning',
                                 '--startup-add-mode', 'one-shot', '--context', 'ide', '--tool-timeout', '120',
                                 '--read-only', *args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in Path(env['CALL_LOG']).read_text().splitlines()]
        registrations = [x for x in calls if x[0] != 'serena' and x[1:3] == ['mcp', 'add']]
        self.assertEqual(len(registrations), 6)
        for call in registrations:
            self.assertIn('planning', call)
            self.assertIn('one-shot', call)
            self.assertIn('--enable-web-dashboard', call)
            self.assertIn('--tool-timeout', call)
            self.assertEqual(call[call.index('--context') + 1], 'ide')
        self.assertTrue(c.yaml_parser().load((self.project / '.serena/project.yml').read_text())['read_only'])
        # Default runtime dashboard preferences must not rewrite global preferences.
        global_settings = c.yaml_parser().load((Path(env['SERENA_HOME']) / 'serena_config.yml').read_text())
        self.assertTrue(global_settings['web_dashboard_open_on_launch'])

    def test_shell_profile_false_is_honored(self):
        env = self.make_stubs()
        result = self.run_script(env, '--profile', 'advanced', '--no-check-memories', '--no-prepare-lsp', '--client', 'none')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = Path(env['CALL_LOG']).read_text()
        self.assertNotIn('download-ls-dependencies', calls)
        self.assertNotIn('memories', calls)
        self.assertIn('health-check', calls)

    def test_shell_dry_run_writes_no_configs_or_client_registrations(self):
        env = self.make_stubs()
        result = self.run_script(env, '--dry-run', '--default-mode', 'planning', '--client', 'codex')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.project / '.serena').exists())
        self.assertFalse(Path(env['SERENA_HOME']).exists())
        self.assertIn('+default_modes:', result.stdout)
        calls = [json.loads(line) for line in Path(env['CALL_LOG']).read_text().splitlines()]
        self.assertFalse(any(x[1:3] == ['mcp', 'add'] for x in calls))

    def test_shell_invalid_mode_fails_before_config_writes(self):
        env = self.make_stubs()
        result = self.run_script(env, '--mode', 'nonexistent-mode', '--client', 'none')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.project / '.serena').exists())
        self.assertFalse(Path(env['SERENA_HOME']).exists())

    def test_inheritance_reset_is_stable_with_native_project_defaults(self):
        env = self.make_stubs()
        result = self.run_script(env, '--profile', 'minimal', '--client', 'none', '--default-mode', 'editing')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_script(env, '--profile', 'minimal', '--client', 'none', '--inherit', 'default_modes')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        file = self.project / '.serena/project.yml'
        self.assertIsNone(c.yaml_parser().load(file.read_text())['default_modes'])
        backups = list(file.parent.glob('project.yml.bak.*'))
        before = file.read_text()
        result = self.run_script(env, '--profile', 'minimal', '--client', 'none', '--inherit', 'default_modes')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(file.read_text(), before)
        self.assertEqual(len(list(file.parent.glob('project.yml.bak.*'))), len(backups))

    def test_global_settings_remain_separate_from_project(self):
        env = self.make_stubs()
        result = self.run_script(env, '--profile', 'minimal', '--client', 'none', '--scope', 'global',
                                 '--base-mode', 'no-onboarding', '--set', 'log_level="DEBUG"', '--set', 'tool_timeout=300')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        glob = c.yaml_parser().load((Path(env['SERENA_HOME']) / 'serena_config.yml').read_text())
        self.assertEqual(glob['log_level'], 10)
        self.assertEqual(glob['tool_timeout'], 300)
        self.assertEqual(glob['base_modes'], ['no-onboarding'])
        project = c.yaml_parser().load((self.project / '.serena/project.yml').read_text())
        self.assertNotIn('tool_timeout', project)
        self.assertNotIn('base_modes', project)

    def test_local_backend_override_is_honored(self):
        env = self.make_stubs()
        folder = self.project / '.serena'
        folder.mkdir()
        (folder / 'project.yml').write_text('project_name: test\nlanguage_backend: LSP\n')
        (folder / 'project.local.yml').write_text('language_backend: JetBrains\n')
        result = self.run_script(env, '--profile', 'advanced', '--client', 'none')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = Path(env['CALL_LOG']).read_text()
        self.assertNotIn('health-check', calls)
        self.assertNotIn('"project", "index"', calls)
        self.assertNotIn('download-ls-dependencies', calls)

    def test_no_serena_dry_run_can_preview_first_install(self):
        env = self.make_stubs()
        (self.root / 'bin/serena').unlink()
        # Existing system Serena must also be hidden; expose only utilities needed for preview.
        import shutil
        for name in ['python3', 'bash', 'dirname', 'readlink', 'grep', 'cat']:
            file = self.root / 'bin' / name
            if not file.exists():
                file.symlink_to(shutil.which(name))
        env['PATH'] = str(self.root / 'bin')
        env['BASH_ENV'] = ''
        result = self.run_script(env, '--dry-run', '--default-mode', 'planning', '--client', 'none')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('without YAML diffs', result.stderr)
        self.assertFalse((self.project / '.serena').exists())
        self.assertFalse(Path(env['SERENA_HOME']).exists())

    def test_symlink_entry_finds_helper(self):
        link = self.root / 'entry.sh'
        link.symlink_to(ROOT / 'serena.sh')
        result = subprocess.run(['bash', str(link), '--no-config', '--show-config', '--client', 'none', str(self.project)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['bootstrap']['clients'], [])

    def test_scope_change_triggers_reindex_on_existing_project(self):
        env = self.make_stubs()
        folder = self.project / '.serena'
        folder.mkdir()
        (folder / 'project.yml').write_text('project_name: test\nlanguage_backend: LSP\nignored_paths: []\n')
        result = self.run_script(env, '--client', 'none', '--set', 'ignored_paths=["generated/**"]')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('"project", "index"', Path(env['CALL_LOG']).read_text())
        Path(env['CALL_LOG']).write_text('')
        result = self.run_script(env, '--client', 'none', '--set', 'ignored_paths=["generated/**"]')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('"project", "index"', Path(env['CALL_LOG']).read_text())

    def test_shell_claude_repeat_skips_matching_registration(self):
        env = self.make_stubs()
        result = self.run_script(env, '--profile', 'minimal', '--per-project', '--default-mode', 'editing')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in Path(env['CALL_LOG']).read_text().splitlines()]
        call = next(x for x in calls if x[0] == 'claude' and x[1:3] == ['mcp', 'add'])
        index = call.index('--')
        (self.project / '.mcp.json').write_text(json.dumps({'mcpServers': {'serena': {'command': call[index+1], 'args': call[index+2:]}}}))
        Path(env['CALL_LOG']).write_text('')
        result = self.run_script(env, '--profile', 'minimal', '--per-project', '--default-mode', 'editing')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('"claude", "mcp", "add"', Path(env['CALL_LOG']).read_text())
        self.assertFalse(list((self.project / '.serena').glob('*.bak.*'))[1:])


if __name__ == '__main__':
    unittest.main()
