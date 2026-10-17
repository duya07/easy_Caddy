#!/usr/bin/env python3
"""Linux-only isolated acceptance for management pages, package ownership and log rotation."""
import argparse
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import struct
import subprocess
import sys
import termios
import time

PACKAGE_WRAPPER = r'''#!/usr/bin/python3
import json,os,re,sys
from pathlib import Path
root=Path(os.environ['OPS_FIXTURE'])
a=sys.argv[1:]
tool=Path(sys.argv[0]).name
state=json.loads((root/'packages.json').read_text())
with (root/'package-trace.jsonl').open('a') as f:f.write(json.dumps({'tool':tool,'argv':a})+'\n')
if tool=='dpkg-query':
    fmt=next((x[3:] for x in a if x.startswith('-f=')),'${binary:Package}\t${db:Status-Status}\t${Essential}\t${Protected}\n')
    if '--showformat' in a:fmt=a[a.index('--showformat')+1]
    names=[x for x in a if not x.startswith('-')]
    fmt=fmt.replace('\\n','\n').replace('\\t','\t')
    rc=0
    for name in names or sorted(state['installed']):
        name=name.split(':')[0]
        installed=name in state['installed']
        if not installed and names:rc=1;continue
        fields={'binary:Package':name,'Package':name,'db:Status-Status':'installed' if installed else 'not-installed',
                'db:Status-Abbrev':'ii ' if installed else 'un ','Status':'install ok installed' if installed else 'unknown ok not-installed',
                'Essential':'yes' if name in state['essential'] else '', 'Protected':'yes' if name in state['protected'] else '', 'Version':'1.0'}
        print(re.sub(r'\$\{([^}]+)\}',lambda m:fields.get(m[1],''),fmt),end='')
    sys.exit(rc)
operation=next((x for x in a if x in ['update','install','remove','purge','autoremove']),None)
if operation=='update':sys.exit(0)
if operation in ['purge','autoremove']:print('PROHIBITED PACKAGE OPERATION',file=sys.stderr);sys.exit(90)
if operation not in ['install','remove']:print('Unsupported apt operation',file=sys.stderr);sys.exit(91)
requested=[x for x in a[a.index(operation)+1:] if not x.startswith('-')]
sim=any(x in ['--simulate','-s','--dry-run'] for x in a)
packages=list(requested)
if operation=='install':
    if 'jq' in packages:packages+=['libjq1','libonig5']
    packages=sorted(set(packages)-set(state['installed']))
else:
    packages=sorted(set(packages)|set(state.get('cascade',[])))
if sim:
    for name in packages:print(('Inst ' if operation=='install' else 'Remv ')+name+' (1.0 mock [amd64])')
    sys.exit(0)
if operation=='install':
    if state.get('fail_install'):
        packages=[x for x in packages if x in ['jq','libjq1','libonig5']]
    state['installed']=sorted(set(state['installed'])|set(packages))
    for name in packages:
        command={'jq':'jq','logrotate':'logrotate','gnupg':'gpg'}.get(name)
        if command and not (root/'bin'/command).exists():
            target=state.get('logrotate') if command=='logrotate' else shutil_path(command)
            if target:(root/'bin'/command).symlink_to(target)
else:
    if state.get('fail_remove'):packages=packages[:1]
    state['installed']=sorted(set(state['installed'])-set(packages))
(root/'packages.json').write_text(json.dumps(state))
sys.exit(77 if state.get('fail_'+operation) else 0)
'''
# Keep the wrapper independent of PATH for tools intentionally hidden by a fixture.
PACKAGE_WRAPPER = PACKAGE_WRAPPER.replace('shutil_path(command)', "('/usr/bin/'+command)")
SYSTEM_WRAPPER = r'''#!/usr/bin/python3
import json,os,sys
from pathlib import Path
root=Path(os.environ['OPS_FIXTURE']);a=sys.argv[1:]
with (root/'service-trace.jsonl').open('a') as f:f.write(json.dumps(a)+'\n')
if a[0]=='is-active':
    if 'caddy' in a:print('active');sys.exit(0)
    enabled=(root/'enabled').exists();print('active' if enabled else 'inactive');sys.exit(0 if enabled else 3)
if a[0]=='show':
    if '--value' in a:
        prop=next((x.split('=',1)[1] for x in a if x.startswith('--property=')),'')
        print({'MainPID':'0','User':'caddy','Environment':'','EnvironmentFiles':'','ActiveState':'active'}.get(prop,''));sys.exit(0)
    print('MainPID=0\nUser=caddy\nActiveState=active');sys.exit(0)
if a[0]=='status':print('CADDY_STATUS_FIXTURE');sys.exit(0)
if a[0]=='daemon-reload':sys.exit(0)
if a[0] in ['enable','restart','start','stop','disable']:
    if not any(x.startswith('easy-caddy-') for x in a):print('BLOCKED production service',file=sys.stderr);sys.exit(90)
    if a[0]=='enable' and os.environ.get('OPS_ENABLE_FAIL')=='1':print('simulated enable failure',file=sys.stderr);sys.exit(77)
    if a[0]=='enable':(root/'enabled').write_text('enabled')
    sys.exit(0)
print('BLOCKED unexpected systemctl',file=sys.stderr);sys.exit(90)
'''

