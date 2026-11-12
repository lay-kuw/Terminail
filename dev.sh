#!/bin/bash
# 開発用：Sources などが書き換わったら、自動でビルドして Terminail を起動し直す
# 止めるときは Ctrl+C
cd "$(dirname "$0")"

sig() {
  find Sources Resources build.sh Info.plist -type f -exec stat -f '%m %z %N' {} + 2>/dev/null | md5
}

echo "✦ dev モード：Sources の変更を見張っています（Ctrl+C で終了）"
last=""
while true; do
  cur=$(sig)
  if [ "$cur" != "$last" ]; then
    last=$cur
    sleep 0.5   # 複数ファイルの書き込みが終わるのを少し待つ
    last=$(sig)
    echo "✦ $(date +%T) ビルド中..." | tee -a dev.log
    pkill -x Terminail
    if bash build.sh >> dev.log 2>&1; then
      sleep 0.3
      open "build/Terminail.app"
      echo "✦ $(date +%T) 起動しました" | tee -a dev.log
    else
      echo "✦ $(date +%T) ビルド失敗（dev.log を見てね）" | tee -a dev.log
    fi
  fi
  sleep 1
done
