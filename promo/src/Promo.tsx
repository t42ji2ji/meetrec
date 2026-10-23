import React from "react";
import {
  AbsoluteFill, Audio, Img, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig, Easing,
} from "remotion";
import { loadFont } from "@remotion/google-fonts/SchibstedGrotesk";
import { loadFont as loadMono } from "@remotion/google-fonts/IBMPlexMono";
import lines from "./lines.json";

export const FPS = 30;
export const TOTAL = 40;

export const { fontFamily } = loadFont("normal", { weights: ["400", "500", "600", "700", "800"], subsets: ["latin"] });
export const { fontFamily: mono } = loadMono("normal", { weights: ["400", "500"], subsets: ["latin"] });

// 場景切換點（秒），對齊音樂小節
const S = { hook: 0, label: 4, link: 14, ai: 24, end: 34 };

// 旁白：lines.json 的 at 是開始秒數，duration 由 scripts/voice.mjs 寫入
const VO = Object.fromEntries(lines.map((l) => [l.id, l.at]));

export const C = {
  bg: "#f3f3f0", ink: "#18181a", muted: "#66666c", line: "rgba(24,24,26,0.1)", sunk: "#ebebe7",
  Me: "#2f7cf6", Sarah: "#e8812f", Daniel: "#2f9d55", Priya: "#b84ccf", Host: "#2f7cf6", Guest: "#b84ccf",
};
type Who = "Me" | "Sarah" | "Daniel" | "Priya" | "Host" | "Guest";

export const sec = (s: number) => Math.round(s * FPS);

export const useSpring = (at: number, cfg = { damping: 14, mass: 0.6 }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  return spring({ frame: f - sec(at), fps, config: cfg });
};

export const fade = (f: number, a: number, b: number) =>
  interpolate(f, [sec(a), sec(b)], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });

const Chip: React.FC<{ who: Who; scale?: number; size?: number }> = ({ who, scale = 1, size = 22 }) => (
  <span
    style={{
      display: "inline-block", transform: `scale(${scale})`, transformOrigin: "left center",
      font: `600 ${size}px/1 ${fontFamily}`, color: C[who], background: `${C[who]}24`,
      padding: `${size * 0.32}px ${size * 0.55}px ${size * 0.38}px`, borderRadius: 999, whiteSpace: "nowrap",
    }}
  >
    {who}
  </span>
);

export const Card: React.FC<{ style?: React.CSSProperties; children: React.ReactNode }> = ({ style, children }) => (
  <div
    style={{
      background: "#fff", borderRadius: 26, overflow: "hidden",
      boxShadow: "0 2px 4px rgba(20,20,24,0.06), 0 16px 40px -12px rgba(20,20,24,0.18), 0 60px 120px -40px rgba(20,20,24,0.28)",
      outline: `1px solid ${C.line}`, ...style,
    }}
  >
    {children}
  </div>
);

export const Caption: React.FC<{ at: number; out?: number; children: React.ReactNode; top?: number }> = ({ at, out, children, top = 90 }) => {
  const f = useCurrentFrame();
  const s = useSpring(at);
  const gone = out ? fade(f, out, out + 0.25) : 0;
  return (
    <div
      style={{
        position: "absolute", top, left: 0, right: 0, textAlign: "center",
        font: `800 76px/1.05 ${fontFamily}`, letterSpacing: "-0.04em", color: C.ink,
        opacity: s * (1 - gone), transform: `translateY(${(1 - s) * 40 - gone * 30}px)`,
      }}
    >
      {children}
    </div>
  );
};

