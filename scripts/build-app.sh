#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
product_name="CodexQuota"
app_name="Codex Quota.app"
dist_dir="$project_root/dist"
app_dir="$dist_dir/$app_name"

cd "$project_root"
swift build -c release --product "$product_name"
swift build -c release --product "CodexQuotaLauncher"
bin_dir="$(swift build -c release --show-bin-path)"

if [[ "$app_dir" != "$project_root/dist/"* ]]; then
    print -u2 "拒绝清理意外路径：$app_dir"
    exit 1
fi

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Helpers"
cp "$bin_dir/$product_name" "$app_dir/Contents/MacOS/$product_name"
cp "$bin_dir/CodexQuotaLauncher" "$app_dir/Contents/Helpers/CodexQuotaLauncher"
cp "$project_root/Resources/Info.plist" "$app_dir/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - --timestamp=none "$app_dir/Contents/Helpers/CodexQuotaLauncher"
    codesign --force --sign - --timestamp=none "$app_dir"
fi

print "已生成：$app_dir"
