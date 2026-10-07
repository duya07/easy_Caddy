#!/usr/bin/env python3
"""Isolated development regressions for easy_Caddy (Python is not a product dependency).
Run on Linux; real validators required. Services are mocked; never installs or runs daemons.
Each case keeps its source, driver, initial/final files, engine/service trace and result.
"""
import argparse
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

DOMAIN = 'target.test'
UPSTREAM = 'http://127.0.0.1:18080'


def quote(value):
    return shlex.quote(str(value))


def execute(argv, directory, environment, stdin=None):
    return subprocess.run(argv, cwd=directory, env=environment, input=stdin,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, encoding='utf-8', errors='replace', timeout=45)


def snapshot(paths):
    result = {}
    for path in paths:
        if path.is_symlink():
            result[str(path)] = ('symlink', os.readlink(path))
        elif path.is_file():
            result[str(path)] = ('file', path.read_bytes().hex())
        elif path.is_dir():
            result[str(path)] = ('directory', None)
        else:
            result[str(path)] = ('absent', None)
    return result


class Case:
    def __init__(self, suite, component, name):
        self.suite, self.component, self.name = suite, component, name
        self.root = suite.root / (component + '-' + name)
        self.root.mkdir()
        for item in ['tmp', 'home', 'bin', 'available', 'enabled']:
            (self.root / item).mkdir()
        self.config = self.root / ('Caddyfile' if component == 'caddy' else 'available/target.test')
        self.registry = self.root / 'registry'
        self.link = self.root / 'enabled/target.test'
        self.trace = self.root / 'trace.txt'
        self.master = self.root / 'nginx.conf'
        self.fault = ''
        self.body = ''
        self.stdin = ''
        self.environment = os.environ.copy()
        self.environment.update(HOME=str(self.root/'home'), TMPDIR=str(self.root/'tmp'),
                                XDG_CONFIG_HOME=str(self.root/'home/config'),
                                XDG_DATA_HOME=str(self.root/'home/data'),
                                PATH=str(self.root/'bin') + os.pathsep + os.environ.get('PATH', ''),
                                AUDIT_ROOT=str(self.root), AUDIT_TRACE=str(self.trace),
                                AUDIT_FAULT='', AUDIT_DEST='')
        self.registry.write_bytes(b'')
        self.prefix = ('{\n admin off\n auto_https off\n storage file_system {\n  root '+str(self.root/'storage')+'\n }\n}\n\n# prefix bytes\nhttp://before.test {\n respond "before"\n}\n\n')
        self.suffix = '\n# suffix bytes\nhttp://after.test {\n respond "after"\n}\n'
        if component == 'caddy':
            self.config.write_text(self.prefix + self.suffix, encoding='utf-8')
        else:
            self.master.write_text('pid '+str(self.root/'nginx.pid')+';\nerror_log '+str(self.root/'error.log')+';\nevents {}\nhttp {\n access_log off;\n client_body_temp_path '+str(self.root/'body')+';\n proxy_temp_path '+str(self.root/'proxy')+';\n fastcgi_temp_path '+str(self.root/'fastcgi')+';\n uwsgi_temp_path '+str(self.root/'uwsgi')+';\n scgi_temp_path '+str(self.root/'scgi')+';\n include '+str(self.root/'enabled/*')+';\n}\n', encoding='utf-8')
        self.install_wrappers()

    def install_wrappers(self):
        for tool in ['cp', 'mv', 'tee', 'ln']:
            real = shutil.which(tool, path=os.environ.get('PATH'))
            if not real:
                raise RuntimeError('required utility missing: '+tool)
            # Once-only fault at externally observable destination, regardless of staging helper.
            text = '''#!/bin/bash
last="${!#}"
if [[ "$AUDIT_FAULT" == "commit" && "$last" == "$AUDIT_DEST" && ! -e "$AUDIT_ROOT/fault-used" ]]; then
 printf "FAULT commit %s %s\\n" TOOL "$last" >> "$AUDIT_TRACE"
 : > "$AUDIT_ROOT/fault-used"
 if [[ TOOL == tee ]]; then cat >/dev/null; fi
 exit 76
fi
if [[ TOOL == ln ]]; then
 printf "LINK destination=%s\\n" "$last" >> "$AUDIT_TRACE"
 if [[ "$AUDIT_FAULT" == link && "$last" == "$AUDIT_DEST" && ! -e "$AUDIT_ROOT/fault-used" ]]; then
  : > "$AUDIT_ROOT/fault-used"
  site_present=0; link_present=0
  if [[ -f "$AUDIT_SITE" ]]; then
   site_present=1; cat -- "$AUDIT_SITE" > "$AUDIT_ROOT/fault-site.txt"
  fi
  [[ -e "$last" || -L "$last" ]] && link_present=1
  printf "FAULT link destination=%s site_present=%s link_present=%s\\n" "$last" "$site_present" "$link_present" >> "$AUDIT_TRACE"
  exit 78
 fi
fi
exec REAL "$@"
'''.replace('TOOL', quote(tool)).replace('REAL', quote(real))
            self.wrapper(tool, text)
        for engine, binary in [('caddy', self.suite.caddy), ('nginx', self.suite.nginx)]:
            if not binary:
                continue
            text = '#!/bin/bash\nprintf "ENGINE '+engine+' %s\\n" "$*" >> "$AUDIT_TRACE"\n'
            if engine == 'caddy':
                text += '[[ "$1" == validate || "$1" == adapt || "$1" == version ]] || { echo "blocked daemon command"; exit 90; }\nexec '+quote(binary)+' "$@"\n'
            else:
                text += 'args=("$@"); cfg=""; has_test=0\nfor ((i=0;i<${#args[@]};i++)); do [[ "${args[i]}" == -t ]] && has_test=1; [[ "${args[i]}" == -c ]] && cfg="${args[i+1]}"; done\n[[ "$has_test" == 1 ]] || { echo "blocked daemon command"; exit 90; }\nif [[ -n "$cfg" && "$cfg" != "$AUDIT_ROOT/"* ]]; then echo "blocked non-sandbox nginx config"; exit 90; fi\nif [[ -z "$cfg" ]]; then args+=(-c "$AUDIT_ROOT/nginx.conf"); fi\nexec '+quote(binary)+' -p "$AUDIT_ROOT/" -e "$AUDIT_ROOT/engine-error.log" "${args[@]}"\n'
            self.wrapper(engine, text)
        self.wrapper('systemctl', '#!/bin/bash\nprintf "SERVICE %s\\n" "$*" >> "$AUDIT_TRACE"\ncase "$1" in\n reload|restart) [[ "$AUDIT_FAULT" == reload ]] && exit 77; exit 0;;\n status|is-active) exit 0;;\n *) echo "blocked unexpected service action"; exit 90;;\nesac\n')
        self.wrapper('sudo', '#!/bin/bash\n[[ "$1" == -- ]] && shift\ncase "$1" in cp|mv|tee|ln|rm|systemctl|caddy|nginx|mktemp|cat|awk|chmod|mkdir|sed|touch|stat|cut|tr|head|tail|grep|readlink|sort|wc|cmp) exec "$@";; *) echo "blocked sudo command $1"; exit 90;; esac\n')
        for blocked in ['apt', 'apt-get', 'yum', 'dnf', 'service', 'docker', 'curl', 'wget']:
            self.wrapper(blocked, '#!/bin/bash\necho "blocked external operation"; exit 90\n')

    def wrapper(self, name, text):
        path = self.root/'bin'/name
        path.write_text(text, encoding='utf-8')
        path.chmod(0o755)

    def caddy_site(self, interior=' reverse_proxy http://127.0.0.1:18080\n', header='target.test {', crlf=False):
        block = header+'\n'+interior+'}\n'
        if crlf:
            block = block.replace('\n', '\r\n')
        self.config.write_bytes((self.prefix+block+self.suffix).encode())
        self.registry.write_text('target.test -> '+UPSTREAM+'\n', encoding='utf-8')
        return (self.prefix+self.suffix).encode()

    def nginx_site(self, manual=False):
        extra = '    # retain manual comment {\n    client_max_body_size 17m;\n    add_header X-Manual "kept" always;\n    location /admin { deny all; }\n' if manual else ''
        inside = '        proxy_read_timeout 37s;\n' if manual else ''
        self.config.write_text('server {\n    listen 127.0.0.1:18654;\n    server_name target.test;\n'+extra+'    location / {\n'+inside+'        proxy_pass '+UPSTREAM+';\n        proxy_set_header Host 127.0.0.1:18080;\n    }\n}\n', encoding='utf-8')
        self.link.symlink_to(self.config)

    def invoke(self, function, *arguments, stdin=''):
        self.body = function + ''.join(' '+quote(a) for a in arguments)
        self.stdin = stdin

    def validate(self):
        if self.component == 'caddy':
            args = [self.suite.caddy, 'validate', '--adapter', 'caddyfile', '--config', str(self.config)]
        else:
            args = [self.suite.nginx, '-t', '-p', str(self.root)+'/', '-e', str(self.root/'engine-error.log'), '-c', str(self.master)]
        result = execute(args, self.root, self.environment)
        with (self.root/'validator-output.txt').open('a', encoding='utf-8') as out:
            out.write(json.dumps(args)+'\n'+result.stdout+'\nEXIT='+str(result.returncode)+'\n')
        return result.returncode == 0

    def run(self, check, initial_valid=True):
        def tracked_paths():
            if self.component == 'caddy':
                return [self.config, self.registry]
            return [self.root/'victim'] + sorted((self.root/'available').rglob('*')) + sorted((self.root/'enabled').rglob('*'))
        before = snapshot(tracked_paths())
        (self.root/'before.json').write_text(json.dumps(before, indent=2), encoding='utf-8')
        if initial_valid and not self.validate():
            raise RuntimeError('fixture did not pass real validator: '+self.name)
        source = self.suite.sources[self.component]
        match = re.search(r'^while true; do\s*$', source, re.M)
        if not match:
            raise RuntimeError('cannot find main menu boundary in '+self.component)
        library = source[:match.start()]
        for original, replacement in [('/etc/caddy/Caddyfile', str(self.config)),
                                      ('/root/caddy_reverse_proxies.txt', str(self.registry)),
                                      ('/etc/caddy', str(self.root)),
                                      ('/etc/nginx/sites-available', str(self.root/'available')),
                                      ('/etc/nginx/sites-enabled', str(self.root/'enabled')),
                                      ('/etc/nginx/nginx.conf', str(self.master)),
                                      ('/etc/nginx', str(self.root))]:
            library = library.replace(original, replacement)
        (self.root/'library.sh').write_text(library, encoding='utf-8')
        driver = ('#!/bin/bash\n'
                  'id() { if [[ "$1" == -u ]]; then printf "0\\n"; else command id "$@"; fi; }\n'
                  'source '+quote(self.root/'library.sh')+'\n'
                  'check_remote_upstream() { :; }\ncheck_port_running() { :; }\n'
                  'NGINX_MAIN_CONFIG='+quote(self.master)+'\nNGINX_CONFIG_FILE='+quote(self.master)+'\n'
                  +self.body+'\nrc=$?\nprintf "FUNCTION_EXIT=%s\\n" "$rc"\nexit "$rc"\n')
        (self.root/'driver.sh').write_text(driver, encoding='utf-8')
        self.environment.update(AUDIT_FAULT=self.fault, AUDIT_DEST=str(getattr(self, 'fault_dest', self.config)),
                                AUDIT_SITE=str(getattr(self, 'fault_site', self.config)))
        result = execute(['bash', str(self.root/'driver.sh')], self.root, self.environment, self.stdin)
        (self.root/'output.txt').write_text(result.stdout, encoding='utf-8')
        after = snapshot(tracked_paths())
        (self.root/'after.json').write_text(json.dumps(after, indent=2), encoding='utf-8')
        trace = self.trace.read_text(encoding='utf-8') if self.trace.exists() else ''
        valid = self.validate()
        passed, reason = check(result.returncode, before == after, trace, valid, result.stdout)
        record = {'component': self.component, 'case': self.name, 'passed': passed, 'reason': reason,
                  'function_exit': result.returncode, 'unchanged': before == after, 'post_valid': valid,
                  'source_sha256': hashlib.sha256(source.encode()).hexdigest(), 'evidence': str(self.root),
                  'trace': trace}
        self.suite.results.append(record)
        print(('PASS ' if passed else 'FAIL ')+self.component+'/'+self.name+': '+reason, flush=True)


