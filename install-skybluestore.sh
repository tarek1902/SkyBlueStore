#!/bin/sh
# Stable Sky Blue Store installer: verified latest manifest, no automatic reboot.
set -eu
[ "$(id -u)" = 0 ] || { echo 'Run as root on the receiver.'; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'Python 3 is required.'; exit 1; }
command -v opkg >/dev/null 2>&1 || { echo 'This installer needs an opkg Enigma2 image.'; exit 1; }
exec python3 - <<'STORE_PY'
import hashlib,json,os,re,shutil,subprocess,tarfile,tempfile,time
from pathlib import Path
from urllib.request import build_opener,HTTPRedirectHandler
BASE='https://updates.skyblue1.us/e2/'
PACKAGE='enigma2-plugin-extensions-skybluestore'
class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self,*args):raise ValueError('Unexpected redirect')
def validate(m):
    v=m.get('version','')
    if m.get('package')!=PACKAGE or not re.fullmatch(r'\d{1,4}\.\d{1,4}\.\d{1,4}',v):raise ValueError('Invalid release')
    if m.get('url')!=BASE+PACKAGE+'_'+v+'_all.ipk':raise ValueError('Unexpected package URL')
    if type(m.get('size')) is not int or not 1<=m['size']<=67108864:raise ValueError('Invalid size')
    if not re.fullmatch('[a-f0-9]{64}',m.get('sha256','')):raise ValueError('Invalid checksum')
    return v
temporary=None
try:
    opener=build_opener(NoRedirect())
    with opener.open(BASE+'store-latest.json',timeout=25) as response:raw=response.read(16385)
    if len(raw)>16384:raise ValueError('Manifest too large')
    m=json.loads(raw);v=validate(m)
    result=subprocess.run(['opkg','status',PACKAGE],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    current=re.search(r'^Version:\s*(\S+)',result.stdout.decode('utf-8','replace'),re.M)
    plugin=Path('/usr/lib/enigma2/python/Plugins/Extensions/SkyBlueStore')
    if current and (plugin/'plugin.py').is_file():
        if subprocess.run(['opkg','compare-versions',current.group(1),'>=',v]).returncode==0:
            print('Sky Blue Store is already up to date: '+current.group(1));raise SystemExit(0)
    if shutil.disk_usage('/tmp').free<m['size']+4194304:raise ValueError('Not enough temporary space')
    fd,temporary=tempfile.mkstemp(prefix='skybluestore-',suffix='.ipk')
    digest=hashlib.sha256();total=0
    with os.fdopen(fd,'wb') as output:
        with opener.open(m['url'],timeout=60) as response:
            while True:
                chunk=response.read(65536)
                if not chunk:break
                total+=len(chunk)
                if total>m['size']:raise ValueError('Package exceeds declared size')
                digest.update(chunk);output.write(chunk)
    if total!=m['size'] or digest.hexdigest()!=m['sha256']:raise ValueError('Package checksum mismatch')
    with open(temporary,'rb') as stream:
        if stream.read(8)!=b'!<arch>\n':raise ValueError('Not an IPK package')
    if plugin.exists():
        backups=Path('/home/root/skyblue-store-backups');backups.mkdir(mode=0o700,parents=True,exist_ok=True)
        needed=sum(p.stat().st_size for p in plugin.rglob('*') if p.is_file())
        if shutil.disk_usage(backups).free<needed+4194304:raise ValueError('Not enough space for rollback backup')
        backup=backups/('before-install-'+str(time.time_ns())+'.tar.gz')
        with tarfile.open(backup,'w:gz') as archive:
            archive.add(str(plugin),arcname='SkyBlueStore')
            settings=Path('/etc/enigma2/skyblue-store-theme')
            if settings.is_file():archive.add(str(settings),arcname='skyblue-store-theme')
        backup.chmod(0o600);print('Rollback backup: '+str(backup))
    command=['opkg']+(['--force-reinstall'] if current and current.group(1)==v else [])+['install',temporary]
    if subprocess.run(command).returncode:raise ValueError('opkg installation failed; see output above')
    print('Sky Blue Store '+v+' installed. Restart the Enigma2 GUI from the receiver menu.')
except Exception as error:
    print('ERROR: '+str(error)[:300]);raise SystemExit(1)
finally:
    if temporary and os.path.exists(temporary):os.unlink(temporary)
STORE_PY
