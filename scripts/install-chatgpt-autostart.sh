#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
source_app="$project_root/dist/Tokivue.app"
applications_dir="${HOME:?}/Applications"
installed_app="$applications_dir/Tokivue.app"
launch_agents_dir="${HOME:?}/Library/LaunchAgents"
launcher_plist="$launch_agents_dir/com.local.codex-quota.chatgpt-launcher.plist"
launcher_template="$project_root/Resources/com.local.codex-quota.chatgpt-launcher.plist"
launcher_path="$installed_app/Contents/Helpers/CodexQuotaLauncher"
launcher_label="com.local.codex-quota.chatgpt-launcher"
user_domain="gui/$(id -u)"

"$project_root/scripts/build-app.sh"
mkdir -p "$applications_dir" "$launch_agents_dir"

launchctl bootout "$user_domain/$launcher_label" 2>/dev/null || true
# Preserve compatibility with the previous app name and launcher identity.
legacy_app="$applications_dir/Codex Quota.app"
for app_pid in $(pgrep -x CodexQuota || true); do
    app_command="$(ps -p "$app_pid" -o comm=)"
    if [[ "$app_command" == "$legacy_app/Contents/MacOS/CodexQuota" || "$app_command" == "$installed_app/Contents/MacOS/CodexQuota" ]]; then
        kill -TERM "$app_pid"
        for attempt in {1..30}; do
            kill -0 "$app_pid" 2>/dev/null || break
            sleep 0.1
        done
    fi
done
if [[ -d "$legacy_app" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy_app/Contents/Info.plist")" == "com.local.codex-quota" ]]; then
    backup_dir="${HOME:?}/.codex-usage-monitor/backups/tokivue-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    mv "$legacy_app" "$backup_dir/"
fi
/usr/bin/ditto "$source_app" "$installed_app"
/usr/bin/ditto "$launcher_template" "$launcher_plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $launcher_path" "$launcher_plist"
chmod 644 "$launcher_plist"

launchctl bootstrap "$user_domain" "$launcher_plist"
launchctl enable "$user_domain/$launcher_label"
launchctl kickstart -k "$user_domain/$launcher_label"

print "已安装应用：$installed_app"
print "已启用 ChatGPT 联动启动：$launcher_label"
