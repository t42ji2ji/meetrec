<div align="center">

<img src="site/assets/icon.png" width="112" alt="MeetRec app icon">

# MeetRec

The meeting recorder for your Mac's menu bar that knows who said what.

[**Download**](https://github.com/t42ji2ji/meetrec/releases/latest) · [Website](https://meetrec.dorara.app) · [中文](README.zh-TW.md)

<a href="https://meetrec.dorara.app/#video"><img src="site/assets/poster.jpg" width="640" alt="MeetRec intro video"></a>

[▶ Watch the 80-second intro](https://meetrec.dorara.app/#video)

</div>

## Features

**Knows who said what.** You and the other participants are recorded on separate channels, then every line of the transcript is labeled with its speaker. Rename a speaker once and every line follows.

<img src="site/assets/transcript.png" width="640" alt="Transcript with each line labeled by speaker">

**Click a person, see their timeline.** Each speaker's talk time opens a list of every turn they took; click one and playback jumps there.

<img src="site/assets/speaker-turns.png" width="640" alt="One speaker's turns listed from their talk time">

**Works with the AI you already use.** Press ⌘E to discuss the meeting with your local [Claude Code](https://code.claude.com/docs/en/setup) or [Codex](https://developers.openai.com/codex/cli), using your own login. No extra API key.

<img src="site/assets/ai-sidebar.png" width="640" alt="AI chat side panel next to the transcript">

**Import files and links.** Drop in audio or video, or paste a YouTube, podcast or Spotify episode link, and it's transcribed the same way.

Also: asks to record when a Google Meet, Teams or Slack huddle starts; transcribes on your Mac with whisper.cpp (Chinese and English), or in the cloud with your own Groq or OpenAI key; vocabulary hints; edit, search, and export to SRT or TXT.

## Install

Download the `.dmg` from [Releases](https://github.com/t42ji2ji/meetrec/releases/latest) and drag MeetRec into Applications. Requires macOS 15+ on Apple Silicon. The first on-device transcription downloads a speech model (about 570 MB by default).

## Privacy

Recording, transcription and speaker detection run on your Mac by default. MeetRec goes online only to download models, for cloud transcription if you turn it on, for AI chat through your own Claude Code or Codex, and when importing a link. Get consent before recording people.

## Build from source

Requires Xcode command line tools and cmake.

```sh
./vendor.sh   # builds whisper.cpp and sherpa-onnx
./build.sh    # builds the app and installs it to ~/Applications
```

Replace the signing identities in `build.sh` and `release.sh` with your own.

## License

GPL-3.0. Bundled components and models keep their own licenses; see `Resources/licenses`.