class Fixture:
    def __init__(self, name, populated=False, missing=()):
        self.root=out/name;self.root.mkdir(mode=0o700)
        self.bin=self.root/'bin';self.bin.mkdir(mode=0o700)
        self.state=self.root/'cert-state';self.state.mkdir(mode=0o700)
        self.logs=self.root/'log-state';self.deps=self.root/'dep-state';self.units=self.root/'units'
        self.storage=self.root/'storage';self.storage.mkdir(mode=0o700)
        self.dest=self.root/'export destination';self.dest.mkdir(mode=0o700)
        self.config=self.root/'Caddyfile';self.registry=self.root/'registry'
        self.config.write_text('{\n admin off\n auto_https off\n storage file_system {\n root '+json.dumps(str(self.storage))+'\n }\n}\nhttp://alpha.test { respond "fixture" }\n')
        self.registry.write_text('alpha.test -> http://127.0.0.1:18080\n' if populated else '')
        tools=['bash','sh','env','awk','sed','grep','sort','comm','uniq','cut','tr','head','tail','wc','find','xargs','dirname','basename',
               'readlink','realpath','stat','date','sha256sum','cp','mv','rm','mkdir','chmod','chown','mktemp','cmp','install','flock',
               'timeout','tee','cat','touch','printf','id','getent','caddy','openssl','curl','gpg','jq','gzip','gunzip','which','sync']
        for tool in tools:
            if tool in missing:continue
            target=shutil.which(tool)
            if target:(self.bin/tool).symlink_to(target)
        if 'logrotate' not in missing:(self.bin/'logrotate').symlink_to(logrotate)
        for tool in ['apt-get','dpkg-query']:
            path=self.bin/tool;path.write_text(PACKAGE_WRAPPER);path.chmod(0o700)
        path=self.bin/'systemctl';path.write_text(SYSTEM_WRAPPER);path.chmod(0o700)
        path=self.bin/'sudo';path.write_text('#!/bin/bash\nexec "$@"\n');path.chmod(0o700)
        path=self.bin/'journalctl';path.write_text('#!/bin/bash\nprintf "JOURNAL alpha.test certificate ready\\n"\n');path.chmod(0o700)
        installed=['curl','gnupg','jq','openssl','util-linux','coreutils','findutils','grep','sed','mawk','sudo','ca-certificates','logrotate','gzip','bash','apt','dpkg','systemd','libpopt0']
        for tool in missing:
            package={'gpg':'gnupg','awk':'mawk'}.get(tool,tool)
            if package in installed:installed.remove(package)
        self.pkg={'installed':installed,'essential':['bash','coreutils','util-linux','grep','sed','findutils','apt','dpkg','systemd'],
                  'protected':['systemd'],'logrotate':str(logrotate)}
        self.save_packages()
        self.env=os.environ.copy()
        for key in list(self.env):
            if key.startswith(('CERT_','CADDY_SERVICE_','TEST_','OPS_')):self.env.pop(key)
        self.env.update(EASY_CADDY_TEST_MODE='1',PATH=str(self.bin),OPS_FIXTURE=str(self.root),
                        CADDYFILE=str(self.config),PROXY_CONFIG_FILE=str(self.registry),CERT_STATE_DIR=str(self.state),
                        CERT_WORKER_INSTALL_DIR=str(self.root/'worker'),CERT_SYSTEMD_UNIT_DIR=str(self.root/'cert-units'),
                        CERT_STORAGE_DIR_OVERRIDE=str(self.storage),DEPENDENCY_STATE_DIR=str(self.deps),
                        LOG_MANAGER_STATE_DIR=str(self.logs),LOG_SYSTEMD_UNIT_DIR=str(self.units),TERM='xterm-256color',COLUMNS='40')
        self.steps=0
        if populated:
            (self.state/'export-directory').write_text(str(self.dest)+'\n')
            (self.state/'export-domains').write_text('alpha.test\n')
            (self.state/'sync.log').write_text('2026-10-13T00:00:00Z [alpha.test] READY fixture entry\n')
            leaf=self.storage/'certificates/fixture/alpha.test';leaf.mkdir(parents=True)
            subprocess.run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','2','-subj','/CN=alpha.test',
                            '-addext','subjectAltName=DNS:alpha.test','-keyout',str(leaf/'alpha.test.key'),'-out',str(leaf/'alpha.test.crt')],
                           stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,timeout=20)
    def save_packages(self): (self.root/'packages.json').write_text(json.dumps(self.pkg))
    def packages(self): return json.loads((self.root/'packages.json').read_text())['installed']
    def trace(self):
        file=self.root/'package-trace.jsonl'
        return [json.loads(x) for x in file.read_text().splitlines()] if file.exists() else []
    def call(self, command, data='', expected=None):
        return self.run(['/usr/bin/bash','-c','source "$1"; '+command,'_',str(script)],data,expected)
    def main(self, data): return self.run(['/usr/bin/bash',str(script)],data)
    def run(self, argv, data='', expected=None):
        self.steps+=1
        p=subprocess.run(argv,input=data,text=True,capture_output=True,env=self.env,timeout=30)
        (self.root/f'step-{self.steps:03d}.stdout').write_text(p.stdout)
        (self.root/f'step-{self.steps:03d}.stderr').write_text(p.stderr)
        (self.root/f'step-{self.steps:03d}.exit').write_text(str(p.returncode))
        if expected is not None:assert p.returncode==expected,(p.returncode,p.stdout,p.stderr)
        return p