def no_success(output):
    # Product success messages, excluding explicit failure/recovery diagnostics.
    return not re.search(r'配置完成|反向代理目标已更新|配置已删除|(?:删除|添加|设置|重启|重载|反向代理)[^\n！!]*成功', output)


def validated_before_service(component, trace):
    lines = trace.splitlines()
    validators = [i for i, line in enumerate(lines) if line.startswith('ENGINE '+component+' ') and ('validate' in line if component == 'caddy' else '-t' in line)]
    services = [i for i, line in enumerate(lines) if line.startswith(('SERVICE reload', 'SERVICE restart'))]
    return bool(validators and services and validators[0] < services[0])


def reject_check(require_failure=False):
    def check(rc, unchanged, trace, valid, output):
        ok = unchanged and no_success(output) and 'SERVICE reload' not in trace and 'SERVICE restart' not in trace
        if require_failure:
            ok = ok and rc != 0
        return ok, 'must preserve files, avoid service application'+(' and return nonzero' if require_failure else '')
    return check


def committed_check(component):
    def check(rc, unchanged, trace, valid, output):
        ok = rc == 0 and not unchanged and valid and validated_before_service(component, trace)
        return bool(ok), 'successful commit needs real candidate validation before simulated service application'
    return check


def final_link_check(case, rc, unchanged, trace, valid, output):
    lines = trace.splitlines()
    marker = 'FAULT link destination='+str(case.fault_dest)+' site_present=1 link_present=0'
    faults = [i for i, line in enumerate(lines) if line == marker]
    validators = [i for i, line in enumerate(lines) if line.startswith('ENGINE nginx ') and '-t' in line]
    candidate_links = [i for i, line in enumerate(lines) if line.startswith('LINK destination=') and '/enabled/' in line and line != 'LINK destination='+str(case.fault_dest) and not line.startswith('LINK destination='+str(case.root/'enabled')+'/')]
    capture = case.root/'fault-site.txt'
    committed = (capture.is_file() and b'server_name new.test;' in capture.read_bytes()
                 and b'proxy_pass http://127.0.0.1:18081;' in capture.read_bytes())
    ok = (len(faults) == 1 and validators and candidate_links
          and min(candidate_links) < min(validators) < faults[0] and committed
          and rc != 0 and unchanged and valid and no_success(output)
          and 'SERVICE reload' not in trace and 'SERVICE restart' not in trace)
    return bool(ok), 'final enabled/new.test fault after candidate links/validation and site commit; rollback exact, nonzero, no success/service'


