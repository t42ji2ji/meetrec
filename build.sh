#!/bin/zsh
# 編譯並安裝到 ~/Applications/MeetRec.app（用固定的開發者憑證簽名，重編才不會丟系統授權）
set -e
cd "${0:A:h}"
APP=build/MeetRec.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS
cp Info.plist $APP/Contents/Info.plist
swiftc -O -target arm64-apple-macos15.0 Sources/*.swift -o $APP/Contents/MacOS/MeetRec
# 轉逐字稿、分說話者的輔助程式（./vendor.sh 產生）；簽名要由內往外
[ -x vendor/bin/whisper-cli ] || ./vendor.sh
mkdir -p $APP/Contents/Frameworks
cp vendor/bin/whisper-cli vendor/bin/sherpa-diarize $APP/Contents/MacOS/
cp vendor/bin/libonnxruntime.dylib $APP/Contents/Frameworks/
ID=240813A71E965C988CFFE2FDF5F6663FF78A0E89
codesign --force --sign $ID $APP/Contents/Frameworks/libonnxruntime.dylib $APP/Contents/MacOS/whisper-cli $APP/Contents/MacOS/sherpa-diarize
codesign --force --sign $ID $APP
mkdir -p ~/Applications
rm -rf ~/Applications/MeetRec.app && cp -R $APP ~/Applications/
echo "installed ~/Applications/MeetRec.app"
