#!/bin/zsh
# 下載並編譯打包進 app 的輔助程式到 vendor/：
#   whisper-cli（whisper.cpp，靜態連結、Metal 內嵌）、whisper-vad（同一包的 VAD，雲端轉錄前剪掉沒人講話的地方）、
#   sherpa-onnx 的說話者辨識＋ libonnxruntime.dylib
# 需要 cmake 和 Xcode command line tools。已經有的就跳過
set -e
cd "${0:A:h}"
mkdir -p vendor/src vendor/bin
WV=1.8.6
if [ ! -x vendor/bin/whisper-cli ]; then
  [ -d vendor/src/whisper.cpp-$WV ] || curl -fL --retry 5 https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v$WV.tar.gz | tar xz -C vendor/src
  cmake -S vendor/src/whisper.cpp-$WV -B vendor/src/whisper-build -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple -DGGML_NATIVE=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_SDL2=OFF >/dev/null
  cmake --build vendor/src/whisper-build --target whisper-cli -j 8 >/dev/null
  cp vendor/src/whisper-build/bin/whisper-cli vendor/bin/
fi
if [ ! -x vendor/bin/whisper-vad ]; then
  cmake --build vendor/src/whisper-build --target whisper-vad-speech-segments -j 8 >/dev/null
  cp vendor/src/whisper-build/bin/whisper-vad-speech-segments vendor/bin/whisper-vad
fi
SV=v1.13.8; SP=sherpa-onnx-$SV-osx-arm64-shared-no-tts
if [ ! -x vendor/bin/sherpa-diarize ]; then
  [ -d vendor/src/$SP ] || curl -fL --retry 5 https://github.com/k2-fsa/sherpa-onnx/releases/download/$SV/$SP.tar.bz2 | tar xj -C vendor/src
  cp vendor/src/$SP/bin/sherpa-onnx-offline-speaker-diarization vendor/bin/sherpa-diarize
  cp vendor/src/$SP/lib/libonnxruntime.dylib vendor/bin/
  # app 裡 dylib 放 Contents/Frameworks
  install_name_tool -add_rpath @executable_path/../Frameworks vendor/bin/sherpa-diarize 2>/dev/null
fi
ls -la vendor/bin
