#!/bin/zsh
# 編譯並安裝到 ~/Applications/MeetRec.app（用固定的開發者憑證簽名，重編才不會丟系統授權）
set -e
cd "${0:A:h}"
APP=build/MeetRec.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS
cp Info.plist $APP/Contents/Info.plist
swiftc -O Sources/*.swift -o $APP/Contents/MacOS/MeetRec
codesign --force --sign 240813A71E965C988CFFE2FDF5F6663FF78A0E89 $APP
mkdir -p ~/Applications
rm -rf ~/Applications/MeetRec.app && cp -R $APP ~/Applications/
echo "installed ~/Applications/MeetRec.app"