class Suite:
    def __init__(self, options, root, caddy, nginx):
        self.root, self.caddy, self.nginx = root, caddy, nginx
        self.results = []
        repo = Path(__file__).resolve().parent.parent
        self.sources = {name: (repo/file).read_text(encoding='utf-8') for name, file in [('caddy', 'easyCaddy.sh'), ('nginx', 'easy_nginx.sh')]}

    def caddy_cases(self):
        interiors = {
            'plain-control': ' reverse_proxy '+UPSTREAM+'\n',
            'comment-open': ' # custom note: {\n reverse_proxy '+UPSTREAM+'\n',
            'comment-close': ' # custom note: }\n reverse_proxy '+UPSTREAM+'\n',
            'quoted-brace': ' respond "literal {"\n',
            'backtick-placeholder': ' header X-Test `literal {`\n respond "{http.request.method}"\n',
        }
        for name, interior in interiors.items():
            case = Case(self, 'caddy', 'R1-'+name)
            expected = case.caddy_site(interior)
            case.invoke('delete_reverse_proxy', stdin='1\n')
            def check(rc, unchanged, trace, valid, output, c=case, expected=expected):
                return rc == 0 and c.config.read_bytes() == expected and c.registry.read_bytes() == b'' and valid and validated_before_service('caddy', trace), 'delete exactly target block; retain outside bytes; validate candidate before service'
            case.run(check)
        headers = [('tail-comment', 'target.test { # managed', False), ('CRLF', 'target.test {   ', True),
                   ('quoted-scheme', '"http://target.test" {', False), ('shared-addresses', 'target.test, alias.test {', False)]
        for name, header, crlf in headers:
            case = Case(self, 'caddy', 'R5-'+name)
            expected = case.caddy_site(header=header, crlf=crlf)
            case.invoke('delete_reverse_proxy', stdin='1\n')
            def check(rc, unchanged, trace, valid, output, c=case, expected=expected, shared=name == 'shared-addresses'):
                if shared or rc != 0:
                    return reject_check(True)(rc, unchanged, trace, valid, output)
                return c.config.read_bytes() == expected and c.registry.read_bytes() == b'' and valid and validated_before_service('caddy', trace), 'recognized header deletes target only with candidate precheck, otherwise fail unchanged'
            case.run(check)
        for name in ['registry-no-LF', 'current-config-only']:
            case = Case(self, 'caddy', 'R4-'+name)
            case.caddy_site()
            case.registry.write_bytes(('target.test -> '+UPSTREAM).encode() if name == 'registry-no-LF' else b'')
            case.invoke('apply_reverse_proxy', DOMAIN, UPSTREAM)
            case.run(reject_check(True))
        case = Case(self, 'caddy', 'R4-subdomain-control')
        case.caddy_site()
        case.invoke('apply_reverse_proxy', 'sub.target.test', UPSTREAM)
        case.run(committed_check('caddy'))
        for operation in ['add', 'delete']:
            for fault in ['config-commit', 'registry-commit', 'reload']:
                case = Case(self, 'caddy', 'R3-'+operation+'-'+fault)
                case.caddy_site()
                case.fault = 'reload' if fault == 'reload' else 'commit'
                case.fault_dest = case.registry if fault == 'registry-commit' else case.config
                if operation == 'delete':
                    case.invoke('delete_reverse_proxy', stdin='1\n')
                else:
                    case.invoke('apply_reverse_proxy', 'new.test', UPSTREAM)
                def check(rc, unchanged, trace, valid, output, c=case):
                    exercised = 'SERVICE reload' in trace or 'SERVICE restart' in trace if c.fault == 'reload' else 'FAULT commit' in trace
                    return exercised and rc != 0 and unchanged and valid and no_success(output), 'fault must be reached; nonzero, both files restored, no success message'
                case.run(check)
        for number in ['abc', '0', '99']:
            case = Case(self, 'caddy', 'delete-number-'+number)
            case.caddy_site()
            case.invoke('delete_reverse_proxy', stdin=number+'\n')
            case.run(reject_check(True))

    def inputs(self, component):
        invalid = ['http://:8080', 'http://127.0.0.1:', 'http://[not-ipv6]:8080',
                   'http://{http.request.host}:8080' if component == 'caddy' else 'http://$host', 'http://127.0.0.1;',
                   'http://127.0.0.1/path']
        entry = 'setup_reverse_proxy_remote' if component == 'caddy' else 'setup_remote_proxy'
        for index, url in enumerate(invalid):
            case = Case(self, component, 'R2-invalid-URL-'+str(index))
            if component == 'nginx':
                case.nginx_site()
            case.invoke(entry, stdin='new.test\n'+url+'\n')
            case.run(reject_check())
        for index, domain in enumerate(['bad.test {', '../victim']):
            case = Case(self, component, 'invalid-domain-'+str(index))
            if component == 'nginx':
                case.nginx_site()
                (case.root/'victim').write_bytes(b'manual victim\n')
            case.invoke(entry, stdin=domain+'\n'+UPSTREAM+'\n')
            case.run(reject_check())
        case = Case(self, component, 'candidate-engine-reject')
        if component == 'caddy':
            case.config.write_text(case.prefix+'http://broken.test {\n definitely_invalid_directive\n}\n'+case.suffix, encoding='utf-8')
            case.invoke('apply_reverse_proxy', 'new.test', UPSTREAM)
        else:
            case.nginx_site()
            case.master.write_text(case.master.read_text()+'invalid_main_directive;\n', encoding='utf-8')
            case.invoke('apply_proxy_config', 'new.test', UPSTREAM)
        case.run(reject_check(True), initial_valid=False)

    def nginx_cases(self):
        case = Case(self, 'nginx', 'R6-manual-site')
        case.nginx_site(manual=True)
        manual = [b'# retain manual comment {', b'listen 127.0.0.1:18654;', b'client_max_body_size 17m;', b'add_header X-Manual "kept" always;', b'location /admin { deny all; }', b'proxy_read_timeout 37s;']
        case.invoke('modify_proxy', stdin='target.test\n18081\n')
        def check(rc, unchanged, trace, valid, output):
            if rc != 0:
                return reject_check(True)(rc, unchanged, trace, valid, output)
            text = case.config.read_bytes()
            ok, _ = committed_check('nginx')(rc, unchanged, trace, valid, output)
            return ok and all(item in text for item in manual) and b'proxy_pass http://127.0.0.1:18081;' in text, 'modify preserves manual directives and changes only target upstream/necessary headers'
        case.run(check)
        for index, target in enumerate(['https://127.0.0.1:19443', 'https://localhost:19443', 'http://[::1]:19482', '18081']):
            case = Case(self, 'nginx', 'R7-scheme-authority-'+str(index))
            case.invoke('setup_local_proxy' if target.isdigit() else 'setup_remote_proxy', stdin=DOMAIN+'\n'+target+'\n')
            expected = 'http://127.0.0.1:'+target if target.isdigit() else target
            def check(rc, unchanged, trace, valid, output, c=case, expected=expected):
                ok, reason = committed_check('nginx')(rc, unchanged, trace, valid, output)
                return ok and ('proxy_pass '+expected+';').encode() in c.config.read_bytes(), reason+'; retain scheme and authority'
            case.run(check)
        for fault in ['commit', 'link', 'reload']:
            case = Case(self, 'nginx', 'transaction-'+fault)
            case.nginx_site()
            case.fault = fault
            if fault == 'link':
                case.fault_dest = case.root/'enabled/new.test'
                case.fault_site = case.root/'available/new.test'
                case.invoke('apply_proxy_config', 'new.test', 'http://127.0.0.1:18081')
            else:
                case.invoke('modify_proxy', stdin='target.test\n18081\n')
            def check(rc, unchanged, trace, valid, output, fault=fault, c=case):
                if fault == 'link':
                    return final_link_check(c, rc, unchanged, trace, valid, output)
                exercised = ('SERVICE reload' in trace or 'SERVICE restart' in trace) if fault == 'reload' else 'FAULT '+fault in trace
                return exercised and rc != 0 and unchanged and valid and no_success(output), 'fault reached; site/link restored, nonzero, no success message'
            case.run(check)