/* ---------- 1. Hook：一堆沒名字的字幕 ---------- */
const hookLines = [
  "Let's lock the plan for launch.", "The beta wrapped up Friday.", "We can fix that this week.",
  "How many users does that affect?", "Roughly 4%.", "Wait, who's taking screenshots?", "I thought you were.",
];
const Hook = () => {
  const f = useCurrentFrame();
  const q = useSpring(0.9, { damping: 9, mass: 0.7 });
  const wobble = Math.sin(f / 3) * interpolate(f, [sec(1), sec(2.4)], [10, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const leave = fade(f, 3.7, 4);
  return (
    <AbsoluteFill style={{ background: C.bg }}>
      {hookLines.map((t, i) => {
        const x = [90, 760, 180, 820, 120, 700, 300][i];
        const y = 110 + i * 128;
        const drift = Math.sin((f + i * 20) / 18) * 14;
        const a = fade(f, i * 0.12, i * 0.12 + 0.3);
        return (
          <div
            key={i}
            style={{
              position: "absolute", left: x + drift, top: y, opacity: a * 0.55 * (1 - leave),
              font: `500 40px/1 ${fontFamily}`, color: C.muted, filter: `blur(${1 + q * 2.5}px)`,
              display: "flex", alignItems: "center", gap: 18,
            }}
          >
            <span style={{ font: `600 22px/1 ${fontFamily}`, color: "#9b9ba1", background: C.sunk, padding: "8px 14px", borderRadius: 999 }}>???</span>
            {t}
          </div>
        );
      })}
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <div
          style={{
            font: `800 150px/1 ${fontFamily}`, letterSpacing: "-0.05em", color: C.ink,
            transform: `scale(${q * (1 + leave * 0.2)}) rotate(${wobble * 0.3}deg)`, opacity: 1 - leave,
          }}
        >
          Who said <span style={{ color: C.Sarah }}>that</span>?
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

/* ---------- 2. 每一句都有名字，接著是發言時間條 ---------- */
const meeting: { who: Who; t: string; at: string }[] = [
  { who: "Me", t: "Let's lock the plan for the launch.", at: "00:00" },
  { who: "Sarah", t: "The beta wrapped up Friday. About 300 testers.", at: "00:07" },
  { who: "Daniel", t: "We can fix the export bug this week.", at: "00:24" },
  { who: "Priya", t: "How many users does that affect?", at: "00:42" },
  { who: "Daniel", t: "Roughly 4%.", at: "00:45" },
];
// 發言時間條（跟官網 hero 一樣的輪替）
const turns: [Who, number, number][] = [
  ["Me", 0, 7], ["Sarah", 7, 18], ["Me", 18, 20], ["Sarah", 20, 24], ["Daniel", 24, 33], ["Me", 33, 35],
  ["Daniel", 35, 42], ["Priya", 42, 45], ["Daniel", 45, 51], ["Priya", 51, 56],
];
const POP0 = 5.3, POP_GAP = 0.5;
const Label = () => {
  const f = useCurrentFrame();
  const enter = useSpring(0.05, { damping: 16, mass: 0.8 });
  const barIn = fade(f, 6.3, 6.6); // 相對於場景開始
  const grow = interpolate(f, [sec(6.3), sec(7.6)], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: Easing.out(Easing.cubic) });
  const head = interpolate(f, [sec(7.6), sec(10)], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const shares: [Who, string][] = [["Me", "35%"], ["Sarah", "21%"], ["Daniel", "19%"], ["Priya", "25%"]];
  return (
    <AbsoluteFill style={{ background: C.bg }}>
      <Caption at={0.2} out={6.0}>Every line, <span style={{ color: C.Me }}>named.</span></Caption>
      <Caption at={6.3}>Who talked, <span style={{ color: C.Daniel }}>how long.</span></Caption>
      <Card style={{ position: "absolute", left: 150, right: 150, top: 250, transform: `translateY(${(1 - enter) * 500}px)` }}>
        <div style={{ display: "flex", alignItems: "center", gap: 14, padding: "24px 32px", borderBottom: `1px solid ${C.line}` }}>
          <span style={{ width: 14, height: 14, borderRadius: 7, background: "#f2463a" }} />
          <span style={{ font: `500 18px/1 ${mono}`, color: "#f2463a", letterSpacing: "0.08em" }}>REC</span>
          <span style={{ font: `600 26px/1 ${fontFamily}`, color: C.ink }}>Launch Planning Sync</span>
        </div>
        <div style={{ padding: "16px 20px" }}>
          {meeting.map((l, i) => {
            const at = POP0 - S.label + i * POP_GAP;
            const pop = spring({ frame: f - sec(at), fps: FPS, config: { damping: 10, mass: 0.5 } });
            const named = f >= sec(at);
            return (
              <div key={i} style={{ display: "grid", gridTemplateColumns: "80px 130px 1fr", alignItems: "center", padding: "14px 12px", borderRadius: 14, background: named && pop < 0.98 ? `${C[l.who]}14` : "transparent" }}>
                <span style={{ font: `400 20px/1 ${mono}`, color: C.muted }}>{l.at}</span>
                <span>{named ? <Chip who={l.who} scale={pop} /> : <span style={{ font: `600 22px/1 ${fontFamily}`, color: "#9b9ba1", background: C.sunk, padding: "7px 12px", borderRadius: 999 }}>???</span>}</span>
                <span style={{ font: `500 30px/1.3 ${fontFamily}`, color: named ? C.ink : "#a9a9ae" }}>{l.t}</span>
              </div>
            );
          })}
        </div>
        <div style={{ padding: "6px 32px 30px", opacity: barIn }}>
          <div style={{ position: "relative", height: 22, borderRadius: 99, background: C.sunk, overflow: "visible" }}>
            {turns.map(([who, a, b], i) => (
              <i key={i} style={{ position: "absolute", top: 0, bottom: 0, left: `${(a / 56) * 100}%`, width: `calc(${((b - a) / 56) * 100 * grow}% - 3px)`, background: C[who], borderRadius: 6 }} />
            ))}
            <span style={{ position: "absolute", top: -8, bottom: -8, width: 4, borderRadius: 2, background: C.ink, left: `${head * 100}%`, opacity: grow }} />
          </div>
          <div style={{ display: "flex", gap: 30, marginTop: 22 }}>
            {shares.map(([who, p], i) => {
              const s = spring({ frame: f - sec(6.9 + i * 0.12), fps: FPS, config: { damping: 12 } });
              return (
                <span key={who} style={{ display: "flex", alignItems: "center", gap: 10, opacity: s, transform: `translateY(${(1 - s) * 20}px)` }}>
                  <Chip who={who} size={20} />
                  <span style={{ font: `500 22px/1 ${mono}`, color: C.muted }}>{p}</span>
                </span>
              );
            })}
          </div>
        </div>
      </Card>
    </AbsoluteFill>
  );
};

/* ---------- 3. 貼網址 ---------- */
const URL = "youtube.com/watch?v=founder-story";
const pod: { who: Who; t: string }[] = [
  { who: "Host", t: "Welcome back to the show." },
  { who: "Guest", t: "Thanks for having me!" },
  { who: "Host", t: "So how did it all start?" },
  { who: "Guest", t: "Honestly? With a really messy meeting." },
];
const Link = () => {
  const f = useCurrentFrame();
  const enter = useSpring(0.05, { damping: 16, mass: 0.8 });
  const typed = Math.floor(interpolate(f, [sec(0.6), sec(2.3)], [0, URL.length], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }));
  const press = f >= sec(2.9) && f < sec(3.15);
  const sheetOut = fade(f, 3.2, 3.5);
  const prog = interpolate(f, [sec(3.5), sec(5.3)], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: Easing.inOut(Easing.quad) });
  const progVis = fade(f, 3.4, 3.6) * (1 - fade(f, 5.3, 5.5));
  const resIn = useSpring(5.4, { damping: 15, mass: 0.7 });
  return (
    <AbsoluteFill style={{ background: C.bg }}>
      <Caption at={0.2} out={5.2}>Paste a <span style={{ color: "#ff0033" }}>link.</span></Caption>
      <Caption at={5.5}>Same <span style={{ color: C.Guest }}>speakers.</span></Caption>
      {/* Import sheet */}
      <Card style={{ position: "absolute", left: 250, right: 250, top: 300, padding: "40px 46px", opacity: 1 - sheetOut, transform: `translateY(${(1 - enter) * 500}px) scale(${1 - sheetOut * 0.1})` }}>
        <div style={{ font: `700 38px/1 ${fontFamily}`, color: C.ink }}>Import</div>
        <div style={{ font: `400 22px/1.4 ${fontFamily}`, color: C.muted, marginTop: 10 }}>Everything you import is transcribed automatically</div>
        <div style={{ marginTop: 34, border: `2px solid ${typed ? C.Me : C.line}`, borderRadius: 14, padding: "20px 22px", display: "flex", alignItems: "center", gap: 14, font: `500 28px/1 ${fontFamily}`, color: C.ink, height: 74, boxSizing: "border-box" }}>
          <span style={{ color: C.muted }}>🔗</span>
          {typed ? `https://${URL.slice(0, typed)}` : <span style={{ color: "#a9a9ae" }}>Paste a link</span>}
          <span style={{ width: 3, height: 32, background: C.Me, opacity: Math.floor(f / 10) % 2 ? 1 : 0 }} />
        </div>
        <div style={{ display: "flex", gap: 34, marginTop: 24, alignItems: "center" }}>
          {[["youtube.svg", "YouTube"], ["applepodcasts.svg", "Apple Podcasts"], ["spotify.svg", "Spotify"]].map(([src, name], i) => (
            <span key={name} style={{ display: "flex", alignItems: "center", gap: 10, font: `500 24px/1 ${fontFamily}`, color: C.ink, opacity: i === 0 && typed > 6 ? 1 : 0.4 }}>
              <Img src={staticFile(src)} style={{ width: 30, height: 30 }} />
              {name}
            </span>
          ))}
        </div>
        <div style={{ display: "flex", justifyContent: "flex-end", marginTop: 36 }}>
          <span style={{ font: `600 26px/1 ${fontFamily}`, color: "#fff", background: C.ink, padding: "18px 28px", borderRadius: 14, transform: `scale(${press ? 0.92 : 1})` }}>Download &amp; Import</span>
        </div>
      </Card>
      {/* 下載中 */}
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: progVis }}>
        <div style={{ width: 640 }}>
          <div style={{ font: `600 30px/1 ${fontFamily}`, color: C.ink, marginBottom: 20, display: "flex", alignItems: "center", gap: 14 }}>
            <Img src={staticFile("youtube.svg")} style={{ width: 36, height: 36 }} />
            {prog < 0.5 ? "Downloading…" : "Transcribing…"}
          </div>
          <div style={{ height: 14, borderRadius: 99, background: C.sunk }}>
            <div style={{ height: "100%", width: `${prog * 100}%`, borderRadius: 99, background: C.Me }} />
          </div>
        </div>
      </AbsoluteFill>
      {/* 結果 */}
      <Card style={{ position: "absolute", left: 190, right: 190, top: 270, opacity: resIn, transform: `translateY(${(1 - resIn) * 300}px)` }}>
        <div style={{ display: "flex", alignItems: "center", gap: 14, padding: "24px 32px", borderBottom: `1px solid ${C.line}` }}>
          <Img src={staticFile("youtube.svg")} style={{ width: 32, height: 32 }} />
          <span style={{ font: `600 26px/1 ${fontFamily}`, color: C.ink }}>The Founder Story, Ep. 12</span>
        </div>
        <div style={{ padding: "16px 20px" }}>
          {pod.map((l, i) => {
            const s = spring({ frame: f - sec(5.8 + i * 0.45), fps: FPS, config: { damping: 11, mass: 0.5 } });
            return (
              <div key={i} style={{ display: "grid", gridTemplateColumns: "130px 1fr", alignItems: "center", padding: "16px 12px", opacity: s, transform: `translateX(${(1 - s) * -40}px)` }}>
                <span><Chip who={l.who} /></span>
                <span style={{ font: `500 32px/1.3 ${fontFamily}`, color: C.ink }}>{l.t}</span>
              </div>
            );
          })}
        </div>
      </Card>
    </AbsoluteFill>
  );
};

