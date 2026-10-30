#!/usr/bin/env python3
"""Install/uninstall a user LaunchAgent; install files before loading the job."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

LABEL = 'local.codex.usage-monitor'
state = Path.home() / '.codex-usage-monitor'
plist = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
domain = 'gui/' + str(os.getuid())
parser = argparse.ArgumentParser()
parser.add_argument('--uninstall', action='store_true')
args = parser.parse_args()
if sys.platform != 'darwin':
    sys.exit('This installer is for macOS only. See README for other devices.')
if args.uninstall:
    subprocess.run(['launchctl', 'bootout', domain + '/' + LABEL], capture_output=True)
    plist.unlink(missing_ok=True)
    print('Uninstalled scheduled job; retained local data and config.')
    sys.exit()
state.mkdir(parents=True, exist_ok=True)
state.chmod(0o700)
source = Path(__file__).resolve().parent / 'monitor.py'
target = state / 'monitor.py'
shutil.copy2(source, target)
python = str(Path(sys.executable).resolve())
subprocess.run([python, str(target), 'init'], check=True)
plist.parent.mkdir(parents=True, exist_ok=True)
settings = {
    'Label': LABEL, 'ProgramArguments': [python, str(target), 'run'],
    'StartInterval': 60, 'RunAtLoad': True,
    'StandardOutPath': str(state / 'launchd.stdout.log'),
    'StandardErrorPath': str(state / 'launchd.stderr.log'),
    'EnvironmentVariables': {'PATH': '/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin'},
    'ProcessType': 'Background', 'LowPriorityIO': True,
}
with plist.open('wb') as stream:
    plistlib.dump(settings, stream)
subprocess.run(['launchctl', 'bootout', domain + '/' + LABEL], capture_output=True)
subprocess.run(['launchctl', 'bootstrap', domain, str(plist)], check=True)
print('Installed: ' + str(plist))
print('Checks: weekdays 09–18 every 10 minutes; all other times hourly, Asia/Shanghai.')
