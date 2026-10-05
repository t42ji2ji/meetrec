#!/bin/zsh
# 下載轉逐字稿需要的模型與程式到 ~/Library/Application Support/MeetRec（已存在的檔案會跳過）
# 另需 Homebrew：brew install ffmpeg whisper-cpp
set -e
D=~/Library/Application\ Support/MeetRec
mkdir -p $D && cd $D
get() { if [ ! -f "$1" ]; then curl -fL --retry 5 -C - -o "$1.part" "$2" && mv "$1.part" "$1"; fi; }
get ggml-large-v3-turbo-q5_0.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
get ggml-silero-v5.1.2.bin https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin
R=https://github.com/k2-fsa/sherpa-onnx/releases/download
get 3dspeaker-campplus-zh-en.onnx $R/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx
if [ ! -f pyannote-segmentation-3-0.onnx ]; then
  curl -fL --retry 5 $R/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2 | tar xj
  mv sherpa-onnx-pyannote-segmentation-3-0/model.onnx pyannote-segmentation-3-0.onnx && rm -rf sherpa-onnx-pyannote-segmentation-3-0
fi
if [ ! -x sherpa-onnx/bin/sherpa-onnx-offline-speaker-diarization ]; then
  V=v1.13.8; P=sherpa-onnx-$V-osx-arm64-shared-no-tts
  curl -fL --retry 5 $R/$V/$P.tar.bz2 | tar xj
  mkdir -p sherpa-onnx/bin && mv $P/bin/sherpa-onnx-offline-speaker-diarization sherpa-onnx/bin/ && mv $P/lib sherpa-onnx/ && rm -rf $P
fi
echo "ready: $D"
