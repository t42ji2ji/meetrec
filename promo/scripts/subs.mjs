// 由 lines.json 產生 en / zh-TW 字幕
import fs from "node:fs";

const lines = JSON.parse(fs.readFileSync("src/lines.json", "utf8"));
const ts = (s) => new Date(s * 1000).toISOString().slice(11, 23);
for (const [lang, key] of [["en", "en"], ["zh-TW", "zh"]]) {
  const cues = lines.map((l, i) => `${i + 1}\n${ts(l.at)} --> ${ts(l.at + l.duration + 0.3)}\n${l[key]}`);
  fs.writeFileSync(`out/meetrec-promo.${lang}.vtt`, `WEBVTT\n\n${cues.join("\n\n")}\n`);
}
