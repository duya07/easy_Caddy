#!/usr/bin/env python3
"""Private Caddy process + internal CA + genuine PTY; never operates system Caddy."""
import argparse
import errno
import hashlib
import http.client
import json
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import socket
import ssl
import struct
import subprocess
import termios
import time
import fcntl


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--script',required=True)
    ap.add_argument('--caddy-bin',required=True)
    ap.add_argument('--evidence-dir',required=True)
    args=ap.parse_args()
    root=Path(args.evidence_dir).resolve()
    assert str(root).startswith('/tmp/') and os.geteuid()==0
    root.mkdir(mode=0o700)
    for name in ['bin','config','state','home','data','cache','units','worker']:
        (root/name).mkdir(mode=0o700)
    script=Path(args.script).resolve();caddy=Path(args.caddy_bin).resolve()
    subprocess.run(['/bin/bash','-n',str(script)],check=True)
    sockets=[];ports=[]
    for _ in range(3):
        s=socket.socket();s.bind(('127.0.0.1',0));sockets.append(s);ports.append(s.getsockname()[1])
    admin,http_port,https_port=ports
    config=root/'config/Caddyfile';storage=root/'storage'
    config.write_text('{\n admin 127.0.0.1:'+str(admin)+'\n http_port '+str(http_port)+'\n https_port '+str(https_port)+
                      '\n default_bind 127.0.0.1\n skip_install_trust\n cert_issuer internal {\n lifetime 72h\n }\n storage file_system {\n root '+json.dumps(str(storage))+'\n }\n}\nhttp://health.invalid {\n respond "health"\n}\n')
    (root/'registry').write_text('')
    for tool,body in {
        'sudo':'#!/bin/bash\nexec "$@"\n',
        'journalctl':'#!/bin/bash\nexit 0\n',
        'systemctl':'''#!/bin/bash
printf '%s\n' "$*" >> "$UX_ROOT/systemctl.trace"
case "$1" in
 show) case "$*" in *MainPID*) if [ -e "$UX_ROOT/caddy.pid" ]; then cat "$UX_ROOT/caddy.pid"; else echo 0; fi;; *User*) echo root;; esac;;
 is-active) echo active;;
 reload) [ -e "$UX_ROOT/caddy.pid" ] || exit 0
  exec "$UX_CADDY" reload --force --address "$UX_ADMIN" --config "$CADDYFILE" --adapter caddyfile;;
 daemon-reload|enable) exit 0;;
 *) echo 'Blocked unexpected service operation' >&2;exit 90;;
esac
''',
    }.items():
        p=root/'bin'/tool;p.write_text(body);p.chmod(0o700)
    (root/'bin/caddy').symlink_to(caddy)
    env=os.environ.copy()
    env.update(EASY_CADDY_TEST_MODE='1',PATH=str(root/'bin')+':/usr/bin:/bin',UX_ROOT=str(root),UX_CADDY=str(caddy),
               UX_ADMIN='127.0.0.1:'+str(admin),CADDYFILE=str(config),PROXY_CONFIG_FILE=str(root/'registry'),
               CERT_STATE_DIR=str(root/'state'),CERT_STORAGE_DIR_OVERRIDE=str(storage),
               CERT_WORKER_INSTALL_DIR=str(root/'worker'),CERT_SYSTEMD_UNIT_DIR=str(root/'units'),
               HOME=str(root/'home'),XDG_DATA_HOME=str(root/'data'),XDG_CONFIG_HOME=str(root/'cache'),
               TERM='dumb',NO_COLOR='',COLUMNS='40')
    checks=[];steps=0
    def call(command,expected=0):
        nonlocal steps
        steps+=1
        p=subprocess.run(['/bin/bash','-c','source "$1" || exit 98; '+command,'_',str(script)],env=env,capture_output=True,text=True,timeout=35)
        (root/f'step-{steps:03d}.json').write_text(json.dumps({'command':command,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr},ensure_ascii=False,indent=2))
        assert p.returncode==expected,(command,p.returncode,p.stdout,p.stderr)
        return p
    def runtime():
        conn=http.client.HTTPConnection('127.0.0.1',admin,timeout=4)
        conn.request('GET','/config/')
        res=conn.getresponse();data=res.read();conn.close()
        assert res.status==200
        return json.loads(data)
    def wait_for(callback,seconds=20):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            try:
                value=callback()
                if value:return value
            except (OSError,ValueError,AssertionError):pass
            time.sleep(.1)
        raise AssertionError('Observable condition did not complete before deadline')
    def has_certificate():
        matches=list((storage/'certificates').glob('*/alpha.test/alpha.test.crt'))
        return matches[0] if matches else None
    master=slave=None;watch=None;daemon=None;buf=bytearray();status='failed'
    log=(root/'caddy.log').open('wb')
    def read_until(marker,seconds=25):
        deadline=time.monotonic()+seconds
        while time.monotonic()<deadline:
            if marker.encode() in buf:return
            if select.select([master],[],[],.2)[0]:
                try:chunk=os.read(master,65536)
                except OSError as exc:
                    if exc.errno!=errno.EIO:raise
                    chunk=b''
                if chunk:buf.extend(chunk)
                elif watch.poll() is not None:break
        raise AssertionError('PTY did not reach '+marker+'; '+buf.decode('utf-8','replace')[-1800:])
    try:
        call('certificate_request alpha.test on 2; set_certificate_export_directory '+shlex.quote(str(root/'exports'))+'; register_certificate_export alpha.test')
        assert (root/'state/automation/alpha.test').read_text().strip()=='on 2 waiting'
        checks.append('request-is-pending-before-real-daemon-start')
        master,slave=pty.openpty()
        fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',28,40,0,0))
        attrs=termios.tcgetattr(slave);attrs[3]|=termios.ECHO;termios.tcsetattr(slave,termios.TCSANOW,attrs)
        watch=subprocess.Popen(['/bin/bash','-c','source "$1"; certificate_watch_domain alpha.test','_',str(script)],env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True)
        os.close(slave);slave=None
        read_until('请选择 > ')
        os.write(master,b'\n')
        read_until('还在等待可用证书')
        for s in sockets:s.close()
        sockets=[]
        daemon=subprocess.Popen([str(caddy),'run','--adapter','caddyfile','--config',str(config)],env=env,stdout=log,stderr=log,start_new_session=True)
        (root/'caddy.pid').write_text(str(daemon.pid))
        cert=wait_for(has_certificate)
        read_until('证书已经签发完成！')
        watch.wait(timeout=30)
        assert watch.returncode==0
        checks.append('real-PTY-observes-internal-CA-issuance')
        assert (root/'state/automation/alpha.test').read_text().strip()=='on 2 active'
        assert (root/'exports/alpha.test/fullchain.pem').read_bytes()==cert.read_bytes()
        assert (root/'exports/alpha.test/privkey.pem').stat().st_mode&0o077==0
        assert str(root/'exports/alpha.test/fullchain.pem') in buf.decode('utf-8')
        checks.append('actual-copy-at-displayed-path-with-restricted-key')
        data=runtime()
        policies=data['apps']['tls']['automation']['policies']
        assert any('alpha.test' in x.get('subjects',[]) and abs(x.get('renewal_window_ratio',0)-2/3)<.00001 for x in policies)
        checks.append('days-window-is-applied-in-running-Caddy')
        context=ssl.create_default_context(cafile=str(storage/'pki/authorities/local/root.crt'))
        with socket.create_connection(('127.0.0.1',https_port),timeout=5) as tcp:
            with context.wrap_socket(tcp,server_hostname='alpha.test') as tls:
                tls.sendall(b'GET / HTTP/1.1\r\nHost: alpha.test\r\nConnection: close\r\n\r\n')
                received=b''
                while True:
                    part=tls.recv(8192)
                    if not part:break
                    received+=part
        assert b'404' in received.split(b'\r\n',1)[0] and b'managed for certificate issuance' in received
        checks.append('verified-TLS-SNI-and-real-HTTP-response')
        call('certificate_automation_set alpha.test off 0')
        fixed=runtime()['apps']['tls']['certificates']['load_files']
        assert any('easy-caddy-fixed' in x.get('certificate','') for x in fixed)
        assert (root/'state/automation/alpha.test').read_text().strip()=='off 0 fixed'
        checks.append('disable-reloads-real-Caddy-with-fixed-certificate')
        call('certificate_automation_set alpha.test on 2')
        assert not runtime()['apps']['tls'].get('certificates',{}).get('load_files')
        checks.append('reenable-removes-static-loader-in-running-Caddy')
        p=call('certificate_main_summary')
        assert '1/1' in p.stdout and '已复制' in p.stdout
        checks.append('main-summary-displays-ready-certificate')
        status='passed'
    finally:
        for s in sockets:s.close()
        if watch and watch.poll() is None:
            os.killpg(watch.pid,signal.SIGTERM)
            try:watch.wait(timeout=5)
            except subprocess.TimeoutExpired:os.killpg(watch.pid,signal.SIGKILL);watch.wait()
        if daemon and daemon.poll() is None:
            os.killpg(daemon.pid,signal.SIGTERM)
            try:daemon.wait(timeout=8)
            except subprocess.TimeoutExpired:os.killpg(daemon.pid,signal.SIGKILL);daemon.wait()
        log.close()
        if master is not None:
            try:
                while select.select([master],[],[],0)[0]:
                    chunk=os.read(master,65536)
                    if not chunk:break
                    buf.extend(chunk)
            except OSError:pass
            os.close(master)
        if slave is not None:os.close(slave)
        (root/'terminal.txt').write_bytes(bytes(buf))
        (root/'summary.json').write_text(json.dumps({'status':status,'scriptSha256':hashlib.sha256(script.read_bytes()).hexdigest(),
          'checks':checks,'daemonExit':None if daemon is None else daemon.returncode,'ports':ports,
          'scope':'Real private internal CA issuance/TLS/HTTP, PTY, copy and native live policy reloads. OS timer enable mocked; no public CA renewal or production writes.'},ensure_ascii=False,indent=2))
    print(json.dumps({'status':status,'checks':len(checks),'ports':ports}),flush=True)


if __name__=='__main__':main()
