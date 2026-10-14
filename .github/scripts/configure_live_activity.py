"""Enable embedding only with a valid extension profile; keep existing IPA installable."""
import base64,datetime,fnmatch,os,plistlib,re,subprocess,sys
from pathlib import Path

def configure_project(path, bundle, team='', profile_uuid='', signed=False):
    text=Path(path).read_text()
    start=text.index('  SonivoLiveActivity:\n');end=text.index('  SonivoUnitTests:\n',start)
    section=text[start:end]
    section=re.sub(r'PRODUCT_BUNDLE_IDENTIFIER:.*',f'PRODUCT_BUNDLE_IDENTIFIER: {bundle}.LiveActivity',section)
    section=re.sub(r'DEVELOPMENT_TEAM:.*',f'DEVELOPMENT_TEAM: "{team}"',section)
    section=re.sub(r'CODE_SIGNING_ALLOWED:.*','CODE_SIGNING_ALLOWED: '+('YES' if signed and profile_uuid else 'NO'),section)
    section=re.sub(r'CODE_SIGNING_REQUIRED:.*','CODE_SIGNING_REQUIRED: '+('YES' if signed and profile_uuid else 'NO'),section)
    section=re.sub(r'PROVISIONING_PROFILE_SPECIFIER:.*',f'PROVISIONING_PROFILE_SPECIFIER: "{profile_uuid}"',section)
    enabled=bool(profile_uuid) if signed else True
    text=text[:start]+section+text[end:]
    if not enabled:
        text=text.replace('      - target: SonivoLiveActivity\n        embed: true\n','')
    text=re.sub(r'NSSupportsLiveActivities:.*','NSSupportsLiveActivities: '+str(enabled).lower(),text)
    text=re.sub(r'SonivoLiveActivityEmbedded:.*','SonivoLiveActivityEmbedded: '+str(enabled).lower(),text)
    Path(path).write_text(text)
    return enabled

def validate_profile(widget, app, bundle, team, now=None):
    now=now or datetime.datetime.now(datetime.timezone.utc)
    ent=widget.get('Entitlements',{})
    prefix=team+'.';pattern=ent.get('application-identifier','')
    if not pattern.startswith(prefix) or not fnmatch.fnmatchcase(bundle+'.LiveActivity',pattern[len(prefix):]):
        raise ValueError('Live Activity profile does not match the extension bundle identifier')
    if ent.get('com.apple.developer.team-identifier') != team:
        raise ValueError('Live Activity profile belongs to another team')
    expiration=widget.get('ExpirationDate')
    if not expiration or expiration.replace(tzinfo=datetime.timezone.utc) <= now:
        raise ValueError('Live Activity profile has expired')
    if not set(widget.get('DeveloperCertificates',[])).intersection(app.get('DeveloperCertificates',[])):
        raise ValueError('App and Live Activity profiles have no signing certificate in common')
    if bool(ent.get('get-task-allow')) != bool(app.get('Entitlements',{}).get('get-task-allow')):
        raise ValueError('App and Live Activity distribution types differ')
    if app.get('ProvisionedDevices') and not set(app['ProvisionedDevices']).issubset(widget.get('ProvisionedDevices',[])):
        raise ValueError('Live Activity profile does not cover all app devices')
    if not widget.get('UUID'):raise ValueError('Live Activity profile UUID is missing')
    return widget['UUID']

def main():
    signed=os.environ.get('HAS_SIGNING')=='true';bundle=os.environ.get('BUNDLE_ID','com.smoze.sonivo');team=os.environ.get('TEAM_ID','')
    raw=os.environ.get('ACTIVITY_PROFILE_BASE64','').strip();uuid=''
    if signed and raw:
        folder=Path(os.environ['RUNNER_TEMP']);dest=folder/'activity.mobileprovision'
        dest.write_bytes(base64.b64decode(''.join(raw.split()),validate=True))
        def decode(path):
            return plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(path)],stderr=subprocess.DEVNULL))
        widget,app=decode(dest),decode(os.environ['PROV_FILE'])
        uuid=validate_profile(widget,app,bundle,team)
        target=Path.home()/'Library/MobileDevice/Provisioning Profiles'/f'{uuid}.mobileprovision'
        target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(dest.read_bytes())
        with open(os.environ['GITHUB_ENV'],'a') as env:env.write(f'ACTIVITY_PROV_FILE={dest}\n')
    enabled=configure_project('project.yml',bundle,team,uuid,signed)
    print('Live Activity extension: '+('embedded' if enabled else 'validation only; separate profile is not configured'))
if __name__=='__main__':main()
