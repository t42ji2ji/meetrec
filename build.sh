#!/bin/zsh
# 編譯 MeetRec.app。
#   ./build.sh            開發版：Apple Development 簽名，裝到 ~/Applications（重編才不會丟系統授權）
#   RELEASE=1 ./build.sh  發佈版：Developer ID＋hardened runtime＋時間戳，只輸出 build/MeetRec.app（release.sh 用）
set -e
cd "${0:A:h}"
APP=build/MeetRec.app
if [ -n "$RELEASE" ]; then
  ID=40EE56946432E9A272F0B129ED83D5E843B5EAE8
  SIGN=(--options runtime --timestamp)
else
  ID=240813A71E965C988CFFE2FDF5F6663FF78A0E89
  SIGN=()
fi
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Frameworks $APP/Contents/Resources
cp Info.plist $APP/Contents/Info.plist
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns $APP/Contents/Resources/
swiftc -O -target arm64-apple-macos15.0 Sources/*.swift -o $APP/Contents/MacOS/MeetRec
# 轉逐字稿、分說話者的輔助程式（./vendor.sh 產生）；簽名要由內往外
[ -x vendor/bin/whisper-cli ] || ./vendor.sh
cp vendor/bin/whisper-cli vendor/bin/sherpa-diarize $APP/Contents/MacOS/
cp vendor/bin/libonnxruntime.dylib $APP/Contents/Frameworks/
codesign --force $SIGN --sign $ID $APP/Contents/Frameworks/libonnxruntime.dylib $APP/Contents/MacOS/whisper-cli $APP/Contents/MacOS/sherpa-diarize
codesign --force $SIGN --entitlements MeetRec.entitlements --sign $ID $APP
codesign --verify --deep --strict $APP
if [ -z "$RELEASE" ]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/MeetRec.app && cp -R $APP ~/Applications/
  echo "installed ~/Applications/MeetRec.app"
fi
