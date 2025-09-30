#!/usr/bin/env bash
set -euo pipefail

# Google Chrome macOS Uninstaller
# --------------------------------
# Options:
#   --dry-run          : 実際には削除せず、実行内容のみ表示
#   --keep-data        : ユーザープロファイル/キャッシュ等は残す（アプリ本体のみ削除）
#   --keep-keystone    : Google Software Update(Keystone) 関連を残す（他のGoogleアプリを使っている場合に推奨）
#   --force            : 確認プロンプトをスキップして実行
#
# 例:  完全削除（アプリ/データ/Keystone 含む）
#   bash uninstall_chrome.sh
# 例:  アプリ本体のみ削除（データ保持）
#   bash uninstall_chrome.sh --keep-data --keep-keystone
# 例:  何が消えるか先に確認
#   bash uninstall_chrome.sh --dry-run

if [[ $(uname) != "Darwin" ]]; then
  echo "[ERROR] このスクリプトは macOS 専用です。" >&2
  exit 1
fi

DRY_RUN=false
KEEP_DATA=false
KEEP_KEYSTONE=false
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --keep-data) KEEP_DATA=true ;;
    --keep-keystone) KEEP_KEYSTONE=true ;;
    --force) FORCE=true ;;
    *) echo "[ERROR] 不明なオプション: $arg" >&2; exit 2 ;;
  esac
done

# Utility: run or echo
run() {
  if $DRY_RUN; then
    echo "+ $*"
  else
    eval "$@"
  fi
}

remove_path() {
  local p="$1"
  if [[ -e "$p" || -L "$p" ]]; then
    echo "削除: $p"
    run "rm -rf -- '$p'"
  fi
}

unload_launchd() {
  local id="$1"; local domain="$2" # user|system
  if launchctl list | grep -q "$id"; then
    echo "launchctl remove: $id ($domain)"
    if [[ "$domain" == "system" ]]; then
      run "sudo launchctl bootout system /Library/LaunchDaemons/$id.plist || true"
    else
      run "launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/$id.plist || true"
    fi
  fi
}

confirm() {
  if $FORCE; then return 0; fi
  echo "\n=== 実行確認 ==="
  echo "  DRY_RUN       : $DRY_RUN"
  echo "  KEEP_DATA     : $KEEP_DATA"
  echo "  KEEP_KEYSTONE : $KEEP_KEYSTONE"
  read -r -p "続行しますか？ [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# 1) Chrome を終了
if pgrep -a "Google Chrome" >/dev/null 2>&1; then
  echo "Chrome を終了します…"
  run "osascript -e 'tell application \"Google Chrome\" to quit' || true"
  sleep 1
  # 念のためプロセスを終了
  run "pkill -9 -x 'Google Chrome' || true"
  run "pkill -9 -f 'Google Chrome Helper' || true"
fi

# 削除対象のパス定義
APP_PATHS=(
  "/Applications/Google Chrome.app"
  "$HOME/Applications/Google Chrome.app"
)

DATA_PATHS=(
  "$HOME/Library/Application Support/Google/Chrome"
  "$HOME/Library/Caches/Google/Chrome"
  "$HOME/Library/Preferences/com.google.Chrome.plist"
  "$HOME/Library/Saved Application State/com.google.Chrome.savedState"
  "$HOME/Library/WebKit/Google Chrome"
  "$HOME/Library/Logs/Google/Chrome"
)

KEYSTONE_PATHS=(
  "$HOME/Library/Google/GoogleSoftwareUpdate"
  "/Library/Google/GoogleSoftwareUpdate"
  "/Library/LaunchAgents/com.google.keystone.agent.plist"
  "$HOME/Library/LaunchAgents/com.google.keystone.agent.plist"
  "/Library/LaunchDaemons/com.google.keystone.daemon.plist"
  "/Library/PrivilegedHelperTools/com.google.keystone.daemon"
  "/Library/Google/Google Chrome Brand.plist"
)

# 実行内容のプレビュー
echo "\n=== 削除プラン ==="
echo "[アプリ本体]"; printf '  %s\n' "${APP_PATHS[@]}"
if ! $KEEP_DATA; then
  echo "[ユーザーデータ/キャッシュ/設定]"; printf '  %s\n' "${DATA_PATHS[@]}"
else
  echo "[ユーザーデータ] は保持します (--keep-data)"
fi
if ! $KEEP_KEYSTONE; then
  echo "[Google Software Update(Keystone) 関連]"; printf '  %s\n' "${KEYSTONE_PATHS[@]}"
  echo "  *注意*: Keystone を削除すると、Chrome 以外の Google アプリの自動更新も止まります。"
else
  echo "[Keystone] は保持します (--keep-keystone)"
fi

if ! confirm; then
  echo "中止しました。"; exit 0
fi

# 2) アプリ本体を削除（必要に応じて sudo）
for p in "${APP_PATHS[@]}"; do
  if [[ -e "$p" ]]; then
    if [[ -w "$p" ]]; then
      remove_path "$p"
    else
      echo "管理者権限が必要なため sudo で削除: $p"
      if $DRY_RUN; then
        echo "+ sudo rm -rf -- '$p'"
      else
        sudo rm -rf -- "$p"
      fi
    fi
  fi
done

# 3) ユーザーデータ削除（任意）
if ! $KEEP_DATA; then
  for p in "${DATA_PATHS[@]}"; do
    remove_path "$p"
  done
fi

# 4) Keystone 無効化と削除（任意）
if ! $KEEP_KEYSTONE; then
  # launchd 停止
  unload_launchd com.google.keystone.agent user || true
  unload_launchd com.google.keystone.daemon system || true
  # ファイル削除
  for p in "${KEYSTONE_PATHS[@]}"; do
    if [[ "$p" == /Library/* || "$p" == /System/Library/* ]]; then
      if $DRY_RUN; then
        echo "+ sudo rm -rf -- '$p'"
      else
        [[ -e "$p" || -L "$p" ]] && sudo rm -rf -- "$p"
      fi
    else
      remove_path "$p"
    fi
  done
fi

# 5) ゴミ箱ではなく完全削除のため、追加の掃除（存在すれば）
EXTRA=(
  "$HOME/Library/Containers/com.google.Chrome"
  "$HOME/Library/Group Containers/com.google.Chrome"
)
for p in "${EXTRA[@]}"; do
  remove_path "$p"
fi

# 6) 完了メッセージ
echo "\n✅ 完了しました。必要に応じて Mac を再起動するとクリーンになります。"
if $KEEP_DATA; then
  echo "  ※ プロファイルや履歴等は保持されています (--keep-data)。再インストール後も引き継がれます。"
fi
if $KEEP_KEYSTONE; then
  echo "  ※ Google Software Update(Keystone) は残しています (--keep-keystone)。"
else
  echo "  ※ Keystone を削除したため、他の Google アプリの自動更新が無効化されている可能性があります。必要なら再インストールしてください。"
fi
