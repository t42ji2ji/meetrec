# MeetRec

[English](#english) · [中文](#中文)

## 中文

MeetRec 是 macOS 選單列上的會議錄音工具。瀏覽器開始用麥克風（Google Meet、Teams 等網頁會議）或 Slack huddle 開始時，它會問要不要錄；錄完自動轉成逐字稿、分出說話者。錄音和轉錄都在你的 Mac 上完成，不會上傳。

- 錄下你的麥克風和會議裡其他人的聲音，存成立體聲：左聲道是你，右聲道是對方
- 用 whisper.cpp 轉逐字稿，中英文自動偵測，可選繁體／簡體
- 分辨不同說話者，名字可以改
- 點逐字稿跳到那個時間播放；「逐句」和「編輯」兩種檢視，直接改字
- 全部取代、調整字級、匯出 SRT／TXT
- 電腦上有 [Claude Code](https://code.claude.com/docs/en/setup) 或 [Codex](https://developers.openai.com/codex/cli) 的話，可以在側欄跟 AI 討論這場會議（⌘E）

### 安裝

從 [Releases](../../releases) 下載 `MeetRec-<版本>.dmg`，打開後把 MeetRec 拖進「應用程式」。

需要 macOS 15 以上、Apple Silicon（M 系列晶片）。第一次轉錄時會從 Hugging Face 下載語音模型（預設 Whisper large-v3-turbo，約 570 MB；設定裡可以換成更小或更準的）。

### 權限

- **麥克風**：錄你的聲音
- **錄製系統音訊**：錄瀏覽器／Slack 裡其他人的聲音
- **自動化（瀏覽器）**：讀會議分頁的標題，用來替錄音命名；不給也能錄

### 隱私

錄音、轉錄、說話者辨識都在本機執行，錄音存在 `~/Music/會議錄音`。只有兩種情況會連網：第一次下載模型，以及你主動使用 AI 對話時——那時逐字稿會透過你自己登入的 Claude Code 或 Codex 送給 Anthropic 或 OpenAI。

錄音前請先取得與會者同意，並遵守當地法律。

### 從原始碼編譯

需要 Xcode command line tools 和 cmake。`./vendor.sh` 會下載並編譯 whisper.cpp、sherpa-onnx；`./build.sh` 編譯並裝到 `~/Applications`。`build.sh` 和 `release.sh` 裡的簽名身分是作者的，自己編譯時換成你的。

## English

MeetRec is a menu bar meeting recorder for macOS. When your browser starts using the microphone (Google Meet, Teams and other web meetings) or a Slack huddle starts, it asks whether to record. Afterwards it transcribes the recording and labels the speakers. Recording and transcription run entirely on your Mac; nothing is uploaded.

- Records your microphone and the other participants as stereo: you on the left channel, them on the right
- Transcribes with whisper.cpp, detecting Chinese or English automatically
- Tells speakers apart, with names you can edit
- Click a line to jump there in playback; switch between a per-line view and an editor view to fix text quickly
- Replace all, adjustable text size, export to SRT or TXT
- If [Claude Code](https://code.claude.com/docs/en/setup) or [Codex](https://developers.openai.com/codex/cli) is installed, discuss the meeting with AI in a side panel (⌘E)

### Install

Download `MeetRec-<version>.dmg` from [Releases](../../releases), open it and drag MeetRec into Applications.

Requires macOS 15 or later on Apple Silicon. The first transcription downloads speech models from Hugging Face (Whisper large-v3-turbo by default, about 570 MB; you can pick a smaller or more accurate one in Settings).

### Permissions

- **Microphone**: records your voice
- **System audio recording**: records the other participants in the browser or Slack
- **Automation (browser)**: reads the meeting tab's title to name the recording; optional

### Privacy

Recording, transcription and speaker detection all run locally; recordings are saved to `~/Music/會議錄音`. MeetRec goes online only to download models the first time, and when you use the AI chat — then the transcript is sent to Anthropic or OpenAI through your own signed-in Claude Code or Codex.

Get consent from participants before recording, and follow the laws where you are.

### Building from source

Requires Xcode command line tools and cmake. `./vendor.sh` downloads and builds whisper.cpp and sherpa-onnx; `./build.sh` builds the app and installs it to `~/Applications`. The signing identities in `build.sh` and `release.sh` are the author's; replace them with yours.

## License

GPL-3.0. Bundled components and models keep their own licenses; see `Resources/licenses`.
