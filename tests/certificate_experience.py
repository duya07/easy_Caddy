#!/usr/bin/env python3
"""Isolated Linux acceptance: certificate UX, native issuance policy, rollback and PTY."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import shlex
import errno
import pty
import select
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--script', required=True)
    parser.add_argument('--caddy-bin', required=True)
    parser.add_argument('--only', default='')
    parser.add_argument('--evidence-dir', required=True)
    args = parser.parse_args()
    out = Path(args.evidence_dir)
    assert str(out).startswith('/tmp/') and os.geteuid() == 0
    out.mkdir(mode=0o700, parents=True, exist_ok=True)
    script = Path(args.script).resolve()
    assert subprocess.run(['/bin/bash', '-n', str(script)], capture_output=True).returncode == 0, 'Product syntax preflight failed'
    caddy = Path(args.caddy_bin).resolve()
    results = []

    def fixture(name, certificate=False):
        root = out / name
        root.mkdir(mode=0o700)
        for sub in ['bin', 'state', 'storage', 'units', 'worker', 'config']:
            (root / sub).mkdir(mode=0o700)
        config = root / 'config/Caddyfile'
        config.write_text('{\n admin off\n storage file_system {\n root ' + json.dumps(str(root/'storage')) + '\n }\n}\nalpha.test {\n respond "original"\n}\n')
        (root/'registry').write_text('alpha.test -> http://127.0.0.1:18080\n')
        for tool, content in {
            'sudo': '#!/bin/bash\nexec "$@"\n',
            'systemctl': '#!/bin/bash\nprintf "%s\\n" "$*" >> "$UX_ROOT/service.trace"\ncase "$1" in show) case "$*" in *MainPID*) echo 0;; *User*) echo root;; esac;; is-active) echo active;; reload) [ ! -e "$UX_ROOT/fail-reload" ];; *) exit 0;; esac\n',
            'journalctl': '#!/bin/bash\nprintf "No journal entries\\n"\n',
        }.items():
            file = root/'bin'/tool
            file.write_text(content)
            file.chmod(0o700)
        (root/'bin/caddy').symlink_to(caddy)
        env = os.environ.copy()
        env.update(EASY_CADDY_TEST_MODE='1', UX_ROOT=str(root),
                   PATH=str(root/'bin')+':/usr/bin:/bin', CADDYFILE=str(config),
                   PROXY_CONFIG_FILE=str(root/'registry'), CERT_STATE_DIR=str(root/'state'),
                   CERT_STORAGE_DIR_OVERRIDE=str(root/'storage'), CERT_WORKER_INSTALL_DIR=str(root/'worker'),
                   CERT_SYSTEMD_UNIT_DIR=str(root/'units'), HOME=str(root), TERM='dumb')
        if certificate:
            leaf = root/'storage/certificates/fixture/alpha.test'
            leaf.mkdir(parents=True)
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '90',
                            '-subj', '/CN=alpha.test/O=Test CA', '-addext', 'subjectAltName=DNS:alpha.test',
                            '-keyout', str(leaf/'alpha.test.key'), '-out', str(leaf/'alpha.test.crt')],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        return root, env

    def run(root, env, command, data='', expected=0):
        count = len(list(root.glob('step-*.json'))) + 1
        p = subprocess.run(['/bin/bash', '-c', 'source "$1" || exit 98; '+command, '_', str(script)],
                           input=data, text=True, capture_output=True, env=env, timeout=45)
        (root/f'step-{count:03d}.json').write_text(json.dumps({'command':command, 'exit':p.returncode,
                                                           'stdout':p.stdout, 'stderr':p.stderr}, ensure_ascii=False, indent=2))
        if expected is not None:
            assert p.returncode == expected, (p.returncode, p.stdout, p.stderr)
        return p

    def case(name, callback):
        if args.only and name not in args.only.split(','):
            return
        try:
            callback()
            results.append({'name': name, 'status': 'passed'})
            print('PASS '+name, flush=True)
        except Exception as exc:
            results.append({'name': name, 'status': 'failed', 'reason': str(exc)[:2200]})
            print('FAIL '+name+': '+str(exc)[:300], flush=True)

    def interfaces():
        root, env = fixture('interfaces')
        run(root, env, 'for f in certificate_request certificate_automation_set certificate_automation_run certificate_renewal_ratio certificate_destination_preview certificate_normalize_destination_input certificate_watch_domain; do declare -F "$f" >/dev/null || exit 17; done')
    case('new-public-interfaces', interfaces)

    def paths():
        root, env = fixture('paths')
        p=run(root, env, 'certificate_destination_preview "/root/cert" alpha.test')
        assert '/root/cert/alpha.test/fullchain.pem' in p.stdout
        assert '/root/cert/alpha.test/privkey.pem' in p.stdout
        p=run(root, env, 'certificate_destination_preview "/root/cert/alpha.test" alpha.test')
        assert '重复' in p.stdout and '/root/cert/alpha.test/alpha.test/' in p.stdout
        p=run(root, env, "certificate_normalize_destination_input '~/cert files'")
        assert p.stdout.strip() == str(root/'cert files')
        p=run(root, env, "certificate_normalize_destination_input '~other/cert'", expected=None)
        assert p.returncode != 0
        run(root, env, 'certificate_watch_domain alpha.test; printf NON_TTY_RETURNED')
    case('destination-parent-preview-and-no-nontty-wait', paths)

    def ratio():
        root, env = fixture('ratio', True)
        cert=root/'storage/certificates/fixture/alpha.test/alpha.test.crt'
        p=run(root, env, 'certificate_renewal_ratio '+json.dumps(str(cert))+' 20')
        assert abs(float(p.stdout.strip())-20/90)<0.00001
        p=run(root, env, 'certificate_renewal_ratio '+json.dumps(str(cert))+' 120', expected=None)
        assert p.returncode != 0 and '有效期' in p.stderr
        p=run(root, env, 'certificate_automation_set alpha.test on '+shlex.quote('$(touch '+str(root/'injected')+')'), expected=None)
        assert p.returncode != 0 and not (root/'injected').exists()
    case('renewal-window-days-and-input-validation', ratio)

    def enable():
        root, env = fixture('enable', True)
        original=(root/'config/Caddyfile').read_text()
        run(root, env, 'certificate_automation_set alpha.test on 20')
        text=(root/'config/Caddyfile').read_text()
        assert 'respond "original"' in text and 'renewal_window_ratio' in text
        p=subprocess.run([str(caddy), 'adapt', '--adapter', 'caddyfile', '--config', str(root/'config/Caddyfile')], capture_output=True,text=True,timeout=20)
        assert p.returncode == 0, p.stderr
        data=json.loads(p.stdout)
        policies=data['apps']['tls']['automation']['policies']
        assert any(abs(x.get('renewal_window_ratio',0)-20/90)<0.00001 and 'alpha.test' in x.get('subjects',[]) for x in policies)
        first=(root/'config/Caddyfile').read_bytes()
        trace=(root/'service.trace').read_text()
        run(root, env, 'certificate_automation_run')
        assert first==(root/'config/Caddyfile').read_bytes()
        assert (root/'service.trace').read_text().count('reload caddy')==trace.count('reload caddy')
        assert (root/'units/easy-caddy-cert-sync.service').is_file()
        assert '--certificate-maintenance' in (root/'units/easy-caddy-cert-sync.service').read_text()
    case('enable-real-adapt-and-idempotent-maintenance', enable)

    def disable():
        root, env = fixture('disable', True)
        run(root, env, 'certificate_automation_set alpha.test off 0')
        p=subprocess.run([str(caddy), 'adapt', '--adapter', 'caddyfile', '--config', str(root/'config/Caddyfile')], capture_output=True,text=True,timeout=20)
        assert p.returncode==0,p.stderr
        data=json.loads(p.stdout)
        assert data['apps']['tls']['certificates']['load_files']
        assert 'alpha.test.crt' in (root/'config/Caddyfile').read_text()
        p=run(root,env,'certificate_automation_describe alpha.test')
        assert '关闭' in p.stdout
        run(root,env,'certificate_automation_set alpha.test on 20')
        assert 'renewal_window_ratio' in (root/'config/Caddyfile').read_text()
        assert 'alpha.test.crt' not in (root/'config/Caddyfile').read_text()
    case('disable-uses-fixed-cert-and-can-reenable', disable)

    def request():
        root, env = fixture('request')
        run(root,env,'certificate_request beta.test on 20')
        text=(root/'config/Caddyfile').read_text()
        assert 'beta.test {' in text and 'respond "original"' in text
        assert (root/'registry').read_text()=='alpha.test -> http://127.0.0.1:18080\n'
        p=run(root,env,'certificate_request beta.test on 20')
        assert (root/'config/Caddyfile').read_text().count('beta.test {')==1
    case('request-new-domain-without-changing-proxy-registry', request)

    def custom_reject():
        root,env=fixture('custom-reject',True)
        path=root/'config/Caddyfile'
        path.write_text(path.read_text().replace('respond "original"','tls internal\n respond "original"'))
        before=path.read_bytes()
        p=run(root,env,'certificate_automation_set alpha.test off 0',expected=None)
        assert p.returncode!=0 and path.read_bytes()==before
        assert 'TLS' in p.stderr or 'tls' in p.stderr or '手工' in p.stderr
    case('custom-tls-refusal-preserves-user-config',custom_reject)

    def rollback():
        root,env=fixture('rollback',True)
        before=(root/'config/Caddyfile').read_bytes()
        (root/'fail-reload').touch()
        p=run(root,env,'certificate_automation_set alpha.test on 20',expected=None)
        assert p.returncode!=0 and (root/'config/Caddyfile').read_bytes()==before
        assert not (root/'state/automation/alpha.test').exists()
    case('reload-failure-preserves-config-and-rule',rollback)

    def warning_capture():
        root,env=fixture('warnings')
        path=root/'config/Caddyfile'
        before=path.read_bytes()
        p=run(root,env,'unset CERT_STORAGE_DIR_OVERRIDE; certificate_storage_root')
        assert 'WARN' not in p.stderr and 'Unnecessary' not in p.stderr
        assert 'storage' in p.stdout
        assert before==path.read_bytes()
        path.write_text('broken { invalid_directive }\n')
        p=run(root,env,'unset CERT_STORAGE_DIR_OVERRIDE; certificate_storage_root',expected=None)
        assert p.returncode!=0 and p.stderr.strip()
    case('normal-adapt-warnings-quiet-real-errors-visible',warning_capture)

    def friendly():
        root,env=fixture('friendly',True)
        (root/'state/export-directory').write_text(str(root/'export')+'\n')
        (root/'state/export-domains').write_text('alpha.test\n')
        p=run(root,env,'list_certificates')
        assert 'alpha.test' in p.stdout and ('有效' in p.stdout or '签发' in p.stdout)
        assert 'notAfter=' not in p.stdout and 'issuer目录' not in p.stdout
        assert '到期' in p.stdout and '天' in p.stdout
    case('human-certificate-status',friendly)

    def pending_then_issued():
        root,env=fixture('pending-then-issued')
        run(root,env,'certificate_request alpha.test on 20')
        assert (root/'state/automation/alpha.test').read_text().strip()=='on 20 waiting'
        leaf=root/'storage/certificates/fixture/alpha.test';leaf.mkdir(parents=True)
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','90','-subj','/CN=alpha.test',
                        '-addext','subjectAltName=DNS:alpha.test','-keyout',str(leaf/'alpha.test.key'),'-out',str(leaf/'alpha.test.crt')],
                       check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=20)
        run(root,env,'certificate_automation_run')
        assert (root/'state/automation/alpha.test').read_text().strip()=='on 20 active'
        assert '0.22222222' in (root/'config/Caddyfile').read_text()
        backups=list((root/'config').glob('Caddyfile.manual-backup.*'))
        run(root,env,'certificate_automation_run')
        assert list((root/'config').glob('Caddyfile.manual-backup.*'))==backups
    case('first-issuance-applies-window-without-repeated-backups',pending_then_issued)

    def fixed_after_cleanup():
        root,env=fixture('fixed-after-cleanup',True)
        run(root,env,'certificate_automation_set alpha.test off 0')
        fixed=list((root/'config/easy-caddy-fixed/alpha.test').glob('.pair.*/alpha.test.crt'))
        assert len(fixed)==1
        shutil.rmtree(root/'storage/certificates')
        before=(root/'config/Caddyfile').read_bytes()
        run(root,env,'certificate_automation_run')
        assert (root/'state/automation/alpha.test').read_text().strip()=='off 0 fixed'
        assert before==(root/'config/Caddyfile').read_bytes()
        assert 'tls {' not in before.decode()
        p=run(root,env,'list_certificates')
        assert '已签发' in p.stdout and '已关闭' in p.stdout
    case('disabled-survives-storage-cleanup-and-does-not-reissue',fixed_after_cleanup)

    def shared_and_alias_refusal():
        root,env=fixture('shared-alias',True)
        path=root/'config/Caddyfile'
        path.write_text(path.read_text().replace('alpha.test {','alpha.test, other.test {'))
        before=path.read_bytes()
        p=run(root,env,'certificate_automation_set alpha.test on 20',expected=None)
        assert p.returncode!=0 and path.read_bytes()==before
    case('shared-site-is-never-automatically-rewritten',shared_and_alias_refusal)

    def wildcard_protection():
        root,env=fixture('wildcard-protection')
        path=root/'config/Caddyfile'
        path.write_text(path.read_text()+'\n*.parent.test {\n respond "existing wildcard content"\n}\n')
        before=path.read_bytes()
        subprocess.run([str(caddy),'validate','--adapter','caddyfile','--config',str(path)],check=True,capture_output=True,timeout=20)
        p=run(root,env,'certificate_request child.parent.test on 20',expected=None)
        assert p.returncode!=0 and path.read_bytes()==before, 'new certificate site must never shadow wildcard content'
    case('new-request-preserves-wildcard-site',wildcard_protection)

    def bounded_refusal():
        root,env=fixture('bounded-refusal',True)
        run(root,env,'certificate_automation_set alpha.test on 20')
        path=root/'config/Caddyfile'
        path.write_text(path.read_text().replace('respond "original"','tls internal\n respond "original"'))
        before=path.read_bytes()
        for _ in range(3):
            p=run(root,env,'certificate_automation_run',expected=None)
            assert p.returncode!=0 and path.read_bytes()==before
        assert not list((root/'config').glob('.easy-caddy-policy.*')), 'safe refusals must not accumulate config copies'
    case('background-refusal-does-not-accumulate-config-copies',bounded_refusal)

    def rule_save_failure():
        root,env=fixture('rule-save-failure',True)
        run(root,env,'certificate_automation_set alpha.test on 20')
        original=(root/'config/Caddyfile').read_bytes()
        rule=root/'state/automation/alpha.test'
        rule.write_text('on 20 waiting\n')
        wrapper=root/'bin/mv'
        wrapper.write_text('#!/bin/bash\ncase "${@: -1}" in "$CERT_STATE_DIR"/automation/alpha.test) exit 77;; esac\nexec /usr/bin/mv "$@"\n')
        wrapper.chmod(0o700)
        p=run(root,env,'certificate_automation_set alpha.test on 20',expected=None)
        assert p.returncode!=0 and (root/'config/Caddyfile').read_bytes()==original
        assert '配置原本无需修改' in p.stderr and rule.read_text()=='on 20 waiting\n'
        p=run(root,env,'certificate_automation_set alpha.test on 30',expected=None)
        assert p.returncode!=0 and (root/'config/Caddyfile').read_bytes()==original
        assert rule.read_text()=='on 20 waiting\n' and '恢复原配置' in p.stderr
    case('rule-save-failure-preserves-or-restores-config',rule_save_failure)

    def tty_return_and_eof():
        for action in ['return','eof']:
            root,env=fixture('tty-'+action)
            master,slave=pty.openpty();buf=bytearray()
            proc=subprocess.Popen(['/bin/bash','-c','source "$1"; certificate_watch_domain alpha.test','_',str(script)],env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True)
            os.close(slave)
            def until(marker):
                deadline=time.monotonic()+12
                while marker.encode() not in buf and time.monotonic()<deadline:
                    if select.select([master],[],[],.1)[0]:
                        try:buf.extend(os.read(master,65536))
                        except OSError as exc:
                            if exc.errno!=errno.EIO:raise
                            break
                assert marker.encode() in buf,buf.decode('utf-8','replace')
            try:
                until('请选择 > ')
                if action=='return':
                    os.write(master,b'\n');until('还在等待可用证书');os.write(master,b'r\n')
                else:os.write(master,b'\x04')
                assert proc.wait(timeout=8)==0
            finally:
                if proc.poll() is None:proc.kill();proc.wait()
                try:
                    while select.select([master],[],[],0)[0]:
                        part=os.read(master,65536)
                        if not part:break
                        buf.extend(part)
                except OSError:pass
                os.close(master)
                (root/'terminal.txt').write_bytes(buf)
    case('real-terminal-wait-can-return-or-end-input',tty_return_and_eof)

    summary={'script_sha256':hashlib.sha256(script.read_bytes()).hexdigest(),
             'cases':results,'passed':sum(r['status']=='passed' for r in results),
             'failed':sum(r['status']=='failed' for r in results),
             'boundary':'Real OpenSSL, Caddy adapt/validate and filesystem; systemctl mocked. Native process integration is separate.'}
    (out/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
    print(json.dumps({k:v for k,v in summary.items() if k!='cases'}),flush=True)
    return 1 if summary['failed'] else 0


if __name__=='__main__':
    raise SystemExit(main())