def binary(value):
    path = shutil.which(value)
    if not path:
        raise ValueError('validator unavailable: '+value)
    return str(Path(path).resolve())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--component', choices=['caddy', 'nginx', 'all'], default='all')
    parser.add_argument('--caddy-bin', default='caddy')
    parser.add_argument('--nginx-bin', default='nginx')
    parser.add_argument('--evidence-dir', type=Path, help='parent directory for retained, uniquely named sandbox')
    options = parser.parse_args()
    if sys.platform != 'linux':
        parser.error('run on Linux with Bash and real validators; no Windows shell execution')
    try:
        caddy = binary(options.caddy_bin) if options.component in ['caddy', 'all'] else None
        nginx = binary(options.nginx_bin) if options.component in ['nginx', 'all'] else None
    except ValueError as error:
        parser.error(str(error))
    if options.evidence_dir:
        options.evidence_dir.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='regression-', dir=options.evidence_dir))
    suite = Suite(options, root, caddy, nginx)
    try:
        if options.component in ['caddy', 'all']:
            suite.caddy_cases()
            suite.inputs('caddy')
        if options.component in ['nginx', 'all']:
            suite.nginx_cases()
            suite.inputs('nginx')
    except (RuntimeError, subprocess.TimeoutExpired, OSError) as error:
        print('HARNESS ERROR: '+str(error), file=sys.stderr)
        (root/'harness-error.txt').write_text(str(error), encoding='utf-8')
        return 2
    failures = sum(not record['passed'] for record in suite.results)
    summary = {'cases': len(suite.results), 'passed': len(suite.results)-failures, 'failed': failures,
               'validators': {'caddy': caddy, 'nginx': nginx}, 'results': suite.results,
               'limits': ['services mocked; no daemon started', 'no request/TLS certificate/DNS behavior test',
                          'source menu libraries isolated; install/uninstall menus not exercised']}
    (root/'summary.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding='utf-8')
    print('RESULT '+json.dumps({key: summary[key] for key in ['cases', 'passed', 'failed']}))
    print('EVIDENCE '+str(root))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
