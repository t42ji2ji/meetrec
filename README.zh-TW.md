<div align="center">

<img src="site/assets/icon.png" width="112" alt="MeetRec 圖示">

# MeetRec

住在 Mac 選單列、分得出誰說了什麼的會議錄音工具。

[**下載**](https://github.com/t42ji2ji/meetrec/releases/latest) · [官網](https://meetrec.dorara.app) · [English](README.md)

<a href="https://meetrec.dorara.app/#video"><img src="site/assets/poster.jpg" width="640" alt="MeetRec 介紹影片"></a>

[▶ 看 80 秒介紹影片](https://meetrec.dorara.app/#video)

</div>

## 功能

**分得出誰說了什麼。** 你和其他與會者分開錄成兩個聲道，逐字稿每一句都標上說話的人；改一次名字，這個人說的每一句都跟著改。

<img src="site/assets/transcript.png" width="640" alt="逐字稿，每句標著說話者">

**點一個人，看他整場的發言。** 點某人的發言時間，列出他每一段發言；點任一段，播放就跳到那裡。

<img src="site/assets/speaker-turns.png" width="640" alt="從發言時間展開某人的每段發言">

**直接用你已經在用的 AI。** 按 ⌘E 和電腦上的 [Claude Code](https://code.claude.com/docs/en/setup) 或 [Codex](https://developers.openai.com/codex/cli) 討論這場會議，用你自己的登入，不用另外申請 API key。

<img src="site/assets/ai-sidebar.png" width="640" alt="逐字稿旁的 AI 對話側欄">

**匯入檔案和連結。** 拖進音檔或影片，或貼上 YouTube、Podcast、Spotify 單集連結，一樣轉成逐字稿。

其他：Google Meet、Teams、Slack huddle 開始時問要不要錄；用 whisper.cpp 在本機轉錄（中英文），或用你自己的 Groq、OpenAI key 雲端轉錄；常用詞提示；改字、搜尋、匯出 SRT／TXT。

## 安裝

從 [Releases](https://github.com/t42ji2ji/meetrec/releases/latest) 下載 `.dmg`，把 MeetRec 拖進「應用程式」。需要 macOS 15 以上、Apple Silicon。第一次在本機轉錄會下載語音模型（預設約 570 MB）。

## 隱私

錄音、轉錄、分辨說話者預設都在你的 Mac 上完成。只有下載模型、開啟雲端轉錄、透過你自己的 Claude Code 或 Codex 使用 AI 對話、從連結匯入時才會連網。錄音前請先取得與會者同意。

## 從原始碼編譯

需要 Xcode command line tools 和 cmake。

```sh
./vendor.sh   # 編譯 whisper.cpp 和 sherpa-onnx
./build.sh    # 編譯 app 並裝到 ~/Applications
```

`build.sh` 和 `release.sh` 裡的簽名身分換成你自己的。

## 授權

GPL-3.0。內附的元件和模型各自沿用原本的授權，見 `Resources/licenses`。
