// 功能短片：每支 12 秒、沒有旁白，只有輕音樂。共用 Promo.tsx 的樣式
import React from "react";
import { AbsoluteFill, Audio, Img, Sequence, interpolate, spring, staticFile, useCurrentFrame, Easing } from "remotion";
import { C, Card, Caption, FPS, fade, fontFamily, mono, sec, useSpring } from "./Promo";

export const CLIP = 12;

const Tag: React.FC<{ label: string; color: string; size?: number; scale?: number }> = ({ label, color, size = 22, scale = 1 }) => (
  <span
    style={{
      display: "inline-block", transform: `scale(${scale})`, transformOrigin: "left center",
      font: `600 ${size}px/1 ${fontFamily}`, color, background: `${color}24`,
      padding: `${size * 0.32}px ${size * 0.55}px ${size * 0.38}px`, borderRadius: 999, whiteSpace: "nowrap",
    }}
  >
    {label}
  </span>
);
const Unknown = () => (
  <span style={{ font: `600 22px/1 ${fontFamily}`, color: "#9b9ba1", background: C.sunk, padding: "7px 12px", borderRadius: 999 }}>???</span>
);
const Logo: React.FC<{ name: string; size?: number }> = ({ name, size = 30 }) => (
  <Img src={staticFile(`icons/${name}.svg`)} style={{ width: size, height: size }} />
);

// 每支片子的外框：背景、音樂、結尾淡出
const Clip: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const f = useCurrentFrame();
  const out = fade(f, CLIP - 0.6, CLIP - 0.1);
  return (
    <AbsoluteFill style={{ background: C.bg, fontFamily }}>
      <AbsoluteFill style={{ opacity: 1 - out }}>{children}</AbsoluteFill>
      <Audio src={staticFile("music-soft.wav")} volume={0.7} />
    </AbsoluteFill>
  );
};
const Scene: React.FC<{ from: number; to: number; children: React.ReactNode }> = ({ from, to, children }) => (
  <Sequence from={sec(from)} durationInFrames={sec(to - from)}>{children}</Sequence>
);

/* ================= 1. 匯入 ================= */
const sources: [string, string][] = [
  ["youtube", "YouTube"], ["bilibili", "Bilibili"], ["x", "X"], ["tiktok", "TikTok"], ["applepodcasts", "Podcasts"],
  ["spotify", "Spotify"], ["soundcloud", "SoundCloud"], ["facebook", "Facebook"], ["twitch", "Twitch"], ["dailymotion", "Dailymotion"],
];
const BILI = "bilibili.com/video/BV1GJ411x7h7";

const FileIcon: React.FC<{ ext: string; color: string }> = ({ ext, color }) => (
  <div style={{ position: "relative", width: 64, height: 78 }}>
    <svg viewBox="0 0 16 20" width="64" height="78"><path d="M1 1h9l5 5v13H1z" fill="#fff" stroke={C.line} strokeWidth="0.8" /><path d="M10 1v5h5" fill="none" stroke={C.line} strokeWidth="0.8" /></svg>
    <span style={{ position: "absolute", left: 6, bottom: 12, font: `700 15px/1 ${mono}`, color: "#fff", background: color, padding: "4px 6px", borderRadius: 5 }}>{ext}</span>
  </div>
);

