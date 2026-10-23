# 功能短片的背景音樂：乾淨、輕，沒有鼓。12 秒，100 BPM，最後一秒淡出
import wave
import numpy as np

SR = 44100
BEAT = 0.6
TOTAL = 12.0
out = np.zeros((int(SR * TOTAL), 2))

def t_(d): return np.arange(int(SR * d)) / SR

def add(sig, at, pan=0.0, gain=1.0):
    i = int(at * SR)
    sig = sig[: max(0, len(out) - i)]
    out[i:i + len(sig), 0] += sig * gain * (1 - pan) ** 0.5
    out[i:i + len(sig), 1] += sig * gain * (1 + pan) ** 0.5

def hz(n): return 440 * 2 ** ((n - 69) / 12)

def bell(n, d=1.2):
    t = t_(d)
    f = hz(n)
    s = np.sin(2 * np.pi * f * t) + 0.25 * np.sin(2 * np.pi * f * 2 * t) * np.exp(-t * 6)
    return s * np.exp(-t * 3.2) * np.minimum(1, t / 0.004)

def pad(notes, d):
    t = t_(d)
    s = sum(np.sin(2 * np.pi * hz(n) * k * t + k) / k ** 1.8 for n in notes for k in range(1, 4))
    env = np.minimum(1, t / 0.8) * np.minimum(1, (d - t) / 0.8)
    return s * env / len(notes)

def bass(n, d):
    t = t_(d)
    s = np.sin(2 * np.pi * hz(n) * t)
    return s * np.minimum(1, t / 0.02) * np.exp(-t * 1.2)

# Fmaj7 – Am7 – Dm7 – Cmaj9，每個和弦兩拍×2（2.4 秒）
chords = [(41, [57, 60, 64, 65]), (45, [55, 60, 64, 67]), (38, [57, 60, 62, 65]), (36, [55, 59, 62, 64])]
melody = [0, 2, 3, 1]  # 每拍一個音，從和弦裡挑

bar = 0
while bar * 2.4 < TOTAL:
    t0 = bar * 2.4
    root, notes = chords[bar % 4]
    add(pad(notes, 2.6), t0, gain=0.16)
    add(bass(root, 2.4), t0, gain=0.22)
    for b, m in enumerate(melody):
        if bar == 0 and b < 2: continue
        add(bell(notes[m] + 12), t0 + b * BEAT, pan=-0.25 if b % 2 else 0.25, gain=0.11)
    bar += 1

# 最後一秒淡出
fade = np.ones(len(out))
n = int(SR * 1.2)
fade[-n:] = np.linspace(1, 0, n) ** 2
out *= fade[:, None]

out /= np.max(np.abs(out)) / 0.8
with wave.open("public/music-soft.wav", "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((out * 32767).astype("<i2").tobytes())
print("ok")
