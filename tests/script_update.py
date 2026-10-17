#!/usr/bin/env python3
"""Linux-only script updater acceptance; curl is a controlled download boundary."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--script',required=True)
    ap.add_argument('--evidence-dir',required=True)
    args=ap.parse_args()
    out=Path(args.evidence_dir).resolve()
    assert str(out).startswith('/tmp/') and os.geteuid()==0
    out.mkdir(mode=0o700)
    product=Path(args.script).read_bytes()
    assert subprocess.run(['/bin/bash','-n',args.script],capture_output=True).returncode==0
    version_match=re.search(rb"(?m)^SCRIPT_VERSION='([^']+)'$",product)
    version=version_match[1].decode() if version_match else None
    results=[]
    def fixture(name,kind='new'):
        root=out/name;root.mkdir(mode=0o700)
        source=root/'tool with spaces.sh';source.write_bytes(product);source.chmod(0o750)
        bindir=root/'bin';bindir.mkdir()
        for tool in ['systemctl','apt-get','service']:
            p=bindir/tool;p.write_text('#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$UPD_ROOT/forbidden.trace"\nexit 90\n');p.chmod(0o700)
        candidate=product
        if version:
            major,minor,patch=map(int,version.split('.'))
            new_version=f'{major}.{minor}.{patch+1}'
            candidate=candidate.replace(f"SCRIPT_VERSION='{version}'".encode(),f"SCRIPT_VERSION='{new_version}'".encode(),1)
        else:new_version='1.0.1'
        if kind=='same':candidate=product
        if kind=='older' and version:candidate=candidate.replace(f"SCRIPT_VERSION='{new_version}'".encode(),b"SCRIPT_VERSION='0.0.1'",1)
        if kind=='html':candidate=b'<!DOCTYPE html><html>download blocked</html>\n'
        if kind=='syntax':candidate+=b'\nif then\n'
        if kind=='identity':candidate=candidate.replace(b'# EASY_CADDY_SCRIPT_ID=duya07/easy_Caddy',b'# other-script')
        if kind=='execution':candidate+=b'\ntouch "$UPD_ROOT/candidate-executed"\n'
        remote=root/'remote.sh';remote.write_bytes(candidate)
        curl=bindir/'curl'
        curl.write_text('''#!/bin/bash
printf '%s\n' "$*" >> "$UPD_ROOT/curl.trace"
[ "${UPD_DOWNLOAD_FAIL:-0}" != 1 ] || exit 28
while [ "$#" -gt 0 ]; do
 case "$1" in --output|-o) shift; output=$1;; esac
 shift
done
cat -- "$UPD_CANDIDATE" > "$output" || exit 1
if [ "${UPD_CONCURRENT_CHANGE:-0}" = 1 ]; then printf '\n# external modification\n' >> "$UPD_TARGET"; fi
''');curl.chmod(0o700)
        env=os.environ.copy();env.update(PATH=str(bindir)+':/usr/bin:/bin',EASY_CADDY_TEST_MODE='1',UPD_ROOT=str(root),UPD_CANDIDATE=str(remote),UPD_TARGET=str(source),
            CERT_STATE_DIR=str(root/'state'),CADDYFILE=str(root/'Caddyfile'),PROXY_CONFIG_FILE=str(root/'registry'),CERT_WORKER_INSTALL_DIR=str(root/'worker'))
        return root,source,remote,env,new_version
    def run(root,source,env,args=(),data='',function=None):
        command=['/bin/bash',str(source),*args] if function is None else ['/bin/bash','-c','source "$1" || exit 98; '+function,'_',str(source)]
        p=subprocess.run(command,input=data,text=True,capture_output=True,env=env,timeout=20)
        index=len(list(root.glob('step-*.json')))+1
        (root/f'step-{index:02d}.json').write_text(json.dumps({'argv':command,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr},ensure_ascii=False,indent=2))
        assert not (root/'forbidden.trace').exists(),'Updater touched an unrelated service/package command'
        return p
    def case(name,callback):
        try:callback();status='passed';reason=''
        except Exception as exc:status='failed';reason=str(exc)
        results.append({'case':name,'status':status,'reason':reason})
        print(status.upper()+' '+name+' '+reason[:400],flush=True)
    def interfaces():
        root,source,_,env,_=fixture('interfaces')
        p=run(root,source,env,['--version'])
        assert p.returncode==0 and re.fullmatch(r'easy_Caddy \d+\.\d+\.\d+\n',p.stdout),(p.returncode,p.stdout,p.stderr)
        assert not (root/'curl.trace').exists()
        p=run(root,source,env,function='for f in script_update script_version_from_file script_version_compare; do declare -F "$f" >/dev/null || exit 17; done')
        assert p.returncode==0
    case('version-cli-and-public-interfaces',interfaces)
    def check_only():
        root,source,_,env,new=fixture('check-only');before=source.read_bytes()
        p=run(root,source,env,['--check-update'])
        assert p.returncode==0 and new in p.stdout,(p.returncode,p.stdout,p.stderr)
        assert source.read_bytes()==before and not list(root.glob('*.backup.*'))
        assert not (root/'worker').exists() and not (root/'state').exists()
    case('check-update-does-not-change-script-or-state',check_only)
    def successful():
        root,source,remote,env,new=fixture('successful');before=source.read_bytes();mode=source.stat().st_mode&0o777
        p=run(root,source,env,['--update'],'y\n')
        assert p.returncode==0 and '更新成功' in p.stdout,(p.returncode,p.stdout,p.stderr)
        assert source.read_bytes()==remote.read_bytes()
        backups=list(root.glob('*.backup.*'));assert len(backups)==1 and backups[0].read_bytes()==before
        assert source.stat().st_mode&0o777==mode
        assert '重新运行' in p.stdout and not (root/'state').exists() and not (root/'worker').exists()
    case('successful-atomic-update-keeps-backup-and-mode',successful)
    def rejected(kind,answer='y\n'):
        root,source,_,env,_=fixture('reject-'+kind,kind);before=source.read_bytes()
        if kind=='download':env['UPD_DOWNLOAD_FAIL']='1'
        p=run(root,source,env,['--update'],answer)
        assert source.read_bytes()==before,kind
        assert not list(root.glob('*.backup.*')),kind
        assert not list(root.glob('.easy-caddy-update.*')),kind
        if kind in ['cancel','eof','same','older']:assert p.returncode==0,(kind,p.returncode,p.stdout,p.stderr)
        else:assert p.returncode!=0,(kind,p.returncode,p.stdout,p.stderr)
    for kind in ['same','older','html','syntax','identity','download','cancel','eof']:
        case('preserve-original-'+kind,lambda kind=kind:rejected(kind,'n\n' if kind=='cancel' else '' if kind=='eof' else 'y\n'))
    def never_execute():
        root,source,_,env,_=fixture('never-execute','execution')
        p=run(root,source,env,['--check-update'])
        assert p.returncode==0 and not (root/'candidate-executed').exists()
        p=run(root,source,env,['--update'],'y\n')
        assert p.returncode==0 and not (root/'candidate-executed').exists()
    case('downloaded-candidate-is-not-executed',never_execute)
    def concurrent():
        root,source,_,env,_=fixture('concurrent');before=source.read_bytes();env['UPD_CONCURRENT_CHANGE']='1'
        p=run(root,source,env,['--update'],'y\n')
        assert p.returncode!=0 and source.read_bytes()==before+b'\n# external modification\n'
        assert not list(root.glob('*.backup.*'))
    case('concurrent-user-change-is-preserved',concurrent)
    def symlink():
        root,source,_,env,_=fixture('symlink');before=source.read_bytes();link=root/'linked.sh';link.symlink_to(source)
        p=run(root,link,env,['--update'],'y\n')
        assert p.returncode!=0 and source.read_bytes()==before and link.is_symlink()
    case('symlink-target-is-not-overwritten',symlink)
    def rename_failure():
        root,source,_,env,_=fixture('rename-failure');before=source.read_bytes()
        wrapper=root/'bin/mv';wrapper.write_text('#!/bin/bash\nexit 77\n');wrapper.chmod(0o700)
        p=run(root,source,env,['--update'],'y\n')
        assert p.returncode!=0 and source.read_bytes()==before
        assert len(list(root.glob('*.backup.*')))==1
    case('replace-failure-leaves-original-and-backup',rename_failure)
    def menu_update():
        root,source,remote,env,new=fixture('menu-update','execution')
        ctl=root/'bin/systemctl'
        ctl.write_text('#!/bin/bash\nif [ "$1" = is-active ] && [ "$2" = caddy ]; then echo inactive; exit 3; fi\nprintf "%s\\n" "$*" >> "$UPD_ROOT/forbidden.trace"\nexit 90\n');ctl.chmod(0o700)
        p=run(root,source,env,data='0\n')
        assert p.returncode==0 and '脚本版本：'+version in p.stdout and not (root/'curl.trace').exists()
        p=run(root,source,env,data='14\ny\n')
        assert p.returncode==0 and '更新成功' in p.stdout and p.stdout.count('Caddy 一键部署与管理')==1
        assert source.read_bytes()==remote.read_bytes() and not (root/'candidate-executed').exists()
    case('main-menu-is-offline-and-update-finishes-old-process',menu_update)
    def versions():
        root,source,_,env,_=fixture('version-comparison')
        p=run(root,source,env,function='script_version_compare 1.9.9 1.10.0; script_version_compare 2.0.0 1.99.99; script_version_compare 1.0.0 1.0.0')
        assert p.returncode==0 and p.stdout=='-1\n1\n0\n'
        p=run(root,source,env,['--version','extra'])
        assert p.returncode==2
    case('numeric-versions-and-strict-cli-arguments',versions)
    summary={'sourceSha256':hashlib.sha256(product).hexdigest(),'passed':sum(x['status']=='passed' for x in results),'failed':sum(x['status']=='failed' for x in results),'results':results,'boundary':'real Linux Bash/filesystem/metadata/rename; controlled curl downloader; unrelated service calls forbidden'}
    (out/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
    print(json.dumps({k:v for k,v in summary.items() if k!='results'}),flush=True)
    return 1 if summary['failed'] else 0


if __name__=='__main__':raise SystemExit(main())
