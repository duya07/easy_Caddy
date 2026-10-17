#!/usr/bin/env python3
"""Independent Linux certificate/export/editor acceptance tests.

Real Caddy adapt/validate and OpenSSL; mocked service manager and fault injection.
All mutations stay in a unique /tmp run tree. Python is a development dependency.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

DOMAIN = 'target.test'
OTHER = 'other.test'
INTERFACES = ['certificate_storage_root', 'list_certificates',
              'set_certificate_export_directory', 'register_certificate_export',
              'unregister_certificate_export', 'sync_certificates',
              'install_certificate_sync_timer', 'manual_edit_caddyfile',
              'apply_manual_caddyfile']


def q(value):
    return shlex.quote(str(value))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record_tree(root):
    """Record identities and hashes, never embed private key bodies in JSON."""
    result = {}
    if not root.exists() and not root.is_symlink():
        return result
    for path in [root] + sorted(root.rglob('*')) if root.is_dir() and not root.is_symlink() else [root]:
        st = path.lstat()
        item = {'mode': oct(st.st_mode & 0o7777), 'uid': st.st_uid, 'gid': st.st_gid,
                'mtime_ns': st.st_mtime_ns, 'nlink': st.st_nlink}
        if path.is_symlink():
            item.update(type='symlink', target=os.readlink(path))
        elif path.is_file():
            item.update(type='file', sha256=digest(path), bytes=st.st_size)
        elif path.is_dir():
            item.update(type='directory')
        else:
            item.update(type='other')
        result[str(path.relative_to(root)) if path != root else '.'] = item
    return result


class ProductFailure(AssertionError):
    pass


# The wrapper itself is an independent test artifact, not product code.
# None of these service commands reaches the host service manager.
WRAPPER = r'''#!/usr/bin/python3
import json, os, pathlib, shutil, subprocess, sys, time
root = pathlib.Path(os.environ['TEST_ROOT'])
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
trace = root / 'trace.jsonl'
def log(event, **fields):
    with trace.open('a') as out:
        out.write(json.dumps(dict(event=event, tool=tool, argv=args, **fields)) + '\n')
def fail(message, code=90):
    log('blocked', reason=message)
    print(message, file=sys.stderr)
    sys.exit(code)
log('call')
if tool in ('apt', 'apt-get', 'yum', 'dnf', 'curl', 'wget', 'service', 'docker'):
    fail('external operation prohibited by acceptance harness')
if tool == 'sudo':
    while args and args[0] in ('--', '-n', '-E'):
        args.pop(0)
    if not args:
        fail('empty sudo invocation')
    sys.exit(subprocess.call(args, close_fds=False))
if tool == 'systemctl':
    action = next((x for x in args if not x.startswith('-')), '')
    if action == 'show':
        values = {'User': os.environ.get('TEST_SERVICE_USER', 'caddy'),
                  'MainPID': os.environ.get('TEST_SERVICE_PID', '0'),
                  'Environment': '' if os.environ.get('TEST_UNCERTAIN_HOME') else 'HOME=' + str(root / 'service-home'),
                  'EnvironmentFiles': os.environ.get('TEST_ENVIRONMENT_FILES', '')}
        prop = None
        for i, arg in enumerate(args):
            if arg in ('-p', '--property') and i + 1 < len(args):
                prop = args[i + 1]
            elif arg.startswith('--property='):
                prop = arg.split('=', 1)[1]
        if prop and ',' not in prop:
            print(values.get(prop, '') if '--value' in args else prop + '=' + values.get(prop, ''))
        else:
            for key, value in values.items():
                print(key + '=' + value)
        sys.exit(0)
    if action in ('is-active', 'status'):
        print('active' if os.environ.get('TEST_SERVICE_PID', '0') != '0' else 'inactive')
        sys.exit(0 if os.environ.get('TEST_SERVICE_PID', '0') != '0' else 3)
    if action == 'cat':
        print('[Service]\nUser=' + os.environ.get('TEST_SERVICE_USER', 'caddy') + ('\nEnvironment=HOME=' + str(root / 'service-home') if not os.environ.get('TEST_UNCERTAIN_HOME') else ''))
        sys.exit(0)
    if action in ('daemon-reload', 'enable', 'disable', 'start', 'stop', 'reset-failed', 'is-enabled'):
        # Only the export worker may be installed/disabled; never alter Caddy.
        if any(x in ('caddy', 'caddy.service') for x in args) and action not in ('is-enabled',):
            fail('attempt to alter Caddy service')
        if os.environ.get('TEST_FAULT') == 'timer' and action == 'enable':
            log('fault', kind='timer-install')
            sys.exit(78)
        sys.exit(0)
    if action == 'reload':
        counter = root / 'reload-count'
        count = int(counter.read_text()) + 1 if counter.exists() else 1
        counter.write_text(str(count))
        fault = os.environ.get('TEST_FAULT', '')
        if fault == 'reload-external' and count == 1:
            shutil.copyfile(root / 'external.caddy', root / 'Caddyfile')
            log('fault', kind='reload-external')
            sys.exit(77)
        if fault == 'reload-always' or (fault == 'reload-once' and count == 1):
            log('fault', kind='reload', attempt=count)
            sys.exit(77)
        sys.exit(0)
    fail('unexpected systemctl action: ' + action)
if tool == 'journalctl':
    print('fixture journal target.test: certificate pending / synchronised')
    sys.exit(0)
real = json.loads((root / 'real-tools.json').read_text())[tool]
if tool == 'flock':
    # Preserve inherited Bash exec {fd}> locks; subprocess close_fds breaks them.
    os.execv(real, [real] + args)
if tool == 'caddy':
    if not args or args[0] not in ('validate', 'adapt', 'version', 'list-modules', 'environ'):
        fail('Caddy daemon/reload operations prohibited')
    if '--config' in args:
        config = pathlib.Path(args[args.index('--config') + 1])
        if not config.is_relative_to(root):
            fail('Caddy config is outside isolated case')
    if args and args[0] == 'adapt' and os.environ.get('TEST_ADAPT_JSON'):
        log('simulated-adapt', fixture=os.environ['TEST_ADAPT_JSON'])
        print(pathlib.Path(os.environ['TEST_ADAPT_JSON']).read_text())
        sys.exit(0)
    code = subprocess.call([real] + args, close_fds=False)
    if args and args[0] == 'validate' and os.environ.get('TEST_FAULT') == 'validate':
        log('fault', kind='validate-after-real-validator', real_exit=code)
        sys.exit(79)
    sys.exit(code)
if tool == 'openssl':
    if args and args[0] == 'pkey':
        if os.environ.get('TEST_BLOCK_OPENSSL') == '1' and not (root / 'block-active').exists():
            (root / 'block-active').touch()
            deadline = time.monotonic() + 12
            while not (root / 'block-release').exists() and time.monotonic() < deadline:
                time.sleep(.02)
            if not (root / 'block-release').exists():
                fail('test synchronisation barrier expired', 91)
        rotate = os.environ.get('TEST_ROTATE_KEY')
        if rotate and not (root / 'rotation-used').exists():
            shutil.copyfile(rotate, os.environ['TEST_ROTATE_DEST'])
            (root / 'rotation-used').touch()
            log('fault', kind='source-key-rotation')
    sys.exit(subprocess.call([real] + args, close_fds=False))
# Mutating utility containment. Sources may be the fixture product or certificates;
# destinations, and removals/permission changes, must be inside the case root.
if tool in ('cp', 'mv', 'install', 'tee'):
    positional = [x for x in args if not x.startswith('-')]
    destinations = [positional[-1]] if positional else []
    for i, arg in enumerate(args):
        if arg in ('-t', '--target-directory') and i + 1 < len(args):
            destinations = [args[i + 1]]
        elif arg.startswith('--target-directory='):
            destinations = [arg.split('=', 1)[1]]
elif tool in ('chmod', 'chown'):
    destinations = [x for x in args if not x.startswith('-')][1:]
elif tool == 'mkdir':
    destinations = [x for x in args if not x.startswith('-') and not x.isdigit()]
elif tool in ('rm', 'touch', 'ln'):
    positional = [x for x in args if not x.startswith('-')]
    destinations = positional[-1:] if tool == 'ln' else positional
else:
    destinations = []
for text in destinations:
    path = pathlib.Path(text)
    if not path.is_absolute():
        path = pathlib.Path.cwd() / path
    # lexical containment; symlink attacks are asserted by actual victim hashes.
    if os.path.commonpath([str(root), os.path.abspath(path)]) != str(root):
        fail('mutation outside isolated case: ' + str(path))
fault = os.environ.get('TEST_FAULT', '')
if fault == 'export-commit' and tool in ('cp', 'mv', 'install', 'tee'):
    targets = [pathlib.Path(x).absolute() for x in destinations]
    export = pathlib.Path(os.environ['TEST_EXPORT']).absolute()
    if any(p == export / 'target.test' or p == export / 'target.test' / 'privkey.pem' for p in targets):
        if not (root / 'fault-used').exists():
            (root / 'fault-used').touch()
            log('fault', kind='export-commit')
            if tool == 'tee':
                sys.stdin.buffer.read()
            sys.exit(76)
if fault == 'export-stage-key' and tool in ('cp', 'install'):
    source_keys = [pathlib.Path(x) for x in args if not x.startswith('-') and pathlib.Path(x).suffix == '.key' and str(root / 'storage') in x]
    if source_keys or any(pathlib.Path(x).name == 'privkey.pem' for x in destinations):
        if not (root / 'fault-used').exists():
            (root / 'fault-used').touch()
            log('fault', kind='export-stage-key')
            sys.exit(76)
if tool == 'mktemp':
    # mktemp honours TMPDIR (already isolated); explicit templates are checked.
    for arg in args:
        if arg.startswith('/') and not pathlib.Path(arg).is_relative_to(root):
            fail('mktemp outside isolated case')
sys.exit(subprocess.call([real] + args, close_fds=False))
'''


EDITOR = r'''#!/usr/bin/python3
import os, pathlib, shutil, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
candidate = pathlib.Path(sys.argv[-1])
with (root / 'editor-trace.txt').open('a') as out:
    out.write(repr(sys.argv[1:]) + '\n')
mode = os.environ.get('TEST_EDITOR_MODE', 'copy')
if mode == 'none':
    sys.exit(0)
if mode == 'delete':
    candidate.unlink()
    sys.exit(0)
if mode == 'symlink':
    candidate.unlink()
    candidate.symlink_to(root / 'victim')
    sys.exit(0)
if mode == 'directory':
    candidate.unlink()
    candidate.mkdir()
    sys.exit(0)
shutil.copyfile(root / ('invalid.caddy' if mode == 'invalid' else 'candidate.caddy'), candidate)
if mode.startswith('external'):
    live = root / 'Caddyfile'
    if mode == 'external-symlink':
        live.unlink()
        live.symlink_to(root / 'external.caddy')
    else:
        shutil.copyfile(root / 'external.caddy', live)
if mode == 'fail':
    sys.exit(17)
sys.exit(0)
'''


class Suite:
    def __init__(self, args, root):
        self.root, self.args, self.results = root, args, []
        self.product = Path(args.script).resolve()
        self.source_bytes = self.product.read_bytes()
        self.source_hash = hashlib.sha256(self.source_bytes).hexdigest()
        self.tools = {}
        for tool in ['bash', 'openssl', 'jq', 'flock', 'cp', 'mv', 'mkdir', 'chmod',
                     'chown', 'rm', 'touch', 'ln', 'install', 'tee', 'mktemp']:
            binary = shutil.which(tool)
            if not binary:
                raise RuntimeError('required executable missing: ' + tool)
            self.tools[tool] = binary
        self.tools['caddy'] = str(Path(args.caddy_bin).resolve())
        if not os.access(self.tools['caddy'], os.X_OK):
            raise RuntimeError('Caddy binary is not executable: ' + self.tools['caddy'])
        self.fixtures = root / 'fixtures'
        self.fixtures.mkdir(mode=0o700)
        self.preflight()

    def run_tool(self, argv, cwd=None, env=None, stdin=None, check=True):
        result = subprocess.run([str(x) for x in argv], cwd=cwd or self.fixtures,
                                env=env, input=stdin, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=30)
        with (self.root / 'fixture-commands.jsonl').open('a', encoding='utf-8') as out:
            out.write(json.dumps({'argv': [str(x) for x in argv], 'exit': result.returncode,
                                  'stdout': result.stdout.decode('utf-8', 'replace'),
                                  'stderr': result.stderr.decode('utf-8', 'replace')}) + '\n')
        if check and result.returncode:
            raise RuntimeError('fixture/preflight command failed: ' + str(argv) + ': ' + result.stderr.decode('utf-8', 'replace'))
        return result

    def preflight(self):
        self.run_tool(['bash', '-n', self.product])
        versions = {name: self.run_tool([binary, 'version' if name == 'caddy' else '--version' if name == 'bash' else 'version']).stdout.decode('utf-8', 'replace')
                    for name, binary in [('caddy', self.tools['caddy']), ('openssl', self.tools['openssl']), ('bash', self.tools['bash'])]}
        (self.root / 'versions.json').write_text(json.dumps(versions, indent=2), encoding='utf-8')
        lockproof = self.root / 'harness-preflight'
        (lockproof / 'bin').mkdir(parents=True, mode=0o700)
        (lockproof / 'real-tools.json').write_text(json.dumps(self.tools))
        for tool in ['flock', 'sudo']:
            path = lockproof / 'bin' / tool
            path.write_text(WRAPPER, encoding='utf-8')
            path.chmod(0o755)
        script = lockproof / 'inherited-fd.sh'
        script.write_text('set -e\nexec {fd}> "$TEST_ROOT/lock"\n/usr/bin/flock -n "$fd"\nflock -n "$fd"\nsudo flock -n "$fd"\nprintf "FD_TRANSPARENCY_OK\\n"\n')
        env = os.environ.copy()
        env.update(TEST_ROOT=str(lockproof), PATH=str(lockproof / 'bin') + ':' + env['PATH'])
        proof = self.run_tool([self.tools['bash'], script], cwd=lockproof, env=env)
        if proof.stdout.strip() != b'FD_TRANSPARENCY_OK':
            raise RuntimeError('transparent lock-wrapper positive control failed')
        openssl = self.tools['openssl']
        self.run_tool([openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '365',
                       '-subj', '/CN=Acceptance Fixture CA', '-keyout', 'ca.key', '-out', 'ca.crt'])
        (self.fixtures / 'newcerts').mkdir()
        (self.fixtures / 'index').touch()
        (self.fixtures / 'serial').write_text('1000\n')
        for name, algorithm in [('rsa', ['genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048']),
                                ('ec', ['genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:prime256v1'])]:
            self.run_tool([openssl] + algorithm + ['-out', name + '.key'])
        now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
        for name, key, domain, start, end in [
                ('rsa', 'rsa', DOMAIN, -3600, 10 * 86400),
                ('ec', 'ec', DOMAIN, -3600, 12 * 86400),
                ('renewed', 'rsa', DOMAIN, -1800, 30 * 86400),
                ('early', 'rsa', DOMAIN, -7200, 30 * 86400),
                ('expired', 'ec', DOMAIN, -10 * 86400, -86400),
                ('future', 'ec', DOMAIN, 86400, 10 * 86400),
                ('wrong-san', 'ec', OTHER, -3600, 10 * 86400),
                ('other', 'ec', OTHER, -3600, 10 * 86400)]:
            config = ('[ca]\ndefault_ca=fixture\n[fixture]\ndatabase=index\nnew_certs_dir=newcerts\n'
                      'certificate=ca.crt\nprivate_key=ca.key\nserial=serial\ndefault_md=sha256\n'
                      'policy=policy\nunique_subject=no\nx509_extensions=leaf\n[policy]\ncommonName=supplied\n'
                      '[leaf]\nbasicConstraints=critical,CA:false\nkeyUsage=digitalSignature,keyEncipherment\n'
                      'extendedKeyUsage=serverAuth\nsubjectAltName=DNS:' + domain + '\n')
            (self.fixtures / 'openssl.cnf').write_text(config)
            self.run_tool([openssl, 'req', '-new', '-key', key + '.key', '-subj', '/CN=' + domain, '-out', name + '.csr'])
            stamp = lambda seconds: (now + dt.timedelta(seconds=seconds)).strftime('%Y%m%d%H%M%SZ')
            self.run_tool([openssl, 'ca', '-batch', '-notext', '-config', 'openssl.cnf', '-in', name + '.csr',
                           '-startdate', stamp(start), '-enddate', stamp(end), '-out', name + '.crt'])
            (self.fixtures / (name + '.fullchain')).write_bytes((self.fixtures / (name + '.crt')).read_bytes() + (self.fixtures / 'ca.crt').read_bytes())
            shutil.copyfile(self.fixtures / (key + '.key'), self.fixtures / (name + '.pairkey'))
            self.run_tool([openssl, 'x509', '-in', name + '.crt', '-noout', '-dates', '-issuer', '-subject'])
        # Verify independently that fixtures have correct identities and real date states.
        for name in ['rsa', 'ec', 'renewed', 'early']:
            self.run_tool([openssl, 'verify', '-CAfile', 'ca.crt', '-verify_hostname', DOMAIN, name + '.crt'])
        for name in ['expired', 'future', 'wrong-san']:
            result = self.run_tool([openssl, 'verify', '-CAfile', 'ca.crt', '-verify_hostname', DOMAIN, name + '.crt'], check=False)
            if result.returncode == 0:
                raise RuntimeError('invalid certificate fixture unexpectedly verified: ' + name)
        for path in self.fixtures.glob('*key'):
            path.chmod(0o600)

    def case(self, name, callback):
        case = None
        try:
            case = Case(self, name)
            callback(case)
            status, reason = 'passed', 'all independent assertions satisfied'
        except ProductFailure as exc:
            status, reason = 'failed', str(exc)
        except AssertionError as exc:
            status, reason = 'failed', str(exc)
        except Exception as exc:
            status, reason = 'error', type(exc).__name__ + ': ' + str(exc)
        finally:
            if case:
                case.finish()
        record = {'case': name, 'status': status, 'passed': status == 'passed', 'reason': reason,
                  'evidence': str(case.root) if case else None, 'source_sha256': self.source_hash}
        self.results.append(record)
        if case:
            (case.root / 'result.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
        print(status.upper() + ' ' + name + ': ' + reason, flush=True)
        self.save()

    def save(self):
        counts = {key: sum(x['status'] == key for x in self.results) for key in ('passed', 'failed', 'error')}
        summary = {'script': str(self.product), 'source_sha256': self.source_hash,
                   'run_directory': str(self.root), 'counts': counts,
                   'boundaries': {'real': ['Linux filesystem/permissions', 'OpenSSL fixtures/verification', 'Caddy adapt/validate'],
                                  'mocked': ['systemctl', 'journalctl', 'fault injection', 'explicit TEST_ADAPT_JSON cases'],
                                  'not_verified': ['live systemd scheduling', 'production deployment', 'live TLS/internal CA server (final integration task)']},
                   'results': self.results}
        (self.root / 'summary.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding='utf-8')


class Case:
    def __init__(self, suite, name):
        self.suite, self.name = suite, name
        self.root = suite.root / name
        self.root.mkdir(mode=0o700)
        for directory in ['bin', 'tmp', 'home', 'service-home', 'storage']:
            (self.root / directory).mkdir(mode=0o700)
        self.config, self.registry = self.root / 'Caddyfile', self.root / 'registry'
        self.state, self.dest = self.root / 'state', self.root / 'export destination'
        self.worker, self.units = self.root / 'worker', self.root / 'units'
        self.product = self.root / 'product.sh'
        self.product.write_bytes(suite.source_bytes)
        self.product.chmod(0o700)
        self.registry.write_text('before.test -> http://127.0.0.1:18080\n', encoding='utf-8')
        self.original_registry = self.registry.read_bytes()
        self.config.write_text(self.configuration('original'), encoding='utf-8')
        self.config.chmod(0o640)
        self.original_config = self.config.read_bytes()
        (self.root / 'candidate.caddy').write_text(self.configuration('edited'), encoding='utf-8')
        (self.root / 'external.caddy').write_text(self.configuration('external'), encoding='utf-8')
        (self.root / 'invalid.caddy').write_text('this is not a Caddyfile {\n', encoding='utf-8')
        (self.root / 'victim').write_bytes(b'victim must survive\n')
        (self.root / 'Caddyfile.bak').write_bytes(b'existing backup must survive\n')
        (self.root / 'real-tools.json').write_text(json.dumps(suite.tools), encoding='utf-8')
        self.env = os.environ.copy()
        # Do not inherit stale test-mode variables from a preceding suite invocation.
        for key in list(self.env):
            if key.startswith(('TEST_', 'CERT_', 'CADDY_SERVICE_')):
                self.env.pop(key)
        self.env.update(EASY_CADDY_TEST_MODE='1', TEST_ROOT=str(self.root), TEST_EXPORT=str(self.dest),
                        CADDYFILE=str(self.config), PROXY_CONFIG_FILE=str(self.registry),
                        CERT_STATE_DIR=str(self.state), CERT_STORAGE_DIR_OVERRIDE=str(self.root / 'storage'),
                        CERT_WORKER_INSTALL_DIR=str(self.worker), CERT_SYSTEMD_UNIT_DIR=str(self.units),
                        HOME=str(self.root / 'home'), TMPDIR=str(self.root / 'tmp'),
                        XDG_DATA_HOME=str(self.root / 'home/data'), XDG_CONFIG_HOME=str(self.root / 'home/config'),
                        PATH=str(self.root / 'bin') + os.pathsep + os.environ['PATH'])
        for tool in list(suite.tools) + ['sudo', 'systemctl', 'journalctl', 'apt', 'apt-get', 'yum', 'dnf', 'curl', 'wget', 'service', 'docker']:
            if tool == 'bash':
                continue
            wrapper = self.root / 'bin' / tool
            wrapper.write_text(WRAPPER, encoding='utf-8')
            wrapper.chmod(0o755)
        editor = self.root / 'bin/editor'
        editor.write_text(EDITOR, encoding='utf-8')
        editor.chmod(0o755)
        self.env.update(EDITOR=str(editor), VISUAL='')
        self.steps, self.processes = 0, []
        self.validate(self.config, expected=True)
        self.before = self.observed()
        (self.root / 'before.json').write_text(json.dumps(self.before, indent=2), encoding='utf-8')

    def configuration(self, response, storage=None):
        root = self.root / 'validation-storage' if storage is None else storage
        return ('{\n admin off\n auto_https off\n storage file_system {\n  root ' + json.dumps(str(root)) + '\n }\n}\n'
                '# retain manual site\nhttp://before.test {\n respond "' + response + '"\n}\n')

    def observed(self):
        return {name: record_tree(path) for name, path in [('config', self.config), ('registry', self.registry),
                ('state', self.state), ('storage', self.root / 'storage'), ('export', self.dest),
                ('worker', self.worker), ('units', self.units), ('victim', self.root / 'victim')]}

    def finish(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        (self.root / 'after.json').write_text(json.dumps(self.observed(), indent=2), encoding='utf-8')

    def require(self, condition, message):
        if not condition:
            raise ProductFailure(message)

    def require_clean_tools(self):
        blocked = [x for x in self.trace() if x['event'] == 'blocked']
        self.require(not blocked, 'product attempted prohibited/out-of-case operation: ' + str(blocked))

    def trace(self):
        path = self.root / 'trace.jsonl'
        return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []

    def reloads(self):
        return [x for x in self.trace() if x['tool'] == 'systemctl' and 'reload' in x['argv']]

    def validators(self):
        return [x for x in self.trace() if x['tool'] == 'caddy' and x['argv'] and x['argv'][0] == 'validate']

    def driver(self, body, required=()):
        # Source the actual unedited single-file product; legacy EOF exits its menu.
        # Product behavior assertions separately require source to produce no menu.
        self.steps += 1
        path = self.root / ('driver-%03d.sh' % self.steps)
        text = ('#!/bin/bash\nsource ' + q(self.product) + ' </dev/null\n'
                'CADDYFILE=' + q(self.config) + '\nCADDY_CONFIG_DIR=' + q(self.root) + '\n'
                'PROXY_CONFIG_FILE=' + q(self.registry) + '\nBACKUP_CADDYFILE=' + q(self.root / 'Caddyfile.bak') + '\n'
                'CERT_STATE_DIR=' + q(self.state) + '\nCERT_WORKER_INSTALL_DIR=' + q(self.worker) + '\n'
                'CERT_SYSTEMD_UNIT_DIR=' + q(self.units) + '\n'
                'check_port_running() { :; }\ncheck_remote_upstream() { :; }\n'
                'printf "OPERATION_BEGIN\\n"\n')
        for function in required:
            text += 'declare -F ' + q(function) + ' >/dev/null || { printf "CONTRACT_MISSING: %s\\n" ' + q(function) + '; exit 125; }\n'
        path.write_text(text + body + '\n', encoding='utf-8')
        return path

    def invoke(self, function, *args, stdin='', check_interface=True):
        driver = self.driver(function + ''.join(' ' + q(arg) for arg in args), [function] if check_interface else [])
        result = self.execute(['bash', driver], stdin)
        if result.returncode == 125 and 'CONTRACT_MISSING:' in result.stdout:
            raise ProductFailure('required Bash interface absent: ' + function)
        return result

    def execute(self, argv, stdin='', env=None, timeout=15):
        self.steps += 1
        prefix = self.root / ('step-%03d' % self.steps)
        (prefix.with_suffix('.command.json')).write_text(json.dumps([str(x) for x in argv]), encoding='utf-8')
        try:
            result = subprocess.run([str(x) for x in argv], cwd=self.root, env=env or self.env,
                                    input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, encoding='utf-8', errors='replace', timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            prefix.with_suffix('.stdout.txt').write_bytes(exc.stdout or b'')
            prefix.with_suffix('.stderr.txt').write_bytes(exc.stderr or b'')
            raise ProductFailure('product did not terminate within ' + str(timeout) + 's; timeout is never a pass')
        prefix.with_suffix('.stdout.txt').write_text(result.stdout, encoding='utf-8')
        prefix.with_suffix('.stderr.txt').write_text(result.stderr, encoding='utf-8')
        prefix.with_suffix('.exit.txt').write_text(str(result.returncode) + '\n')
        if result.returncode == 90:
            raise ProductFailure('product attempted an operation prohibited by isolated harness: ' + result.stderr.strip())
        return result

    def operation_output(self, result):
        return result.stdout.split('OPERATION_BEGIN\n', 1)[-1]

    def validate(self, config=None, expected=True):
        result = self.execute([self.suite.tools['caddy'], 'validate', '--adapter', 'caddyfile', '--config', config or self.config])
        if (result.returncode == 0) != expected:
            raise RuntimeError('independent real Caddy validation did not match fixture expectation: ' + result.stderr)
        return result

    def source(self, name='rsa', issuer='acme.fixture-one', domain=DOMAIN, key=True):
        folder = self.root / 'storage/certificates' / issuer / domain
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        cert, private = folder / (domain + '.crt'), folder / (domain + '.key')
        shutil.copyfile(self.suite.fixtures / (name + '.fullchain'), cert)
        cert.chmod(0o640)
        if key:
            shutil.copyfile(self.suite.fixtures / (name + '.pairkey'), private)
            private.chmod(0o600)
        return cert, private

    def state_fixture(self, domains=(DOMAIN,), dest=None):
        # Direct independent data fixtures let sync tests avoid relying on setter correctness.
        self.state.mkdir(mode=0o700, exist_ok=True)
        for name, content in [('export-directory', str(dest or self.dest) + '\n'),
                              ('export-domains', ''.join(x + '\n' for x in domains))]:
            path = self.state / name
            path.write_text(content, encoding='utf-8')
            path.chmod(0o600)

    def pair(self, dest=None, domain=DOMAIN):
        folder = (dest or self.dest) / domain
        return folder / 'fullchain.pem', folder / 'privkey.pem'

    def assert_pair(self, source=None, dest=None, domain=DOMAIN):
        cert, key = self.pair(dest, domain)
        self.require(cert.is_file() and key.is_file() and not cert.is_symlink() and not key.is_symlink(), 'export must contain two safe regular PEM files')
        if source:
            self.require(cert.read_bytes() == source[0].read_bytes() and key.read_bytes() == source[1].read_bytes(), 'exported certificate chain/key must match selected source bytes exactly')
        pubcert = self.execute([self.suite.tools['openssl'], 'x509', '-in', cert, '-noout', '-pubkey'])
        pubkey = self.execute([self.suite.tools['openssl'], 'pkey', '-in', key, '-pubout'])
        self.require(pubcert.returncode == pubkey.returncode == 0 and pubcert.stdout == pubkey.stdout, 'real OpenSSL public keys do not match')
        validity = self.execute([self.suite.tools['openssl'], 'verify', '-CAfile', self.suite.fixtures / 'ca.crt', '-verify_hostname', domain, cert])
        self.require(validity.returncode == 0, 'export failed real OpenSSL dates/SAN/fixture-CA verification')
        self.require((key.stat().st_mode & 0o777) == 0o600, 'exported private key must have mode 0600')
        self.require((cert.parent.stat().st_mode & 0o777) == 0o700, 'domain export directory must have mode 0700')
        self.require((cert.stat().st_mode & 0o777) in (0o600, 0o644), 'public certificate permission is not controlled')
        self.require_clean_tools()

    def service_process(self, home=None, xdg=None, extra=None):
        env = self.env.copy()
        env['HOME'] = str(home or self.root / 'service-home')
        env.pop('XDG_DATA_HOME', None)
        if xdg is not None:
            env['XDG_DATA_HOME'] = str(xdg)
        env.update(extra or {})
        child = subprocess.Popen(['/usr/bin/sleep', '1200'], env=env, cwd=self.root,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.processes.append(child)
        self.env['TEST_SERVICE_PID'] = str(child.pid)
        return child

    def background(self, function, *args, env=None):
        driver = self.driver(function + ''.join(' ' + q(arg) for arg in args), [function])
        out = (self.root / ('background-%03d.stdout.txt' % self.steps)).open('w', encoding='utf-8')
        err = (self.root / ('background-%03d.stderr.txt' % self.steps)).open('w', encoding='utf-8')
        process = subprocess.Popen(['bash', str(driver)], cwd=self.root, env=env or self.env,
                                   stdin=subprocess.DEVNULL, stdout=out, stderr=err)
        out.close()
        err.close()
        self.processes.append(process)
        return process


def settings(c):
    # Internal lock filenames are intentionally not part of the public contract.
    root = record_tree(c.state).get('.')
    if root:
        root = {key: root[key] for key in ['mode', 'uid', 'gid', 'type']}
    return {'root': root, 'directory': record_tree(c.state / 'export-directory'),
            'domains': record_tree(c.state / 'export-domains')}


def unchanged(c, config=True, registry=True):
    if config:
        c.require(c.config.read_bytes() == c.original_config, 'live Caddyfile changed when transaction must not commit')
    if registry:
        c.require(c.registry.read_bytes() == c.original_registry, 'legacy domain -> upstream registry was modified')
    c.require((c.root / 'victim').read_bytes() == b'victim must survive\n', 'symlink/injection victim was modified')
    c.require((c.root / 'Caddyfile.bak').read_bytes() == b'existing backup must survive\n', 'existing .bak was overwritten')


def no_worker(c):
    c.require(not c.worker.exists() and not c.units.exists(), 'worker artifacts exist before successful opt-in')
    c.require(not any(x['tool'] == 'systemctl' and any(a in x['argv'] for a in ['enable', 'daemon-reload']) for x in c.trace()), 'worker enabled without successful opt-in')


def source_safe(c):
    result = c.execute(['bash', '-c', 'source ' + q(c.product) + ' </dev/null; printf SOURCE_SAFE'])
    c.require(result.returncode == 0 and result.stdout == 'SOURCE_SAFE', 'sourcing must expose interfaces without running a menu')
    unchanged(c)
    no_worker(c)


def menus(c):
    result = c.invoke('show_menu')
    output = c.operation_output(result)
    for number in range(1, 14):
        c.require(re.search(r'(?m)^\s*' + str(number) + r'(?:[.)、）]|[ \t])', output) is not None, 'main menu is missing option ' + str(number))
    c.require('证书' in output and '编辑' in output, 'main menu must name certificate management and editing')
    # Both new dispatches are executed in actual script processes, bounded by EOF.
    view = c.execute(['bash', c.product], '12\n')
    c.require(view.returncode == 0 and '无效选项' not in view.stdout, 'menu option 12 did not dispatch/return safely at EOF')
    edit = c.execute(['bash', c.product], '13\n')
    c.require(edit.returncode == 0 and (c.root / 'editor-trace.txt').exists(), 'menu option 13 did not invoke the candidate editor')
    c.require(c.config.read_bytes() == (c.root / 'candidate.caddy').read_bytes(), 'menu option 13 did not apply edited candidate')
    c.require(c.registry.read_bytes() == c.original_registry, 'menu editing changed old registry')


def interfaces(c):
    result = c.execute(['bash', c.driver('\n'.join('declare -F ' + name for name in INTERFACES), INTERFACES)])
    c.require(result.returncode == 0, 'nine frozen source-safe interfaces are required: ' + c.operation_output(result))


def cli_unknown(c):
    result = c.execute(['bash', c.product, '--not-a-real-command'])
    c.require(result.returncode != 0 and '请输入选项' not in result.stdout, 'unknown CLI argument must return nonzero without menu')
    unchanged(c)
    no_worker(c)


def listing(c):
    sources = [c.source('rsa', 'acme.alpha'), c.source('expired', 'acme.expired'),
               c.source('ec', 'acme.no-key', key=False)]
    c.source('other', 'acme.other', OTHER)
    account = c.root / 'storage/acme/account-private.key'
    account.parent.mkdir(parents=True)
    account.write_text('ACCOUNT_PRIVATE_SENTINEL')
    authority = c.root / 'storage/pki/authorities/local/root.key'
    authority.parent.mkdir(parents=True)
    authority.write_text('AUTHORITY_PRIVATE_SENTINEL')
    before = record_tree(c.root / 'storage')
    result = c.invoke('list_certificates')
    details = c.invoke('certificate_technical_details')
    c.require(details.returncode == 0, 'explicit technical listing failed')
    output = c.operation_output(result) + result.stderr + c.operation_output(details) + details.stderr
    c.require(result.returncode == 0, 'listing failed with valid/missing/expired certificate fixtures')
    for token in [DOMAIN, OTHER, 'acme.alpha', 'acme.expired', str(sources[0][0]), str(sources[0][1])]:
        c.require(token in output, 'listing lacks required public metadata: ' + token)
    c.require(re.search(r'notBefore|生效|开始|有效期|签发|20\d\d[-/]', output, re.I), 'listing lacks dates')
    c.require(re.search(r'expired|过期', output, re.I) and re.search(r'key|密钥', output, re.I), 'listing lacks expiry/key state')
    c.require('PRIVATE KEY' not in output and 'PRIVATE_SENTINEL' not in output, 'listing leaked key material')
    c.require(record_tree(c.root / 'storage') == before, 'read-only listing modified storage')
    unchanged(c)
    no_worker(c)


def directory_only(c):
    result = c.invoke('set_certificate_export_directory', c.dest)
    c.require(result.returncode == 0, 'safe absolute export path with spaces must be accepted')
    c.require((c.state / 'export-directory').read_text().strip() == str(c.dest), 'directory state is not exact path data')
    c.require((c.state.stat().st_mode & 0o777) == 0o700, 'state directory permissions must be 0700')
    c.require(((c.state / 'export-directory').stat().st_mode & 0o777) == 0o600, 'directory state must be 0600')
    c.require(not (c.state / 'export-domains').exists() or not (c.state / 'export-domains').read_text().strip(), 'saving directory must not opt-in any domains')
    c.require(not list(c.dest.rglob('privkey.pem')) if c.dest.exists() else True, 'directory-only action copied certificates')
    no_worker(c)
    unchanged(c)


def registration(c):
    c.state_fixture(domains=())
    for domain in ['Target.Test.', DOMAIN, OTHER, DOMAIN]:
        result = c.invoke('register_certificate_export', domain)
        c.require(result.returncode == 0, 'registration must normalize and be idempotent')
    lines = (c.state / 'export-domains').read_text().splitlines()
    c.require(lines.count(DOMAIN) == lines.count(OTHER) == 1 and len(lines) == 2, 'domain list is not normalized/idempotent')
    c.require(((c.state / 'export-domains').stat().st_mode & 0o777) == 0o600, 'domain state must be mode 0600')
    unchanged(c)


def invalid_domain(c, kind):
    marker = c.root / 'injected'
    values = {'command': '$(touch ' + str(marker) + ')', 'slash': '../escape.test',
              'newline': DOMAIN + '\n' + OTHER, 'wildcard': '*.target.test', 'semicolon': DOMAIN + '; touch ' + str(marker)}
    c.state_fixture(domains=(OTHER,))
    before = settings(c)
    result = c.invoke('register_certificate_export', values[kind])
    c.require(result.returncode != 0, 'unsafe domain must be rejected: ' + kind)
    c.require(settings(c) == before and not marker.exists(), 'domain rejection changed state or executed data')
    unchanged(c)


def directory_bad(c, kind):
    c.state_fixture()
    candidates = {'relative': Path('relative/path'), 'root': Path('/'), 'system-top': Path('/etc'),
                  'storage': c.root / 'storage', 'within-storage': c.root / 'storage/inside',
                  'contains-storage': c.root, 'config': c.config, 'state': c.state,
                  'registry': c.registry, 'worker': c.worker, 'unit': c.units,
                  'newline': str(c.dest) + '\nextra', 'control': str(c.dest) + '\x01'}
    if kind == 'symlink':
        candidate = c.root / 'linked-export'
        candidate.symlink_to(c.dest, target_is_directory=True)
    elif kind == 'linked-ancestor':
        target = c.root / 'real-ancestor'
        target.mkdir()
        link = c.root / 'linked-ancestor'
        link.symlink_to(target, target_is_directory=True)
        candidate = link / 'nested'
    elif kind == 'foreign-owner':
        candidate = c.root / 'foreign-directory'
        candidate.mkdir()
        os.chown(candidate, 65534, 65534)
    else:
        candidate = candidates[kind]
    before = settings(c)
    result = c.invoke('set_certificate_export_directory', candidate)
    c.require(result.returncode != 0, 'unsafe export destination accepted: ' + kind)
    c.require(settings(c) == before, 'invalid destination must leave prior state unchanged')
    unchanged(c)
    no_worker(c)


def directory_data(c):
    marker = c.root / 'injected'
    candidate = c.root / ('literal $(touch ' + str(marker).replace('/', '_') + ') ; export')
    result = c.invoke('set_certificate_export_directory', candidate)
    c.require(result.returncode == 0, 'shell metacharacters in an otherwise safe path must be treated as data')
    c.require((c.state / 'export-directory').read_text().rstrip('\n') == str(candidate), 'path was evaluated/rewritten')
    c.require(not marker.exists() and not (c.root / 'export').exists(), 'path data executed a command')
    no_worker(c)


def sync_valid(c, kind):
    pair = c.source(kind)
    c.state_fixture()
    before = record_tree(c.root / 'storage')
    result = c.invoke('sync_certificates')
    c.require(result.returncode == 0, 'valid ' + kind + ' fullchain/key failed sync')
    c.assert_pair(pair)
    c.require(record_tree(c.root / 'storage') == before, 'sync modified source bytes/permissions')
    unchanged(c)


def sync_pending(c):
    c.state_fixture()
    result = c.invoke('sync_certificates')
    c.require(result.returncode == 0, 'unsigned registered domain is pending, not fatal')
    c.require(re.search(r'pending|待|未签|没有|未找到', c.operation_output(result) + result.stderr, re.I), 'pending domain lacks diagnostic')
    c.require(not c.pair()[0].exists() and not c.pair()[1].exists(), 'pending sync created a half pair')
    unchanged(c)


def sync_empty(c):
    c.state_fixture(domains=())
    result = c.invoke('sync_certificates')
    c.require(result.returncode == 0 and not c.dest.exists(), 'empty registrations must exit0 without destination creation')
    c.require(not any(x['tool'] in ['caddy', 'openssl'] for x in c.trace()), 'empty registration must not scan/adapt certificates')
    no_worker(c)
    unchanged(c)


def selection(c, kind):
    c.state_fixture()
    if kind == 'latest':
        c.source('rsa', 'acme.z-last')
        expected = c.source('renewed', 'acme.a-first')
        c.source('expired', 'acme.expired')
    elif kind == 'notbefore':
        c.source('early', 'acme.a-early')
        expected = c.source('renewed', 'acme.z-newer')
    else:
        expected = c.source('renewed', 'acme.a-first')
        c.source('renewed', 'acme.z-last')
    result = c.invoke('sync_certificates')
    c.require(result.returncode == 0, 'multiple-issuer selection failed')
    c.assert_pair(expected)
    # Equal bytes still require a stable documented selection path in diagnostic.
    if kind == 'lexical':
        output = c.operation_output(result) + result.stderr + (c.state / 'sync.log').read_text()
        c.require('acme.a-first' in output or str(expected[0]) in output, 'tie must identify deterministic lexical issuer')


def bad_certificate(c, kind):
    c.state_fixture()
    pair = c.source(kind if kind in ['expired', 'future', 'wrong-san'] else 'rsa', key=kind != 'missing-key')
    if kind == 'mismatch':
        shutil.copyfile(c.suite.fixtures / 'ec.pairkey', pair[1])
    elif kind == 'invalid-pem':
        pair[0].write_text('not a certificate\n')
    elif kind == 'key-symlink':
        pair[1].unlink()
        pair[1].symlink_to(c.suite.fixtures / 'rsa.pairkey')
    elif kind == 'cert-symlink':
        pair[0].unlink()
        pair[0].symlink_to(c.suite.fixtures / 'rsa.fullchain')
    elif kind == 'key-hardlink':
        pair[1].unlink()
        os.link(c.suite.fixtures / 'rsa.pairkey', pair[1])
    before = record_tree(c.root / 'storage')
    result = c.invoke('sync_certificates')
    c.require(result.returncode != 0, 'invalid/insecure candidate must produce a diagnostic failure: ' + kind)
    c.require(not c.pair()[0].exists() and not c.pair()[1].exists(), 'invalid candidate exported certificate/key')
    c.require(record_tree(c.root / 'storage') == before, 'invalid source was altered')
    unchanged(c)


def registration_scope(c, cli=False):
    expected = c.source('rsa')
    c.source('other', domain=OTHER)
    c.state_fixture()
    result = c.execute(['bash', c.product, '--sync-certificates', DOMAIN]) if cli else c.invoke('sync_certificates', OTHER)
    if cli:
        c.require(result.returncode == 0 and '请输入选项' not in result.stdout, 'sync CLI must finish without menu/stdin/installation')
        c.assert_pair(expected)
    else:
        c.require(result.returncode != 0 or not (c.dest / OTHER).exists(), 'explicit domain sync exported an unregistered domain')
        c.require(not c.dest.exists(), 'unregistered request wrote a destination')
    c.require(not (c.dest / OTHER).exists(), 'unregistered domain leaked to export')
    no_worker(c)


def destination_unsafe(c, kind):
    c.source()
    c.state_fixture()
    folder = c.dest / DOMAIN
    folder.mkdir(parents=True, mode=0o700)
    cert, key = c.pair()
    if kind == 'domain-symlink':
        folder.rmdir()
        folder.symlink_to(c.root / 'home', target_is_directory=True)
    elif kind == 'key-symlink':
        key.symlink_to(c.root / 'victim')
    elif kind == 'cert-symlink':
        cert.symlink_to(c.root / 'victim')
    elif kind == 'hardlink':
        os.link(c.root / 'victim', key)
    elif kind == 'half-pair':
        cert.write_bytes((c.suite.fixtures / 'rsa.fullchain').read_bytes())
    elif kind == 'invalid-existing-pair':
        cert.write_text('invalid existing cert')
        key.write_text('invalid existing key')
    elif kind == 'foreign-owner':
        os.chown(folder, 65534, 65534)
    before = record_tree(c.dest)
    result = c.invoke('sync_certificates')
    c.require(result.returncode != 0, 'unsafe existing export must be refused: ' + kind)
    c.require(record_tree(c.dest) == before, 'unsafe export objects were changed')
    unchanged(c)


def renew(c, failure=None):
    original = c.source('rsa')
    c.state_fixture()
    first = c.invoke('sync_certificates')
    c.require(first.returncode == 0, 'initial valid export failed')
    c.assert_pair(original)
    initial = record_tree(c.dest)
    again = c.invoke('sync_certificates')
    c.require(again.returncode == 0 and record_tree(c.dest) == initial, 'unchanged certificate should not rewrite files/inodes/mtime')
    renewed = c.source('renewed')
    c.env['TEST_FAULT'] = failure or ''
    result = c.invoke('sync_certificates')
    if failure:
        c.require(any(x['event'] == 'fault' and x.get('kind') == failure for x in c.trace()), 'fault injector did not hit requested write boundary: ' + failure)
        c.require(result.returncode != 0, 'injected write failure must return nonzero')
        cert, key = c.pair()
        c.require(cert.read_bytes() == (c.suite.fixtures / 'rsa.fullchain').read_bytes() and key.read_bytes() == (c.suite.fixtures / 'rsa.pairkey').read_bytes(), 'write failure corrupted previous valid pair')
        c.assert_pair()
    else:
        c.require(result.returncode == 0, 'renewed valid certificate failed sync')
        c.assert_pair(renewed)


def rotation(c):
    pair = c.source('rsa')
    c.state_fixture()
    c.env.update(TEST_ROTATE_KEY=str(c.suite.fixtures / 'ec.pairkey'), TEST_ROTATE_DEST=str(pair[1]))
    result = c.invoke('sync_certificates')
    c.require((c.root / 'rotation-used').exists(), 'source rotation injector never ran')
    c.require(not c.pair()[0].exists() and not c.pair()[1].exists(), 'rotating mixed-generation source pair was exported')
    c.require(result.returncode != 0 or re.search(r'待|rotation|变化|不匹配|retry', c.operation_output(result) + result.stderr, re.I), 'rotation deferred without diagnostic')


def directory_change(c):
    pair = c.source()
    c.state_fixture()
    c.require(c.invoke('sync_certificates').returncode == 0, 'initial sync failed')
    c.assert_pair(pair)
    old = record_tree(c.dest)
    new = c.root / 'second destination'
    c.require(c.invoke('set_certificate_export_directory', new).returncode == 0, 'directory change failed')
    c.require(c.invoke('sync_certificates').returncode == 0, 'sync after directory change failed')
    c.assert_pair(pair, new)
    c.require(record_tree(c.dest) == old, 'directory change deleted/rewrote old consumers copies')


def unregister(c):
    pair = c.source()
    c.source('other', domain=OTHER)
    c.state_fixture((DOMAIN, OTHER))
    c.require(c.invoke('sync_certificates').returncode == 0, 'initial dual sync failed')
    old = record_tree(c.dest / DOMAIN)
    c.require(c.invoke('unregister_certificate_export', DOMAIN).returncode == 0, 'unregister failed')
    c.require((c.state / 'export-domains').read_text().splitlines() == [OTHER], 'unregister damaged other registrations')
    c.source('renewed')
    c.require(c.invoke('sync_certificates').returncode == 0, 'sync remaining registration failed')
    c.require(record_tree(c.dest / DOMAIN) == old, 'unregistered domain was still updated/deleted')
    unchanged(c)


def bad_state(c, kind):
    c.source()
    c.state_fixture()
    marker = c.root / 'injected'
    if kind == 'directory-lines':
        (c.state / 'export-directory').write_text(str(c.dest) + '\n' + str(c.root / 'escape') + '\n')
    elif kind == 'domains-command':
        (c.state / 'export-domains').write_text('$(touch ' + str(marker) + ')\n')
    elif kind == 'state-symlink':
        (c.state / 'export-directory').unlink()
        (c.state / 'export-directory').symlink_to(c.root / 'victim')
    elif kind == 'state-hardlink':
        (c.state / 'export-domains').unlink()
        os.link(c.root / 'victim', c.state / 'export-domains')
    before = settings(c)
    result = c.invoke('sync_certificates')
    c.require(result.returncode != 0 and not c.dest.exists(), 'corrupted state must not silently sync: ' + kind)
    c.require(not marker.exists() and settings(c) == before, 'state data executed or was rewritten')
    unchanged(c)


def storage(c, kind):
    c.env.pop('CERT_STORAGE_DIR_OVERRIDE')
    if kind in ['home', 'xdg', 'home-override', 'xdg-override', 'stopped-default']:
        c.config.write_text('{\n admin off\n auto_https off\n}\nhttp://before.test {\n respond original\n}\n')
        home, xdg = c.root / 'service-home', c.root / 'service-xdg with spaces'
        if kind in ['home', 'xdg']:
            c.service_process(home, xdg if kind == 'xdg' else None, {'PRIVATE_ENV_SENTINEL': 'DO_NOT_DISCLOSE'})
        else:
            c.env['CADDY_SERVICE_HOME_OVERRIDE'] = str(home)
            if kind == 'xdg-override':
                c.env['CADDY_SERVICE_XDG_DATA_HOME_OVERRIDE'] = str(xdg)
        expected = xdg / 'caddy' if kind in ['xdg', 'xdg-override'] else home / '.local/share/caddy'
    elif kind == 'stopped-environment-file':
        c.config.write_text('{\n admin off\n auto_https off\n}\nhttp://before.test {\n respond original\n}\n')
        home, xdg = c.root / 'service-home', c.root / 'environment-file-xdg'
        envfile = c.root / 'caddy.env'
        envfile.write_text('XDG_DATA_HOME=' + str(xdg) + '\n', encoding='utf-8')
        c.env['TEST_ENVIRONMENT_FILES'] = str(envfile) + ' (ignore_errors=no)'
        key, value = envfile.read_text(encoding='utf-8').strip().split('=', 1)
        if key != 'XDG_DATA_HOME' or value != str(xdg):
            raise RuntimeError('invalid EnvironmentFile fixture')
        # Supply only this non-secret fixture environment and record AppDataDir alone.
        effective = {'PATH': '/usr/bin:/bin', 'HOME': str(home), key: value, 'LC_ALL': 'C'}
        real_env = c.execute(['bash', '-c',
                              'set -o pipefail; "$1" environ | sed -n \'/^caddy.AppDataDir=/p\'',
                              '_', c.suite.tools['caddy']], env=effective)
        expected = xdg / 'caddy'
        if real_env.returncode != 0 or real_env.stdout.strip() != 'caddy.AppDataDir=' + str(expected):
            raise RuntimeError('real Caddy EnvironmentFile positive control failed')
    elif kind in ['literal', 'stopped-literal']:
        expected = c.root / 'custom storage with spaces'
        c.config.write_text(c.configuration('original', expected))
        if kind == 'literal':
            c.service_process()
    elif kind in ['template', 'unresolved-template']:
        expected = c.root / 'from service template'
        c.config.write_text(c.configuration('original', '{env.CADDY_FIXTURE_STORAGE}'))
        extra = {'CADDY_FIXTURE_STORAGE': str(expected)} if kind == 'template' else {}
        c.service_process(extra=extra)
    elif kind == 'adapt-failure':
        c.config.write_text('invalid Caddyfile {\n')
        expected = None
    elif kind in ['unknown-module', 'policy-override']:
        # These are explicitly synthetic parsed-JSON branches; stock Caddy cannot
        # generate an unknown storage module. Not claimed as real module proof.
        data = {'storage': {'module': 'unknown_fixture_storage', 'root': str(c.root / 'wrong-root')}} if kind == 'unknown-module' else {'apps': {'tls': {'automation': {'policies': [{'storage': {'module': 'file_system', 'root': str(c.root / 'policy-root')}}]}}}}
        fixture = c.root / 'synthetic-adapt.json'
        fixture.write_text(json.dumps(data))
        c.env['TEST_ADAPT_JSON'] = str(fixture)
        expected = None
    else:
        c.config.write_text('{\n admin off\n auto_https off\n}\nhttp://before.test {\n respond original\n}\n')
        c.env['TEST_SERVICE_USER'] = 'missing_fixture_service_user_90123'
        c.env['TEST_UNCERTAIN_HOME'] = '1'
        expected = None
    if kind == 'unresolved-template':
        expected = None
    real_adapt = c.execute([c.suite.tools['caddy'], 'adapt', '--adapter', 'caddyfile', '--config', c.config])
    if kind != 'adapt-failure' and real_adapt.returncode != 0:
        raise RuntimeError('storage discovery fixture failed independent real adapt: ' + real_adapt.stderr)
    before = c.observed()
    result = c.invoke('certificate_storage_root')
    output = c.operation_output(result).strip()
    if kind == 'stopped-environment-file':
        diagnostic = output + result.stderr
        c.require(result.returncode != 0 and 'EnvironmentFile' in diagnostic,
                  'stopped EnvironmentFile must be rejected with an explicit diagnostic: ' + diagnostic)
        c.require(str(c.root / 'service-home') not in output, 'stopped EnvironmentFile guessed the declared HOME root')
    elif expected is None:
        c.require(result.returncode != 0 and (output or result.stderr), 'unsupported/uncertain storage must diagnose and fail: ' + kind)
        c.require(str(c.root / 'home') not in output, 'storage failure guessed management-script HOME')
    else:
        c.require(result.returncode == 0 and str(expected) in output.splitlines(), 'incorrect service/custom storage root: ' + kind + ': ' + output)
    c.require('DO_NOT_DISCLOSE' not in output + result.stderr, 'storage discovery leaked unrelated process environment')
    c.require(c.observed() == before, 'storage discovery changed configuration, state or export files')
    no_worker(c)
    c.require_clean_tools()


def proxy(c, entry, choice, phase='normal'):
    function = 'setup_reverse_proxy' if entry == 'local' else 'setup_reverse_proxy_remote'
    upstream = '18081' if entry == 'local' else 'https://upstream.test:18443'
    if choice == 'saved-yes':
        c.state_fixture(domains=())
        stdin = DOMAIN + '\n' + upstream + '\ny\n'
    elif choice == 'new-yes':
        stdin = DOMAIN + '\n' + upstream + '\ny\n' + str(c.dest) + '\n'
    elif choice == 'no':
        stdin = DOMAIN + '\n' + upstream + '\nn\n'
    elif choice == 'default-no':
        stdin = DOMAIN + '\n' + upstream + '\n\n'
    elif choice == 'eof-domain':
        stdin = ''
    elif choice == 'eof-upstream':
        stdin = DOMAIN + '\n'
    elif choice == 'eof-choice':
        stdin = DOMAIN + '\n' + upstream + '\n'
    elif choice == 'eof-directory':
        stdin = DOMAIN + '\n' + upstream + '\ny\n'
    elif choice == 'invalid-directory':
        stdin = DOMAIN + '\n' + upstream + '\ny\n/etc\n'
    elif choice == 'existing-no':
        c.state_fixture((DOMAIN, OTHER))
        stdin = DOMAIN + '\n' + upstream + '\nn\n'
    elif choice == 'duplicate':
        c.registry.write_bytes(c.original_registry + (DOMAIN + ' -> http://127.0.0.1:18081\n').encode())
        c.original_registry = c.registry.read_bytes()
        stdin = DOMAIN + '\n' + upstream + '\ny\n' + str(c.dest) + '\n'
    else:
        raise RuntimeError('unknown proxy fixture')
    before = settings(c)
    c.env['TEST_FAULT'] = phase if phase != 'normal' else ''
    # Exercise the actual existing proxy entry, including legacy no/EOF behavior.
    # Assertions on certificate state prove missing integration independently.
    driver = c.driver(function, [function])
    result = c.execute(['bash', driver], stdin)
    c.require(result.returncode != 125, 'reverse-proxy certificate integration interfaces are absent')
    cancelled = choice.startswith('eof-') or choice in ['invalid-directory', 'duplicate'] or phase in ['validate', 'reload-once']
    if cancelled:
        c.require(result.returncode != 0, 'failed/cancelled proxy must return nonzero')
        unchanged(c)
        c.require(settings(c) == before and not c.dest.exists(), 'failed/cancelled proxy prematurely wrote certificate state/destination')
        no_worker(c)
        if phase != 'normal':
            c.require(any(x['event'] == 'fault' for x in c.trace()), 'proxy fault injection did not activate')
        return
    c.require(result.returncode == 0 or phase == 'timer', 'successful proxy returned failure: ' + c.operation_output(result) + result.stderr)
    c.require(DOMAIN in c.config.read_text() and DOMAIN in c.registry.read_text(), 'proxy was not committed')
    c.require('retain manual site' in c.config.read_text(), 'proxy overwrote manual sites')
    c.validate()
    if choice in ['saved-yes', 'new-yes']:
        c.require((c.state / 'export-directory').is_file() and (c.state / 'export-domains').is_file(), 'successful opt-in proxy did not create certificate state')
        c.require((c.state / 'export-directory').read_text().strip() == str(c.dest), 'proxy did not save chosen destination')
        c.require(DOMAIN in (c.state / 'export-domains').read_text().splitlines(), 'proxy yes did not register only opted-in domain')
        if phase == 'timer':
            c.require(any(x['event'] == 'fault' and x.get('kind') == 'timer-install' for x in c.trace()), 'timer install failure not injected')
            c.require(re.search(r'同步.*(未|失败)|--sync-certificates|未启用|安装失败', c.operation_output(result) + result.stderr), 'successful proxy failed to report separate worker-install problem')
        else:
            assert_worker(c)
    else:
        no_worker(c)
        if choice == 'existing-no':
            c.require((c.state / 'export-domains').read_text().splitlines() == [OTHER], 'no on existing domain failed to opt it out/preserved other domains')
        else:
            c.require(settings(c) == before, 'no/default-no changed export state')


def assert_worker(c):
    service, timer = c.units / 'easy-caddy-cert-sync.service', c.units / 'easy-caddy-cert-sync.timer'
    snapshot = c.worker / 'easyCaddy.sh'
    c.require(service.is_file() and timer.is_file() and snapshot.is_file(), 'opt-in lacks service/timer/single-file snapshot')
    service_text, timer_text = service.read_text(), timer.read_text()
    c.require('Type=oneshot' in service_text and re.search(r'UMask=0?077', service_text), 'service must be oneshot with restrictive UMask')
    c.require('--sync-certificates' in service_text and str(snapshot) in service_text, 'service CLI must point at installed script snapshot')
    for setting in ['OnBootSec=1min', 'OnUnitActiveSec=1min', 'AccuracySec=1s']:
        c.require(setting in timer_text, 'timer missing fixed cadence: ' + setting)
    c.require(any(x['tool'] == 'systemctl' and 'enable' in x['argv'] and '--now' in x['argv'] for x in c.trace()), 'timer not enabled --now')
    c.require(snapshot.read_bytes() == c.suite.source_bytes, 'worker snapshot is not a standalone byte-exact product')
    c.require(not (snapshot.stat().st_mode & 0o022), 'worker snapshot writable by group/others')
    c.require_clean_tools()


def worker(c):
    c.state_fixture()
    result = c.invoke('install_certificate_sync_timer')
    c.require(result.returncode == 0, 'opt-in worker installation failed')
    assert_worker(c)
    c.product.unlink()
    c.source('rsa')
    # Initial foreground process is gone and original source no longer exists.
    snapshot = c.worker / 'easyCaddy.sh'
    first = c.execute(['bash', snapshot, '--sync-certificates'])
    c.require(first.returncode == 0 and '请输入选项' not in first.stdout, 'worker snapshot cannot sync in independent process after original exit/removal')
    c.assert_pair()
    renewed = c.source('renewed')
    second = c.execute(['bash', snapshot, '--sync-certificates', DOMAIN])
    c.require(second.returncode == 0, 'standalone renewal invocation failed')
    c.assert_pair(renewed)


def lock_serialisation(c, operation):
    c.source('rsa')
    c.state_fixture()
    # First establish that the interface really exists before parallel calls.
    result = c.execute(['bash', c.driver(':', ['sync_certificates', 'set_certificate_export_directory', 'unregister_certificate_export'])])
    c.require(result.returncode == 0, 'lock test requires real frozen interfaces')
    firstenv = c.env.copy()
    firstenv['TEST_BLOCK_OPENSSL'] = '1'
    first = c.background('sync_certificates', env=firstenv)
    deadline = time.monotonic() + 8
    while not (c.root / 'block-active').exists() and first.poll() is None and time.monotonic() < deadline:
        time.sleep(.02)
    c.require((c.root / 'block-active').exists(), 'sync did not reach fixture certificate-read barrier')
    new = c.root / 'new export'
    second = c.background('set_certificate_export_directory', new) if operation == 'directory' else c.background('unregister_certificate_export', DOMAIN)
    time.sleep(.25)
    if second.poll() == 0:
        raise ProductFailure('state mutation succeeded while sync held certificate read barrier')
    (c.root / 'block-release').touch()
    code1, code2 = first.wait(timeout=12), second.wait(timeout=12)
    c.require(code1 == 0, 'first synchronised export failed')
    if code2 != 0:
        # Busy refusal is allowed, but retry after lock release must work.
        retry = c.invoke('set_certificate_export_directory', new) if operation == 'directory' else c.invoke('unregister_certificate_export', DOMAIN)
        c.require(retry.returncode == 0, 'state mutation retry after lock release failed')
    c.assert_pair()


def editor(c, kind):
    if kind == 'visual-argv':
        c.env['VISUAL'] = str(c.root / 'bin/editor') + ' --acceptance-flag'
        c.env['EDITOR'] = '/nonexistent/editor'
    elif kind == 'editor-injection':
        c.env['EDITOR'] = str(c.root / 'bin/editor') + ' ; touch ' + str(c.root / 'injected')
    else:
        c.env['TEST_EDITOR_MODE'] = kind
    if kind in ['reload-once', 'reload-always', 'reload-external']:
        c.env['TEST_EDITOR_MODE'] = 'copy'
        c.env['TEST_FAULT'] = kind
    before = record_tree(c.config)
    result = c.invoke('manual_edit_caddyfile')
    c.require(c.registry.read_bytes() == c.original_registry, 'manual editor rewrote legacy registry')
    c.require((c.root / 'Caddyfile.bak').read_bytes() == b'existing backup must survive\n', 'manual editor overwrote old .bak')
    if kind in ['copy', 'visual-argv']:
        c.require(result.returncode == 0 and c.config.read_bytes() == (c.root / 'candidate.caddy').read_bytes(), 'valid edited candidate was not committed')
        c.require((c.config.stat().st_mode & 0o777) == 0o640 and c.config.stat().st_uid == before['.']['uid'], 'editor changed live owner/mode')
        c.require(len(c.validators()) >= 1 and len(c.reloads()) == 1, 'valid editor must validate then reload exactly once')
        events = c.trace()
        vi = next(i for i, x in enumerate(events) if x['tool'] == 'caddy' and x['argv'] and x['argv'][0] == 'validate')
        ri = next(i for i, x in enumerate(events) if x['tool'] == 'systemctl' and 'reload' in x['argv'])
        c.require(vi < ri, 'reload occurred before validator success')
        backups = [p for p in c.root.iterdir() if p.is_file() and p.name not in ['Caddyfile', 'Caddyfile.bak'] and p.read_bytes() == c.original_config]
        c.require(backups, 'unique same-directory original backup was not retained')
        for path in backups:
            c.require((path.stat().st_mode & 0o777) & ~0o640 == 0, 'unique backup permissions are broader than live file')
        if kind == 'visual-argv':
            c.require('--acceptance-flag' in (c.root / 'editor-trace.txt').read_text(), 'VISUAL argv flags not safely passed')
        c.validate()
    elif kind == 'none':
        c.require(result.returncode == 0 and record_tree(c.config) == before, 'no-change editor must preserve file/metadata')
        c.require(not c.validators() and not c.reloads(), 'unchanged candidate triggered validate/reload')
    elif kind in ['external', 'external-symlink']:
        c.require(result.returncode != 0 and c.config.read_bytes() == (c.root / 'external.caddy').read_bytes(), 'external edit during editor was overwritten')
        c.require(not c.reloads(), 'conflict must not reload')
    elif kind == 'editor-injection':
        c.require(not (c.root / 'injected').exists(), 'editor command string executed shell metacharacters')
        if result.returncode == 0:
            c.require(c.config.read_bytes() == (c.root / 'candidate.caddy').read_bytes() and len(c.reloads()) == 1, 'safely parsed editor argv did not apply its valid candidate')
        else:
            c.require(c.config.read_bytes() == c.original_config and not c.reloads(), 'rejected editor command changed live state')
    elif kind == 'reload-external':
        c.require(any(x.get('kind') == 'reload-external' for x in c.trace()), 'reload external mutation fault did not activate')
        c.require(result.returncode != 0 and c.config.read_bytes() == (c.root / 'external.caddy').read_bytes(), 'reload rollback overwrote external edit')
        c.require(re.search(r'外部|变化|冲突|恢复|rollback|conflict', c.operation_output(result) + result.stderr, re.I), 'rollback conflict lacks diagnostic')
    elif kind in ['reload-once', 'reload-always']:
        c.require(any(x.get('kind') == 'reload' for x in c.trace()), 'reload failure injector did not activate')
        c.require(result.returncode != 0 and c.config.read_bytes() == c.original_config, 'reload failure did not restore live original')
        c.require(len(c.reloads()) >= 2, 'rollback must attempt recovery reload')
        if kind == 'reload-always':
            c.require(re.search(r'恢复.*失败|reload.*失败|recovery|无法.*恢复', c.operation_output(result) + result.stderr, re.I), 'recovery reload failure lacks diagnosis')
        c.validate()
    else:
        c.require(result.returncode != 0 and c.config.read_bytes() == c.original_config, 'bad/editor-failed/unsafe draft was committed: ' + kind)
        c.require(not c.reloads() and not (c.root / 'injected').exists(), 'failed editor reloaded or executed injected command')
        if kind in ['invalid', 'fail']:
            target = (c.root / ('invalid.caddy' if kind == 'invalid' else 'candidate.caddy')).read_bytes()
            drafts = [p for p in (c.root / 'tmp').rglob('*') if p.is_file() and not p.is_symlink() and p.read_bytes() == target]
            # Product may put the secure draft directory next to Caddyfile.
            drafts += [p for p in c.root.glob('*/**/*') if p.is_file() and not p.is_symlink() and p not in [c.root / 'candidate.caddy', c.root / 'invalid.caddy'] and p.read_bytes() == target]
            c.require(drafts, 'changed failed draft was deleted instead of retained')
            c.require(any(str(p) in c.operation_output(result) + result.stderr or str(p.parent) in c.operation_output(result) + result.stderr for p in drafts), 'retained draft location was not reported')
    c.require_clean_tools()


def apply_editor(c, valid):
    source = c.root / ('candidate.caddy' if valid else 'invalid.caddy')
    before = source.read_bytes()
    result = c.invoke('apply_manual_caddyfile', source)
    c.require(source.read_bytes() == before, 'noninteractive apply modified caller-owned candidate')
    c.require(c.registry.read_bytes() == c.original_registry, 'noninteractive manual apply changed registry')
    if valid:
        c.require(result.returncode == 0 and c.config.read_bytes() == before and len(c.reloads()) == 1, 'noninteractive valid manual candidate did not apply')
        c.validate()
    else:
        c.require(result.returncode != 0 and not c.reloads(), 'noninteractive invalid manual candidate not refused')
        unchanged(c)


def acceptance_cases(suite):
    suite.case('U1-source-safe', source_safe)
    suite.case('U1-nine-interfaces', interfaces)
    suite.case('U1-menu-8-9-dispatch', menus)
    suite.case('W1-unknown-cli', cli_unknown)
    suite.case('S1-public-list', listing)
    suite.case('S3-directory-only', directory_only)
    suite.case('S3-path-data-no-eval', directory_data)
    suite.case('S3-registration-idempotent', registration)
    for kind in ['command', 'slash', 'newline', 'wildcard', 'semicolon']:
        suite.case('S3-domain-reject-' + kind, lambda c, k=kind: invalid_domain(c, k))
    for kind in ['relative', 'root', 'system-top', 'storage', 'within-storage', 'contains-storage', 'config', 'state', 'registry', 'worker', 'unit', 'newline', 'control', 'symlink', 'linked-ancestor', 'foreign-owner']:
        suite.case('S3-directory-reject-' + kind, lambda c, k=kind: directory_bad(c, k))
    for kind in ['rsa', 'ec']:
        suite.case('S1-sync-valid-' + kind, lambda c, k=kind: sync_valid(c, k))
    suite.case('S1-pending', sync_pending)
    suite.case('W1-empty-no-scan', sync_empty)
    for kind in ['latest', 'notbefore', 'lexical']:
        suite.case('S1-select-' + kind, lambda c, k=kind: selection(c, k))
    for kind in ['expired', 'future', 'wrong-san', 'mismatch', 'invalid-pem', 'missing-key', 'key-symlink', 'cert-symlink', 'key-hardlink']:
        suite.case('S1-reject-' + kind, lambda c, k=kind: bad_certificate(c, k))
    suite.case('S1-unregistered-domain', registration_scope)
    suite.case('W1-noninteractive-cli', lambda c: registration_scope(c, True))
    for kind in ['domain-symlink', 'key-symlink', 'cert-symlink', 'hardlink', 'half-pair', 'invalid-existing-pair', 'foreign-owner']:
        suite.case('S3-export-reject-' + kind, lambda c, k=kind: destination_unsafe(c, k))
    suite.case('S2-renewal-idempotency', renew)
    for fault in ['export-commit', 'export-stage-key']:
        suite.case('S2-write-failure-' + fault, lambda c, f=fault: renew(c, f))
    suite.case('S4-source-rotation', rotation)
    suite.case('S3-directory-change', directory_change)
    suite.case('S3-unregister-only-one', unregister)
    for kind in ['directory-lines', 'domains-command', 'state-symlink', 'state-hardlink']:
        suite.case('S3-corrupt-state-' + kind, lambda c, k=kind: bad_state(c, k))
    for kind in ['home', 'xdg', 'home-override', 'xdg-override', 'literal', 'stopped-literal', 'stopped-default', 'stopped-environment-file', 'template', 'unresolved-template', 'adapt-failure', 'unknown-module', 'policy-override', 'uncertain-home']:
        suite.case('D1-storage-' + kind, lambda c, k=kind: storage(c, k))
    for entry in ['local', 'remote']:
        for choice in ['saved-yes', 'new-yes', 'no', 'default-no', 'eof-domain', 'eof-upstream', 'eof-choice', 'eof-directory', 'invalid-directory', 'existing-no', 'duplicate']:
            suite.case('U1-proxy-' + entry + '-' + choice, lambda c, e=entry, h=choice: proxy(c, e, h))
        for fault in ['validate', 'reload-once', 'timer']:
            suite.case('U1-proxy-' + entry + '-failure-' + fault, lambda c, e=entry, f=fault: proxy(c, e, 'new-yes', f))
    suite.case('W1-snapshot-after-exit-renewal', worker)
    for operation in ['directory', 'unregister']:
        suite.case('S4-lock-' + operation, lambda c, o=operation: lock_serialisation(c, o))
    for kind in ['copy', 'none', 'invalid', 'fail', 'delete', 'symlink', 'directory', 'external', 'external-symlink', 'visual-argv', 'editor-injection', 'reload-once', 'reload-always', 'reload-external']:
        suite.case('E1-E2-editor-' + kind, lambda c, k=kind: editor(c, k))
    suite.case('E1-apply-valid', lambda c: apply_editor(c, True))
    suite.case('E1-apply-invalid', lambda c: apply_editor(c, False))


def imported_editor(c, api, kind):
    """Real file-relative imports; controls never use the product validator."""
    good = c.root / 'snippets'
    good.mkdir()
    (good / 'sites.caddy').write_text('http://imported.test {\n respond "included"\n}\n')
    live_import = 'snippets/sites.caddy'
    if kind in ['glob', 'glob-invalid']:
        live_import = 'snippets/*.caddy'
    if kind == 'empty-glob':
        (c.root / 'empty-snippets').mkdir()
        live_import = 'empty-snippets/*.caddy'
    candidate_import = live_import
    invalid = kind in ['relative-invalid', 'glob-invalid', 'missing-explicit']
    if kind in ['relative-invalid', 'glob-invalid']:
        bad = c.root / 'bad-snippets'
        bad.mkdir()
        (bad / 'sites.caddy').write_text('http://invalid-included.test {\n acceptance_invalid_directive\n}\n')
        candidate_import = 'bad-snippets/*.caddy' if kind == 'glob-invalid' else 'bad-snippets/sites.caddy'
    elif kind == 'missing-explicit':
        candidate_import = 'missing-explicit.caddy'
    c.config.write_text(c.configuration('original') + 'import ' + live_import + '\n')
    candidate = c.root / 'candidate.caddy'
    candidate.write_text(c.configuration('edited') + 'import ' + candidate_import + '\n')
    c.original_config = c.config.read_bytes()
    source_before = candidate.read_bytes()
    before = record_tree(c.config)
    includes_before = {p.name: record_tree(p) for p in c.root.iterdir() if p.is_dir() and 'snippets' in p.name}
    live_control = c.validate(c.config)
    candidate_control = c.validate(candidate, expected=not invalid)
    # Metadata-only receipt; full real Caddy stdout/stderr/exit already in step files.
    (c.root / 'import-controls.json').write_text(json.dumps({
        'api': api, 'kind': kind, 'live_exit': live_control.returncode,
        'same_directory_candidate_exit': candidate_control.returncode,
        'empty_glob_allowed': kind == 'empty-glob', 'real_caddy': c.suite.tools['caddy']}, indent=2))
    result = c.invoke('apply_manual_caddyfile', candidate) if api == 'apply' else c.invoke('manual_edit_caddyfile')
    c.require(candidate.read_bytes() == source_before, 'import editor changed caller fixture')
    c.require(c.registry.read_bytes() == c.original_registry, 'import editor changed proxy registry')
    c.require(includes_before == {p.name: record_tree(p) for p in c.root.iterdir() if p.is_dir() and 'snippets' in p.name}, 'editor changed included files')
    if invalid:
        c.require(result.returncode != 0 and record_tree(c.config) == before and not c.reloads(), 'invalid/missing included config was committed or live changed: ' + kind)
    else:
        c.require(result.returncode == 0 and c.config.read_bytes() == source_before, 'real-valid file-relative import candidate refused: ' + api + '/' + kind + ': ' + result.stderr)
        c.require(len(c.validators()) >= 1 and len(c.reloads()) == 1, 'import candidate must really validate then reload once')
        c.require((c.config.stat().st_mode & 0o777) == 0o640 and c.config.stat().st_uid == before['.']['uid'], 'import edit changed live owner/mode')
        c.validate()
    c.require_clean_tools()


def imported_storage(c, nested, management_missing):
    """Adapt with actual NUL /proc service env and a different management env."""
    c.env.pop('CERT_STORAGE_DIR_OVERRIDE')
    var = 'EASY_CADDY_IMPORTED_STORAGE_ROOT'
    expected = c.root / 'service root with spaces'
    management = c.root / 'management wrong root'
    sentinel = 'IMPORTED_ENV_BODY_MUST_NOT_BE_DISCLOSED'
    c.env.pop(var, None)
    child = c.service_process(extra={var: str(expected), 'UNRELATED_IMPORT_PRIVATE_ENV': sentinel})
    # Parse NUL records locally; do not print or serialize the environment body.
    records = Path('/proc/' + str(child.pid) + '/environ').read_bytes().split(b'\0')
    selected = {}
    for entry in records:
        key, sep, value = entry.partition(b'=')
        if sep and key.decode(errors='replace') in [var, 'HOME', 'XDG_DATA_HOME']:
            selected[key.decode()] = value.decode()
    if selected.get(var) != str(expected):
        raise RuntimeError('actual /proc service environment fixture absent')
    imported = c.root / 'storage.inc'
    imported.write_text('storage file_system {\n root "{$' + var + '}"\n}\n')
    if nested:
        (c.root / 'outer.inc').write_text('import storage.inc\n')
    c.config.write_text('{\n admin off\n auto_https off\n import ' + ('outer.inc' if nested else 'storage.inc') + '\n}\nhttp://before.test {\n respond original\n}\n')
    service_env = c.env.copy()
    service_env.update(selected)
    control = c.execute([c.suite.tools['caddy'], 'adapt', '--adapter', 'caddyfile', '--config', c.config], env=service_env)
    if control.returncode != 0 or json.loads(control.stdout).get('storage', {}).get('root') != str(expected):
        raise RuntimeError('real Caddy service-env import positive control failed: ' + control.stderr)
    if not management_missing:
        c.env[var] = str(management)
    management_control = c.execute([c.suite.tools['caddy'], 'adapt', '--adapter', 'caddyfile', '--config', c.config])
    management_root = json.loads(management_control.stdout).get('storage', {}).get('root') if management_control.returncode == 0 else None
    if not management_missing and management_root != str(management):
        raise RuntimeError('real Caddy management-env contrasting control failed')
    (c.root / 'import-controls.json').write_text(json.dumps({
        'mocked_systemctl_MainPID': child.pid, 'actual_proc_NUL_read': True,
        'nested': nested, 'management_variable_missing': management_missing,
        'service_adapt_exit': control.returncode, 'service_root': str(expected),
        'management_adapt_exit': management_control.returncode, 'management_root': management_root,
        'env_body_recorded': False}, indent=2))
    before = c.observed()
    result = c.invoke('certificate_storage_root')
    output = c.operation_output(result).strip()
    diagnostic = output + result.stderr
    c.require(sentinel not in result.stdout + result.stderr and 'UNRELATED_IMPORT_PRIVATE_ENV=' not in diagnostic,
              'storage import discovery leaked unrelated service environment')
    if result.returncode == 0:
        c.require(output.splitlines() == [str(expected)], 'imported env root silently used management/default root: ' + output)
    else:
        c.require(bool(diagnostic.strip()), 'refused imported storage without diagnosis')
    c.require(c.observed() == before, 'storage discovery mutated case files/state')
    no_worker(c)
    c.require_clean_tools()


def import_regression_cases(suite):
    for api in ['apply', 'interactive']:
        for kind in ['relative', 'glob', 'empty-glob', 'relative-invalid', 'glob-invalid', 'missing-explicit']:
            suite.case('I3-editor-' + api + '-' + kind, lambda c, a=api, k=kind: imported_editor(c, a, k))
    for nested in [False, True]:
        for missing in [False, True]:
            suite.case('I3-storage-' + ('nested' if nested else 'direct') + '-' + ('management-missing' if missing else 'management-different'),
                       lambda c, n=nested, m=missing: imported_storage(c, n, m))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--caddy-bin', default='/usr/bin/caddy')
    parser.add_argument('--script', default=str(Path(__file__).resolve().parent.parent / 'easyCaddy.sh'))
    parser.add_argument('--evidence-dir', default='/tmp/easy-caddy-certificates-editor-tests')
    args = parser.parse_args()
    if sys.platform != 'linux':
        parser.error('Linux is required; Windows/MINGW permission emulation is not accepted')
    evidence = Path(args.evidence_dir).resolve()
    if not evidence.is_relative_to(Path('/tmp')):
        parser.error('--evidence-dir must be under /tmp (no production writes)')
    evidence.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='verifier-', dir=evidence))
    root.chmod(0o700)
    print('EVIDENCE=' + str(root), flush=True)
    try:
        suite = Suite(args, root)
        acceptance_cases(suite)
        import_regression_cases(suite)
        suite.save()
        counts = {key: sum(x['status'] == key for x in suite.results) for key in ('passed', 'failed', 'error')}
        print('COUNTS=' + json.dumps(counts), flush=True)
        return 0 if counts['failed'] == counts['error'] == 0 else 1
    except Exception as exc:
        (root / 'preflight-error.txt').write_text(type(exc).__name__ + ': ' + str(exc), encoding='utf-8')
        (root / 'summary.json').write_text(json.dumps({'preflight_error': str(exc), 'counts': {'passed': 0, 'failed': 0, 'error': 1}}, indent=2), encoding='utf-8')
        print('PREFLIGHT ERROR: ' + str(exc), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
