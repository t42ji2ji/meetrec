// 每句旁白各自生成，記下長度給 Remotion 排時間軸
import fs from "node:fs";

const VOICE = "hpp4J3VqNfWAUOO0d1Us"; // Bella
const lines = JSON.parse(fs.readFileSync("src/lines.json", "utf8"));
fs.mkdirSync("public/vo", { recursive: true });

for (const line of lines) {
  const res = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${VOICE}/with-timestamps`, {
    method: "POST",
    headers: { "xi-api-key": process.env.ElevenLab_API_KEY, "content-type": "application/json" },
    body: JSON.stringify({
      text: line.en,
      model_id: "eleven_multilingual_v2",
      voice_settings: { stability: 0.45, similarity_boost: 0.8, style: 0.35, speed: 1.08 },
    }),
  });
  if (!res.ok) throw new Error(`${line.id}: ${res.status} ${await res.text()}`);
  const data = await res.json();
  fs.writeFileSync(`public/vo/${line.id}.mp3`, Buffer.from(data.audio_base64, "base64"));
  const ends = data.alignment.character_end_times_seconds;
  line.duration = Math.round(ends[ends.length - 1] * 100) / 100;
  console.log(line.id, line.duration);
}
fs.writeFileSync("src/lines.json", JSON.stringify(lines, null, 2) + "\n");