/* ---------- 4. ⌘E 問 AI ---------- */
const Key: React.FC<{ label: string; down: boolean }> = ({ label, down }) => (
  <div
    style={{
      width: 190, height: 190, borderRadius: 36, background: "#fff", display: "flex", alignItems: "center", justifyContent: "center",
      font: `600 96px/1 ${fontFamily}`, color: C.ink,
      boxShadow: down ? `0 2px 0 ${C.sunk}, 0 4px 10px rgba(0,0,0,0.1)` : `0 14px 0 #d6d6d0, 0 22px 40px rgba(0,0,0,0.18)`,
      transform: `translateY(${down ? 12 : 0}px)`, outline: `1px solid ${C.line}`,
    }}
  >
    {label}
  </div>
);
const answer: { who: Who; t: string }[] = [
  { who: "Daniel", t: "Move the import button into the toolbar by Wednesday." },
  { who: "Sarah", t: "Take the final screenshots on Thursday." },
  { who: "Priya", t: "Schedule the thank-you email for launch morning." },
];
const Ai = () => {
  const f = useCurrentFrame();
  const keysIn = useSpring(0.05, { damping: 12 });
  const down = f >= sec(0.7) && f < sec(1.0);
  const keysOut = fade(f, 1.2, 1.45);
  const panel = useSpring(1.35, { damping: 17, mass: 0.8 });
  const ask = useSpring(1.9, { damping: 13 });
  // 回答逐字打出
  const total = answer.reduce((n, a) => n + a.t.length, 0);
  const shown = Math.floor(interpolate(f, [sec(2.8), sec(6.6)], [0, total], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }));
  let left = shown;
  return (
    <AbsoluteFill style={{ background: C.bg }}>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", flexDirection: "row", gap: 40, opacity: keysIn * (1 - keysOut), transform: `scale(${0.6 + keysIn * 0.4 + keysOut * 0.3})` }}>
        <Key label="⌘" down={down} />
        <Key label="E" down={down} />
      </AbsoluteFill>
      <Caption at={1.4}>Ask the <span style={{ color: "#d97757" }}>AI</span> you already use.</Caption>
      <Card style={{ position: "absolute", left: 120, right: 120, top: 240, display: "grid", gridTemplateColumns: "0.85fr 1.15fr", opacity: panel, transform: `translateY(${(1 - panel) * 400}px)` }}>
        <div style={{ padding: "26px 28px", borderRight: `1px solid ${C.line}`, opacity: 0.45 }}>
          <div style={{ font: `600 24px/1 ${fontFamily}`, color: C.ink, marginBottom: 18 }}>Launch Planning Sync</div>
          {meeting.map((l, i) => (
            <div key={i} style={{ display: "flex", gap: 12, alignItems: "baseline", padding: "10px 0" }}>
              <Chip who={l.who} size={16} />
              <span style={{ font: `400 20px/1.35 ${fontFamily}`, color: C.ink }}>{l.t}</span>
            </div>
          ))}
        </div>
        <div style={{ padding: "26px 30px", display: "flex", flexDirection: "column", gap: 22 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 12, font: `600 24px/1 ${fontFamily}`, color: C.ink }}>
            <Img src={staticFile("claude.svg")} style={{ width: 30, height: 30 }} /> Claude Code
          </div>
          <div style={{ alignSelf: "flex-end", background: C.Me, color: "#fff", font: `500 25px/1.3 ${fontFamily}`, padding: "16px 22px", borderRadius: 22, opacity: ask, transform: `scale(${0.8 + ask * 0.2})`, transformOrigin: "right center" }}>
            List action items by owner.
          </div>
          <div style={{ background: C.sunk, borderRadius: 22, padding: "20px 24px", display: "flex", flexDirection: "column", gap: 18, opacity: shown > 0 ? 1 : 0 }}>
            {answer.map((a, i) => {
              const n = Math.max(0, Math.min(a.t.length, left));
              left -= a.t.length;
              if (n === 0 && i > 0) return null;
              return (
                <div key={i} style={{ display: "flex", flexDirection: "column", alignItems: "flex-start", gap: 8 }}>
                  <Chip who={a.who} size={19} />
                  <span style={{ font: `500 25px/1.35 ${fontFamily}`, color: C.ink }}>{a.t.slice(0, n)}</span>
                </div>
              );
            })}
          </div>
        </div>
      </Card>
    </AbsoluteFill>
  );
};