def menu():
    c=Fixture('menu');p=c.main('0\n')
    assert p.returncode==0
    for n in range(14):assert re.search(r'(?m)^\s*'+str(n)+r'(?:\)|[ \t])',p.stdout),n
    for label in ['依赖检测与安装','依赖卸载','日志查看','日志轮转设置','证书管理','手动编辑']:assert label in p.stdout,label
    assert '\x1b' not in p.stdout
    assert c.call('printf SOURCE_SAFE',expected=0).stdout=='SOURCE_SAFE'

def install_ownership():
    c=Fixture('install-ownership',missing=['jq','logrotate'])
    p=c.call('dependency_install_menu','y\n',0)
    assert '已安装' in p.stdout and '缺失' in p.stdout
    assert {'jq','libjq1','libonig5','logrotate'}<=set(c.packages())
    assert c.deps.is_dir()
    assert all((p.stat().st_mode & 0o077)==0 for p in c.deps.iterdir() if p.is_file())
    first=[x for x in c.trace() if x['tool']=='apt-get' and 'install' in x['argv'] and '--simulate' not in x['argv'] and '-s' not in x['argv']]
    c.call('dependency_install_menu','y\n',0)
    second=[x for x in c.trace() if x['tool']=='apt-get' and 'install' in x['argv'] and '--simulate' not in x['argv'] and '-s' not in x['argv']]
    assert len(first)==len(second)==1
    c.call('dependency_uninstall_menu','\ny\n',0)
    assert not {'jq','libjq1','libonig5','logrotate'} & set(c.packages())
    assert {'curl','openssl','coreutils','util-linux','caddy'}-{'caddy'}<=set(c.packages())

def install_cancel():
    c=Fixture('install-cancel',missing=['jq']);before=c.packages()
    c.call('dependency_install_menu','n\n')
    assert c.packages()==before
    assert not any('install' in x['argv'] and '--simulate' not in x['argv'] for x in c.trace() if x['tool']=='apt-get')

def partial_install():
    c=Fixture('install-partial',missing=['jq','logrotate']);c.pkg['fail_install']=True;c.save_packages()
    p=c.call('dependency_install_menu','y\n');assert p.returncode!=0
    assert 'jq' in c.packages() and 'logrotate' not in c.packages()
    c.pkg=json.loads((c.root/'packages.json').read_text());c.pkg['fail_install']=False;c.save_packages()
    c.call('dependency_uninstall_menu','\ny\n',0)
    assert 'jq' not in c.packages() and 'curl' in c.packages()

def uninstall_cancel():
    c=Fixture('uninstall-cancel',missing=['jq']);c.call('dependency_install_menu','y\n',0);before=c.packages()
    c.call('dependency_uninstall_menu','\nn\n')
    assert c.packages()==before
    assert not any('remove' in x['argv'] and '--simulate' not in x['argv'] for x in c.trace() if x['tool']=='apt-get')