const DropFile = () => {
  const f = useCurrentFrame();
  const enter = useSpring(0.05, { damping: 16, mass: 0.8 });
  // 檔案從右下飛進拖放區
  const fly = interpolate(f, [sec(0.7), sec(1.8)], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: Easing.inOut(Easing.cubic) });
  const over = f >= sec(1.5) && f < sec(2.0);
  const drop = spring({ frame: f - sec(2.0), fps: FPS, config: { damping: 12 } });
  const prog = interpolate(f, [sec(2.3), sec(3.6)], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const files: [string, string, string][] = [["interview.mp4", "MP4", C.Daniel], ["lecture.m4a", "M4A", C.Sarah]];
  return (
    <AbsoluteFill>
      <Caption at={0.2}>Drop in <span style={{ color: C.Me }}>a file.</span></Caption>
      <Card style={{ position: "absolute", left: 250, right: 250, top: 290, padding: "40px 46px", transform: `translateY(${(1 - enter) * 500}px)` }}>
        <div style={{ font: `700 38px/1 ${fontFamily}`, color: C.ink }}>Import</div>
        <div
          style={{
            marginTop: 30, height: 300, borderRadius: 20, border: `3px dashed ${over ? C.Me : "rgba(24,24,26,0.2)"}`,
            background: over ? `${C.Me}12` : "transparent", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 18,
          }}
        >
          {drop < 0.05 ? (
            <>
              <svg viewBox="0 0 24 24" width="56" height="56" fill="none" stroke={over ? C.Me : "#9b9ba1"} strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M12 15V4M7 9l5-5 5 5M4 15v4a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-4" /></svg>
              <span style={{ font: `500 26px/1 ${fontFamily}`, color: C.muted }}>Drop audio or video files</span>
            </>
          ) : (
            <div style={{ width: "86%", display: "flex", flexDirection: "column", gap: 22, opacity: drop }}>
              {files.map(([name, ext, color], i) => (
                <div key={name} style={{ display: "flex", alignItems: "center", gap: 20, transform: `translateY(${(1 - drop) * 30}px)` }}>
                  <div style={{ transform: "scale(0.7)", margin: "-12px -10px" }}><FileIcon ext={ext} color={color} /></div>
                  <div style={{ flex: 1 }}>
                    <div style={{ font: `600 26px/1 ${fontFamily}`, color: C.ink, marginBottom: 12 }}>{name}</div>
                    <div style={{ height: 10, borderRadius: 99, background: C.sunk }}>
                      <div style={{ height: "100%", width: `${Math.min(1, prog * (i ? 0.8 : 1.15)) * 100}%`, borderRadius: 99, background: C.Me }} />
                    </div>
                  </div>
                  <span style={{ font: `500 20px/1 ${mono}`, color: C.muted, width: 150, textAlign: "right" }}>{prog * (i ? 0.8 : 1.15) >= 1 ? "Done" : "Transcribing"}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      </Card>
      {/* 被拖著的檔案 */}
      {files.map(([name, ext, color], i) => (
        <div
          key={name}
          style={{
            position: "absolute", left: interpolate(fly, [0, 1], [1180 + i * 60, 620 + i * 90]), top: interpolate(fly, [0, 1], [900 + i * 40, 520 + i * 20]),
            transform: `rotate(${(1 - fly) * 12 - 4 + i * 8}deg) scale(${1 - drop * 0.6})`, opacity: f < sec(0.7) ? 0 : 1 - drop,
            filter: "drop-shadow(0 12px 20px rgba(0,0,0,0.18))",
          }}
        >
          <FileIcon ext={ext} color={color} />
        </div>
      ))}
    </AbsoluteFill>
  );
};

const PasteLink = () => {
  const f = useCurrentFrame();
  const enter = useSpring(0.05, { damping: 16, mass: 0.8 });
  const typed = Math.floor(interpolate(f, [sec(1.9), sec(3.0)], [0, BILI.length], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }));
  const lit = typed > 8;
  return (
    <AbsoluteFill>
      <Caption at={0.2}>Or paste <span style={{ color: "#ff0033" }}>a link.</span></Caption>
      <Card style={{ position: "absolute", left: 170, right: 170, top: 270, padding: "40px 46px", transform: `translateY(${(1 - enter) * 500}px)` }}>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(5, 1fr)", gap: 16 }}>
          {sources.map(([icon, name], i) => {
            const s = spring({ frame: f - sec(0.4 + i * 0.09), fps: FPS, config: { damping: 11, mass: 0.5 } });
            const on = icon === "bilibili" && lit;
            return (
              <div
                key={icon}
                style={{
                  display: "flex", flexDirection: "column", alignItems: "center", gap: 14, padding: "22px 0", borderRadius: 18,
                  background: on ? "#00A1D61c" : C.bg, outline: on ? "2px solid #00A1D6" : "none",
                  opacity: s * (lit && !on ? 0.45 : 1), transform: `scale(${0.6 + s * 0.4})`,
                }}
              >
                <Logo name={icon} size={46} />
                <span style={{ font: `500 21px/1 ${fontFamily}`, color: C.ink }}>{name}</span>
              </div>
            );
          })}
        </div>
        <div style={{ marginTop: 30, border: `2px solid ${typed ? C.Me : C.line}`, borderRadius: 14, padding: "20px 22px", display: "flex", alignItems: "center", gap: 14, font: `500 28px/1 ${fontFamily}`, color: C.ink, height: 74, boxSizing: "border-box" }}>
          {lit ? <Logo name="bilibili" size={30} /> : <span style={{ color: C.muted }}>🔗</span>}
          {typed ? `https://${BILI.slice(0, typed)}` : <span style={{ color: "#a9a9ae" }}>Paste a link</span>}
          <span style={{ width: 3, height: 32, background: C.Me, opacity: Math.floor(f / 10) % 2 ? 1 : 0 }} />
        </div>
      </Card>
    </AbsoluteFill>
  );
};

const lecture: { who: string; color: string; t: string }[] = [
  { who: "Host", color: C.Me, t: "今天我們來聊聊怎麼開一場好會議。" },
  { who: "Guest", color: C.Priya, t: "First rule: write down who decided what." },
  { who: "Host", color: C.Me, t: "所以逐字稿要有名字。" },
  { who: "Guest", color: C.Priya, t: "Exactly. Otherwise nobody remembers." },
];
const ImportResult = () => {
  const f = useCurrentFrame();
  const enter = useSpring(0.05, { damping: 15, mass: 0.7 });
  return (
    <AbsoluteFill>
      <Caption at={0.2}>Transcribed, <span style={{ color: C.Priya }}>speaker by speaker.</span></Caption>
      <Card style={{ position: "absolute", left: 170, right: 170, top: 270, opacity: enter, transform: `translateY(${(1 - enter) * 300}px)` }}>
        <div style={{ display: "flex", alignItems: "center", gap: 14, padding: "24px 32px", borderBottom: `1px solid ${C.line}` }}>
          <Logo name="bilibili" size={32} />
          <span style={{ font: `600 26px/1 ${fontFamily}`, color: C.ink }}>How to Run a Good Meeting</span>
        </div>
        <div style={{ padding: "16px 20px" }}>
          {lecture.map((l, i) => {
            const s = spring({ frame: f - sec(0.5 + i * 0.4), fps: FPS, config: { damping: 11, mass: 0.5 } });
            return (
              <div key={i} style={{ display: "grid", gridTemplateColumns: "140px 1fr", alignItems: "center", padding: "16px 12px", opacity: s, transform: `translateX(${(1 - s) * -40}px)` }}>
                <span><Tag label={l.who} color={l.color} /></span>
                <span style={{ font: `500 32px/1.3 ${fontFamily}`, color: C.ink }}>{l.t}</span>
              </div>
            );
          })}
        </div>
      </Card>
    </AbsoluteFill>
  );
};

export const FeatureImport = () => (
  <Clip>
    <Scene from={0} to={4}><DropFile /></Scene>
    <Scene from={4} to={8}><PasteLink /></Scene>
    <Scene from={8} to={CLIP}><ImportResult /></Scene>
  </Clip>
);

/* ================= 2. 分辨說話者 ================= */
// 一開始是自動取的名字，改一次名字，那個人的每一句都跟著換
const lines2: { id: number; t: string; at: string }[] = [
  { id: 0, t: "Let's lock the plan for the launch.", at: "00:00" },
  { id: 1, t: "The beta wrapped up Friday. About 300 testers.", at: "00:07" },
  { id: 2, t: "We can fix the export bug this week.", at: "00:24" },
  { id: 3, t: "How many users does that affect?", at: "00:42" },
  { id: 2, t: "Roughly 4%.", at: "00:45" },
];
const people = [
  { auto: "Me", name: "Me", color: C.Me, at: 0 },
  { auto: "Speaker 2", name: "Sarah", color: C.Sarah, at: 7.6 },
  { auto: "Speaker 3", name: "Daniel", color: C.Daniel, at: 6.6 },
  { auto: "Speaker 4", name: "Priya", color: C.Priya, at: 7.8 },
];
const turns2: [number, number, number][] = [
  [0, 0, 7], [1, 7, 18], [0, 18, 20], [1, 20, 24], [2, 24, 33], [0, 33, 35], [2, 35, 42], [3, 42, 45], [2, 45, 51], [3, 51, 56],
];
const NAME = "Daniel";

export const FeatureSpeakers = () => {
  const f = useCurrentFrame();
  const enter = useSpring(0.05, { damping: 16, mass: 0.8 });
  // 5.2 秒點 Speaker 3 → 打字 → 6.6 確定
  const editing = f >= sec(5.2) && f < sec(6.6);
  const edit = spring({ frame: f - sec(5.2), fps: FPS, config: { damping: 14 } });
  const typed = Math.floor(interpolate(f, [sec(5.6), sec(6.3)], [0, NAME.length], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }));
  const grow = interpolate(f, [sec(9.0), sec(10.2)], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: Easing.out(Easing.cubic) });
  const shares = ["35%", "21%", "19%", "25%"];
  return (
    <Clip>
      <Caption at={0.2} out={4.9}>Knows <span style={{ color: C.Me }}>who said what.</span></Caption>
      <Caption at={5.1} out={8.7}>Rename once, <span style={{ color: C.Daniel }}>every line follows.</span></Caption>
      <Caption at={8.9}>See who <span style={{ color: C.Sarah }}>talked most.</span></Caption>
      <Card style={{ position: "absolute", left: 150, right: 150, top: 250, transform: `translateY(${(1 - enter) * 500}px)` }}>
        <div style={{ display: "flex", alignItems: "center", gap: 14, padding: "24px 32px", borderBottom: `1px solid ${C.line}` }}>
          <span style={{ font: `600 26px/1 ${fontFamily}`, color: C.ink }}>Launch Planning Sync</span>
        </div>
        <div style={{ padding: "16px 20px" }}>
          {lines2.map((l, i) => {
            const p = people[l.id];
            const at = 1.0 + i * 0.45;
            const pop = spring({ frame: f - sec(at), fps: FPS, config: { damping: 10, mass: 0.5 } });
            const renamed = l.id > 0 && f >= sec(p.at);
            const flip = renamed ? spring({ frame: f - sec(p.at), fps: FPS, config: { damping: 9, mass: 0.4 } }) : 1;
            const target = i === 2 && editing;
            return (
              <div key={i} style={{ display: "grid", gridTemplateColumns: "80px 170px 1fr", alignItems: "center", padding: "14px 12px", borderRadius: 14, background: renamed && flip < 0.98 ? `${p.color}18` : "transparent", position: "relative" }}>
                <span style={{ font: `400 20px/1 ${mono}`, color: C.muted }}>{l.at}</span>
                <span>
                  {f < sec(at) ? <Unknown /> : target ? (
                    <span style={{ display: "inline-flex", alignItems: "center", font: `600 22px/1 ${fontFamily}`, color: C.ink, background: "#fff", outline: `2px solid ${C.Me}`, padding: "7px 12px", borderRadius: 10, minWidth: 100, transform: `scale(${0.8 + edit * 0.2})` }}>
                      {typed ? NAME.slice(0, typed) : <span style={{ color: "#a9a9ae" }}>Speaker 3</span>}
                      <span style={{ width: 2, height: 24, marginLeft: 2, background: C.Me, opacity: Math.floor(f / 10) % 2 ? 1 : 0 }} />
                    </span>
                  ) : (
                    <Tag label={renamed ? p.name : p.auto} color={p.color} scale={pop * (renamed ? 0.85 + flip * 0.15 : 1)} />
                  )}
                </span>
                <span style={{ font: `500 30px/1.3 ${fontFamily}`, color: f < sec(at) ? "#a9a9ae" : C.ink }}>{l.t}</span>
              </div>
            );
          })}
        </div>
        <div style={{ padding: "6px 32px 30px", opacity: fade(f, 8.9, 9.2) }}>
          <div style={{ position: "relative", height: 22, borderRadius: 99, background: C.sunk }}>
            {turns2.map(([who, a, b], i) => (
              <i key={i} style={{ position: "absolute", top: 0, bottom: 0, left: `${(a / 56) * 100}%`, width: `calc(${((b - a) / 56) * 100 * grow}% - 3px)`, background: people[who].color, borderRadius: 6 }} />
            ))}
          </div>
          <div style={{ display: "flex", gap: 30, marginTop: 22 }}>
            {people.map((p, i) => {
              const s = spring({ frame: f - sec(9.5 + i * 0.12), fps: FPS, config: { damping: 12 } });
              return (
                <span key={p.name} style={{ display: "flex", alignItems: "center", gap: 10, opacity: s, transform: `translateY(${(1 - s) * 20}px)` }}>
                  <Tag label={p.name} color={p.color} size={20} />
                  <span style={{ font: `500 22px/1 ${mono}`, color: C.muted }}>{shares[i]}</span>
                </span>
              );
            })}
          </div>
        </div>
      </Card>
    </Clip>
  );
};

/* ================= 3. 會議和麥克風同時錄 ================= */
const MicIcon: React.FC<{ size?: number; color?: string }> = ({ size = 40, color = C.Me }) => (
  <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke={color} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
    <rect x="9" y="3" width="6" height="11" rx="3" /><path d="M5 11a7 7 0 0 0 14 0M12 18v3" />
  </svg>
);
const SpeakerIcon: React.FC<{ size?: number; color?: string }> = ({ size = 40, color = C.ink }) => (
  <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke={color} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
    <path d="M4 9v6h4l5 4V5L8 9zM16.5 8.5a5 5 0 0 1 0 7M19 6a8.5 8.5 0 0 1 0 12" />
  </svg>
);

// 確定性的假波形：誰在講話那一段就有振幅
const BARS = 96;
const amp = (i: number, seed: number) => 0.35 + 0.65 * Math.abs(Math.sin(i * 1.7 + seed) * Math.cos(i * 0.43 + seed * 2));
// 每一格是誰在講：0 = 我；1..3 = 對方（Sarah、Daniel、Priya）；-1 = 沒人
const whoAt = (i: number) => {
  const t = (i / BARS) * 56;
  return turns2.find(([, a, b]) => t >= a && t < b)?.[0] ?? -1;
};
const Wave: React.FC<{ mine: boolean; progress: number; height?: number }> = ({ mine, progress, height = 110 }) => (
  <div style={{ display: "flex", alignItems: "center", gap: 3, height }}>
    {Array.from({ length: BARS }, (_, i) => {
      const w = whoAt(i);
      const active = mine ? w === 0 : w > 0;
      const on = i / BARS < progress;
      const h = active ? amp(i, mine ? 1 : 4) : 0.05;
      return <i key={i} style={{ flex: 1, height: `${Math.max(4, h * 100)}%`, borderRadius: 3, background: on ? (active ? people[w].color : "#c9c9c4") : C.sunk }} />;
    })}
  </div>
);

const Sources = () => {
  const f = useCurrentFrame();
  const a = useSpring(0.3, { damping: 14, mass: 0.6 });
  const b = useSpring(0.55, { damping: 14, mass: 0.6 });
  const plus = useSpring(0.9, { damping: 10, mass: 0.6 });
  const pulse = (seed: number) => 1 + 0.08 * Math.abs(Math.sin(f / 4 + seed));
  const box: React.CSSProperties = { width: 440, height: 360, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 26 };
  return (
    <AbsoluteFill>
      <Caption at={0.2}>The meeting <span style={{ color: C.muted }}>and</span> <span style={{ color: C.Me }}>your mic.</span></Caption>
      <AbsoluteFill style={{ flexDirection: "row", alignItems: "center", justifyContent: "center", gap: 56, paddingTop: 120 }}>
        <Card style={{ ...box, opacity: a, transform: `translateY(${(1 - a) * 200}px)` }}>
          <div style={{ display: "flex", gap: 22 }}>
            {["googlemeet", "microsoftteams", "slack"].map((n) => <Logo key={n} name={n} size={58} />)}
          </div>
          <div style={{ display: "flex", gap: 10 }}>
            {[C.Sarah, C.Daniel, C.Priya].map((c, i) => (
              <span key={i} style={{ width: 54, height: 54, borderRadius: 27, background: `${c}30`, outline: `3px solid ${c}`, transform: `scale(${i === Math.floor(f / 24) % 3 ? pulse(i) : 1})` }} />
            ))}
          </div>
          <div style={{ font: `600 30px/1 ${fontFamily}`, color: C.ink }}>Everyone else</div>
        </Card>
        <div style={{ font: `300 90px/1 ${fontFamily}`, color: C.muted, opacity: plus, transform: `scale(${plus})` }}>+</div>
        <Card style={{ ...box, opacity: b, transform: `translateY(${(1 - b) * 200}px)` }}>
          <div style={{ width: 120, height: 120, borderRadius: 60, background: `${C.Me}18`, display: "flex", alignItems: "center", justifyContent: "center", transform: `scale(${pulse(9)})` }}>
            <MicIcon size={66} />
          </div>
          <div style={{ font: `600 30px/1 ${fontFamily}`, color: C.ink }}>Your microphone</div>
        </Card>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

const Tracks = () => {
  const f = useCurrentFrame();
  const enter = useSpring(0.05, { damping: 16, mass: 0.8 });
  const prog = interpolate(f, [sec(0.4), sec(3.8)], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const secs = Math.floor(prog * 56);
  const row = (label: string, side: string, icon: React.ReactNode, mine: boolean) => (
    <div style={{ padding: "24px 32px" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 14, marginBottom: 16 }}>
        {icon}
        <span style={{ font: `600 26px/1 ${fontFamily}`, color: C.ink }}>{label}</span>
        <span style={{ font: `500 18px/1 ${mono}`, color: C.muted, marginLeft: "auto", letterSpacing: "0.06em" }}>{side}</span>
      </div>
      <Wave mine={mine} progress={prog} />
    </div>
  );
  return (
    <AbsoluteFill>
      <Caption at={0.2}>Recorded on <span style={{ color: C.Me }}>separate tracks.</span></Caption>
      <Card style={{ position: "absolute", left: 120, right: 120, top: 260, transform: `translateY(${(1 - enter) * 500}px)` }}>
        <div style={{ display: "flex", alignItems: "center", gap: 14, padding: "22px 32px", borderBottom: `1px solid ${C.line}` }}>
          <span style={{ width: 14, height: 14, borderRadius: 7, background: "#f2463a", opacity: Math.floor(f / 15) % 2 ? 1 : 0.35 }} />
          <span style={{ font: `500 18px/1 ${mono}`, color: "#f2463a", letterSpacing: "0.08em" }}>REC</span>
          <span style={{ font: `600 26px/1 ${fontFamily}`, color: C.ink }}>Launch Planning Sync</span>
          <span style={{ font: `500 22px/1 ${mono}`, color: C.muted, marginLeft: "auto" }}>00:{String(secs).padStart(2, "0")}</span>
        </div>
        {row("Your microphone", "LEFT", <MicIcon size={30} />, true)}
        <div style={{ height: 1, background: C.line, margin: "0 32px" }} />
        {row("Meeting audio", "RIGHT", <SpeakerIcon size={30} />, false)}
      </Card>
    </AbsoluteFill>
  );
};

const DualResult = () => {
  const f = useCurrentFrame();
  const enter = useSpring(0.05, { damping: 15, mass: 0.7 });
  return (
    <AbsoluteFill>
      <Caption at={0.2}>Your voice never <span style={{ color: C.Me }}>gets lost.</span></Caption>
      <Card style={{ position: "absolute", left: 150, right: 150, top: 260, opacity: enter, transform: `translateY(${(1 - enter) * 300}px)` }}>
        <div style={{ padding: "16px 20px" }}>
          {lines2.map((l, i) => {
            const p = people[l.id];
            const s = spring({ frame: f - sec(0.4 + i * 0.35), fps: FPS, config: { damping: 11, mass: 0.5 } });
            return (
              <div key={i} style={{ display: "grid", gridTemplateColumns: "56px 130px 1fr", alignItems: "center", padding: "15px 12px", opacity: s, transform: `translateX(${(1 - s) * (l.id ? 40 : -40)}px)` }}>
                {l.id ? <SpeakerIcon size={28} color={C.muted} /> : <MicIcon size={28} />}
                <span><Tag label={p.name} color={p.color} /></span>
                <span style={{ font: `500 30px/1.3 ${fontFamily}`, color: C.ink }}>{l.t}</span>
              </div>
            );
          })}
        </div>
      </Card>
    </AbsoluteFill>
  );
};

export const FeatureDual = () => (
  <Clip>
    <Scene from={0} to={3.6}><Sources /></Scene>
    <Scene from={3.6} to={8}><Tracks /></Scene>
    <Scene from={8} to={CLIP}><DualResult /></Scene>
  </Clip>
);