/* ---------- 5. 收尾 ---------- */
const End = () => {
  const f = useCurrentFrame();
  const icon = useSpring(0.1, { damping: 9, mass: 0.6 });
  const name = useSpring(0.4);
  const tag = useSpring(0.8);
  const pill = (i: number) => spring({ frame: f - sec(1.5 + i * 0.25), fps: FPS, config: { damping: 11 } });
  const hit = spring({ frame: f - sec(4), fps: FPS, config: { damping: 8, mass: 0.4 } }); // 38 秒重音
  const bump = f >= sec(4) ? Math.sin(Math.min(1, hit) * Math.PI) * 0.04 : 0;
  return (
    <AbsoluteFill style={{ background: C.bg, alignItems: "center", justifyContent: "center", flexDirection: "column", transform: `scale(${1 + bump})` }}>
      <Img src={staticFile("icon.png")} style={{ width: 170, height: 170, transform: `scale(${icon}) rotate(${(1 - icon) * -30}deg)` }} />
      <div style={{ font: `800 120px/1 ${fontFamily}`, letterSpacing: "-0.045em", color: C.ink, marginTop: 30, opacity: name, transform: `translateY(${(1 - name) * 30}px)` }}>MeetRec</div>
      <div style={{ font: `700 50px/1 ${fontFamily}`, letterSpacing: "-0.03em", color: C.ink, marginTop: 26, opacity: tag, position: "relative", paddingBottom: 12 }}>
        Know who said what.
        <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: 7, display: "flex", transform: `scaleX(${tag})`, transformOrigin: "left" }}>
          <i style={{ flex: 35, background: C.Me }} /><i style={{ flex: 21, background: C.Sarah }} /><i style={{ flex: 19, background: C.Daniel }} /><i style={{ flex: 25, background: C.Priya }} />
        </div>
      </div>
      <div style={{ display: "flex", gap: 18, marginTop: 56 }}>
        {["Free & open source", "macOS · Apple Silicon"].map((t, i) => (
          <span key={t} style={{ font: `600 28px/1 ${fontFamily}`, color: C.ink, background: "#fff", outline: `1px solid ${C.line}`, padding: "16px 26px", borderRadius: 999, opacity: pill(i), transform: `scale(${0.7 + pill(i) * 0.3})` }}>{t}</span>
        ))}
      </div>
      <div style={{ font: `500 34px/1 ${mono}`, color: C.muted, marginTop: 44, opacity: pill(2) }}>meetrec.dorara.app</div>
    </AbsoluteFill>
  );
};