def uninstall_all():
    c=Fixture('uninstall-all');p=c.call('dependency_uninstall_menu','2\ny\n',0)
    assert 'curl' not in c.packages() and 'jq' not in c.packages()
    assert {'coreutils','util-linux','bash','systemd','apt','dpkg'}<=set(c.packages())
    assert 'curl' in p.stdout and ('保留' in p.stdout or '保护' in p.stdout)
    assert not any('autoremove' in x['argv'] or 'purge' in x['argv'] for x in c.trace())

def cascade_refused():
    c=Fixture('uninstall-cascade',missing=['jq']);c.call('dependency_install_menu','y\n',0)
    c.pkg=json.loads((c.root/'packages.json').read_text());c.pkg['cascade']=['curl'];c.save_packages();before=c.packages()
    p=c.call('dependency_uninstall_menu','\ny\n')
    assert p.returncode!=0 and c.packages()==before
    assert not any('remove' in x['argv'] and '--simulate' not in x['argv'] for x in c.trace() if x['tool']=='apt-get')

def certificate_context():
    c=Fixture('certificate-context',populated=True)
    for option,prompt in [(2,'请输入证书父目录'),(4,'请选择域名'),(5,'请选择域名'),(6,'请选择域名')]:
        p=c.main('12\n'+str(option)+'\n')
        assert p.returncode==0
        assert str(c.dest) in p.stdout and 'alpha.test' in p.stdout
        assert p.stdout.index('当前目的目录')<p.stdout.index(prompt)
    p=c.main('12\n1\n0\n0\n')
    assert '当前有效' in p.stdout and '证书与私钥匹配' in p.stdout and 'alpha.test' in p.stdout
    p=c.main('12\n3\n0\n0\n')
    assert '已有证书' in p.stdout and (c.dest/'alpha.test/fullchain.pem').exists()
    p=c.main('12\n6\n1\n0\n0\n')
    assert '复制登记已取消' in p.stdout
    assert (c.state/'export-domains').read_text()==''

def certificate_empty():
    c=Fixture('certificate-empty')
    p=c.main('12\n2\n');assert '当前目的目录：未设置' in p.stdout and '无已登记域名' in p.stdout
    p=c.main('12\n5\n');assert '无已签发证书' in p.stdout and '当前没有可选域名' in p.stdout
    p=c.main('12\n6\n0\n0\n');assert '当前没有已登记域名' in p.stdout

def logs():
    c=Fixture('logs',populated=True)
    p=c.main('8\n1\n2\n3\n0\n0\n')
    assert p.returncode==0 and 'JOURNAL alpha.test' in p.stdout and 'READY fixture entry' in p.stdout
    p=c.call('certificate_show_logs beta.test',expected=0);assert '暂无日志' in p.stdout
    (c.state/'sync.log').write_text('')
    p=c.main('8\n2\n0\n0\n');assert '无日志' in p.stdout or '暂无' in p.stdout

def rotation_actual():
    c=Fixture('rotation-actual',populated=True)
    for period in ['daily','weekly','monthly']:
        c.call('log_rotation_apply '+period,expected=0)
        configs=list(c.logs.glob('*.conf'));assert len(configs)==1
        cfg=configs[0];text=cfg.read_text();assert period in text and 'maxsize 10M' in text and 'rotate 14' in text
        log=c.state/'sync.log';log.write_text(period+'-marker\n'+('x'*1024+'\n')*11000)
        inode=log.stat().st_ino
        c.run([str(logrotate),'--state',str(c.root/'actual-logrotate.status'),str(cfg)],expected=0)
        assert log.stat().st_size==0 and log.stat().st_ino==inode
        assert Path(str(log)+'.1').exists()
        log.write_text(period+'-recent\n')
        c.run([str(logrotate),'--state',str(c.root/'actual-logrotate.status'),str(cfg)],expected=0)
        assert log.read_text()==period+'-recent\n'
        state=c.root/'actual-logrotate.status'
        state.write_text(re.sub(r'\d{4}-\d{1,2}-\d{1,2}-\d{1,2}:\d{1,2}:\d{1,2}','2020-1-1-0:0:0',state.read_text()))
        c.run([str(logrotate),'--state',str(state),str(cfg)],expected=0)
        assert log.stat().st_size==0
        assert Path(str(log)+'.1').read_text()==period+'-recent\n'
        assert Path(str(log)+'.2.gz').exists()
        with gzip.open(str(log)+'.2.gz','rt') as f:assert period+'-marker' in f.read(100)
    service=c.units/'easy-caddy-logrotate.service';timer=c.units/'easy-caddy-logrotate.timer'
    assert service.exists() and timer.exists() and 'OnCalendar=hourly' in timer.read_text() and (c.root/'enabled').exists()

