# 背景音樂：120 BPM、40 秒，段落對齊畫面切換（4s 開場、4~38s 主段、38s 收尾重音）
import wave
import numpy as np

SR = 44100
BEAT = 0.5
TOTAL = 40.0
DROP = 4.0     # 開場只有墊音，這裡進鼓
END_HIT = 38.0 # 收尾和弦
out = np.zeros((int(SR * TOTAL), 2))

def t_(d): return np.arange(int(SR * d)) / SR

def add(sig, at, pan=0.0, gain=1.0):
    i = int(at * SR)
    sig = sig[: max(0, len(out) - i)]
    out[i:i + len(sig), 0] += sig * gain * (1 - pan) ** 0.5
    out[i:i + len(sig), 1] += sig * gain * (1 + pan) ** 0.5

def hz(n): return 440 * 2 ** ((n - 69) / 12)

def pluck(n, d=0.35):
    t = t_(d)
    f = hz(n)
    s = sum(np.sin(2 * np.pi * f * k * t) * np.exp(-t * (9 + 5 * k)) / k for k in range(1, 6))
    return s * np.minimum(1, t / 0.003)

def bass(n, d):
    t = t_(d)
    f = hz(n)
    s = np.sin(2 * np.pi * f * t) + 0.35 * np.sin(4 * np.pi * f * t)
    return s * np.exp(-t * 3) * np.minimum(1, t / 0.005) * np.minimum(1, (d - t) / 0.02)

def pad(notes, d):
    t = t_(d)
    s = sum(np.sin(2 * np.pi * hz(n) * k * t + k) / k ** 1.4 for n in notes for k in range(1, 5))
    env = np.minimum(1, t / 0.4) * np.minimum(1, (d - t) / 0.5)
    return s * env / len(notes)

def kick():
    t = t_(0.35)
    f = 50 + 110 * np.exp(-t * 30)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 9)

rng = np.random.default_rng(7)
def noise(d): return rng.uniform(-1, 1, int(SR * d))

def clap():
    t = t_(0.18)
    n = noise(0.18); n = n - np.roll(n, 1) * 0.6
    env = np.exp(-t * 28) + 0.6 * np.exp(-((t - 0.012) % 0.011) * 300) * (t < 0.035)
    return n * env

def hat():
    t = t_(0.05)
    n = noise(0.05); n = n - np.roll(n, 1)
    return n * np.exp(-t * 90)

# C – Am – F – G，每個和弦一小節（2 秒）
chords = [(48, [60, 64, 67, 72]), (45, [57, 60, 64, 69]), (41, [53, 57, 60, 65]), (43, [55, 59, 62, 67])]
arp = [0, 1, 2, 3, 2, 1, 2, 3]  # 八分音符琶音

bar = 0
while bar * 2 < END_HIT:
    t0 = bar * 2.0
    root, notes = chords[bar % 4]
    add(pad(notes, 2.0), t0, gain=0.10)
    if t0 >= DROP:
        for b in range(4):
            add(kick(), t0 + b * BEAT, gain=0.75)
            if b % 2 == 1: add(clap(), t0 + b * BEAT, gain=0.22)
            for h in range(2):
                add(hat(), t0 + b * BEAT + h * BEAT / 2 + BEAT / 4, pan=0.3, gain=0.10)
        for e in range(8):
            add(bass(root, BEAT / 2 * 0.9), t0 + e * BEAT / 2, gain=0.30 if e % 2 == 0 else 0.20)
        for e, a in enumerate(arp):
            add(pluck(notes[a] + 12), t0 + e * BEAT / 2, pan=-0.35 if e % 2 else 0.35, gain=0.13)
    else:
        # 開場：只有一聲聲問號似的高音
        for e in (0, 3, 6):
            add(pluck(notes[e % 4] + 12, 0.6), t0 + e * BEAT / 2, gain=0.08)
    bar += 1

# 收尾：重拍和弦，長尾音
add(kick(), END_HIT, gain=0.9)
add(clap(), END_HIT, gain=0.3)
add(bass(48, 1.8), END_HIT, gain=0.35)
for n in [60, 64, 67, 72, 76]:
    add(pluck(n, 1.8) * 1.5, END_HIT, gain=0.10)
add(pad([60, 64, 67, 72], 2.0), END_HIT, gain=0.12)

out /= np.max(np.abs(out)) / 0.89
with wave.open("public/music.wav", "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((out * 32767).astype("<i2").tobytes())
print("ok")