/* ---------- 組起來 ---------- */
const Sfx: React.FC<{ at: number; src: string; volume?: number }> = ({ at, src, volume = 0.5 }) => (
  <Sequence from={sec(at)} layout="none"><Audio src={staticFile(`sfx/${src}.mp3`)} volume={volume} /></Sequence>
);

export const Promo = () => {
  const scenes: [number, number, React.FC][] = [
    [S.hook, S.label, Hook], [S.label, S.link, Label], [S.link, S.ai, Link], [S.ai, S.end, Ai], [S.end, TOTAL, End],
  ];
  return (
    <AbsoluteFill style={{ background: C.bg, fontFamily }}>
      {scenes.map(([a, b, Scene], i) => (
        <Sequence key={i} from={sec(a)} durationInFrames={sec(b - a)}><Scene /></Sequence>
      ))}
      {/* 旁白時音樂壓低 */}
      <Audio src={staticFile("music.wav")} volume={(fr) => {
        const t = lines.some((l) => fr >= sec(VO[l.id] - 0.15) && fr <= sec(VO[l.id] + l.duration + 0.15));
        return t ? 0.32 : 0.6;
      }} />
      {lines.map((l) => (
        <Sequence key={l.id} from={sec(VO[l.id])} layout="none"><Audio src={staticFile(`vo/${l.id}.mp3`)} /></Sequence>
      ))}
      <Sfx at={0} src="murmur" volume={0.35} />
      <Sfx at={0.9} src="pop" volume={0.6} />
      {[S.label, S.link, S.end].map((t) => <Sfx key={t} at={t - 0.2} src="whoosh" volume={0.35} />)}
      {meeting.map((_, i) => <Sfx key={i} at={POP0 + i * POP_GAP} src="pop" volume={0.45} />)}
      <Sfx at={S.link + 0.6} src="type" volume={0.4} />
      <Sfx at={S.link + 2.9} src="key" volume={0.6} />
      <Sfx at={S.link + 5.4} src="ding" volume={0.35} />
      <Sfx at={S.ai + 0.7} src="key" volume={0.7} />
      <Sfx at={S.ai + 6.7} src="ding" volume={0.35} />
      <Sfx at={S.end + 0.1} src="pop" volume={0.6} />
    </AbsoluteFill>
  );
};