def rotation_rollback():
    c=Fixture('rotation-rollback',populated=True);c.call('log_rotation_apply daily',expected=0)
    config=list(c.logs.glob('*.conf'))[0];before=config.read_bytes()
    units={p.name:p.read_bytes() for p in c.units.iterdir()}
    c.env['OPS_ENABLE_FAIL']='1'
    p=c.call('log_rotation_apply monthly');assert p.returncode!=0
    assert config.read_bytes()==before and all((c.units/k).read_bytes()==v for k,v in units.items())

def rotation_unsafe():
    c=Fixture('rotation-unsafe');victim=c.root/'victim';victim.write_text('must survive')
    (c.state/'sync.log').symlink_to(victim)
    p=c.call('log_rotation_apply weekly');assert p.returncode!=0
    assert victim.read_text()=='must survive' and not c.units.exists()

def rotation_cancel():
    c=Fixture('rotation-cancel');c.call('log_rotation_menu','1\nn\n')
    assert not c.units.exists()

def tty_pages():
    c=Fixture('tty-pages',populated=True)
    master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',48,40,0,0))
    proc=subprocess.Popen(['/usr/bin/bash',str(script)],stdin=slave,stdout=slave,stderr=slave,env=c.env,start_new_session=True)
    os.close(slave);chunks=[];buffer=b''
    steps=[('请输入选项: ',b'4\n'),('按回车返回',b'\n'),('请输入选项: ',b'3\n'),('请输入选项 > ',b'0\n'),
           ('请输入选项: ',b'12\n'),('请选择 > ',b'2\n'),('请输入证书父目录',b'\n'),('按回车返回',b'\n'),
           ('请选择 > ',b'0\n'),('请输入选项: ',b'0\n')]
    deadline=time.monotonic()+20
    try:
        while time.monotonic()<deadline:
            ready,_,_=select.select([master],[],[],.1)
            if ready:
                try:data=os.read(master,65536)
                except OSError:break
                if not data:break
                chunks.append(data);buffer+=data
                if steps and steps[0][0].encode() in buffer:
                    prompt,answer=steps.pop(0);buffer=buffer.split(prompt.encode(),1)[1]
                    os.write(master,answer)
            elif proc.poll() is not None:break
        code=proc.wait(timeout=max(.1,deadline-time.monotonic()))
        assert code==0 and not steps
    finally:
        if proc.poll() is None:proc.kill();proc.wait()
        os.close(master)
    raw=b''.join(chunks);(c.root/'tty.ansi').write_bytes(raw)
    text=raw.decode();(c.root/'tty.txt').write_text(re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]','',text))
    assert text.count('\x1b[2J')>=7
    status=text.index('CADDY_STATUS_FIXTURE');pause=text.index('按回车返回',status)
    assert '\x1b[2J' not in text[status:pause]
    assert '\x1b[2J' in text[pause:]

p=argparse.ArgumentParser();p.add_argument('--script',required=True);p.add_argument('--evidence-dir',required=True)
p.add_argument('--logrotate-bin',required=True);p.add_argument('--only',default='')
a=p.parse_args();script=Path(a.script).resolve();logrotate=Path(a.logrotate_bin).resolve();out=Path(a.evidence_dir).resolve()
assert out.is_relative_to(Path('/tmp')) and script.is_relative_to(Path('/tmp'))
out.mkdir(mode=0o700,parents=True,exist_ok=False)
results=[]
cases=[menu,install_ownership,install_cancel,partial_install,uninstall_cancel,uninstall_all,cascade_refused,
       certificate_context,certificate_empty,logs,rotation_actual,rotation_rollback,rotation_unsafe,rotation_cancel,tty_pages]
for test in cases:
    if a.only and test.__name__ not in a.only.split(','):continue
    try:test();status='passed';reason=''
    except Exception as exc:status='failed';reason=repr(exc)
    record={'case':test.__name__,'status':status,'reason':reason};results.append(record)
    print(status.upper()+' '+test.__name__+' '+reason,flush=True)
    summary={'sourceSha256':hashlib.sha256(script.read_bytes()).hexdigest(),'results':results,
             'passed':sum(x['status']=='passed' for x in results),'failed':sum(x['status']=='failed' for x in results),
             'boundaries':{'packages':'mock apt/dpkg, real ledger filesystem','services':'mock systemctl/journalctl',
                           'rotation':'real Debian logrotate binary; real file growth/time-state/compression', 'terminal':'real PTY'}}
    (out/'summary.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False))
sys.exit(1 if summary['failed'] else 0)
