// 旁白 TTS：用 Gemini TTS API 把台詞表生成 mp3（每句一檔，各自有語速與起伏）
//
// 用法:
//   node tts-gemini.js <lines.json> <輸出資料夾> [voice=Zephyr]
//   lines.json 格式: { "s1": { "text": "Three, two, one, let's dig!", "dir": "Count slowly... then burst out fast" }, ... }
//
// API key 讀取順序：環境變數 GEMINI_API_KEY → 檔案 %USERPROFILE%\.gemini_api_key（一行，不要引號）
//   金鑰不要放進 repo、不要貼進對話；到 https://aistudio.google.com/apikey 複製「Default Gemini API Key」，
//   用記事本存成 C:\Users\<你>\.gemini_api_key 即可。免費級（Free tier）不扣錢，只有速率限制。
//
// 產出：<輸出資料夾>/<id>.mp3（24kHz 單聲道 64kbps，頭尾靜音修掉、音量正規化）。已存在的檔會跳過（重跑不重生）。
const fs = require('fs'), path = require('path'), os = require('os'), { execSync } = require('child_process');

const [,, linesPath, outDir, voiceArg] = process.argv;
if (!linesPath || !outDir) { console.error('用法: node tts-gemini.js <lines.json> <輸出資料夾> [voice]'); process.exit(1); }
const VOICE = voiceArg || 'Zephyr';
const MODELS = ['gemini-3.1-flash-tts-preview', 'gemini-2.5-flash-preview-tts'];   // 先新後舊，前者不存在就退回

let key = process.env.GEMINI_API_KEY;
if (!key) { const f = path.join(os.homedir(), '.gemini_api_key'); if (fs.existsSync(f)) key = fs.readFileSync(f, 'utf8').trim(); }
if (!key) { console.error('找不到 API key：設 GEMINI_API_KEY 或建立 ~/.gemini_api_key'); process.exit(2); }

const lines = JSON.parse(fs.readFileSync(linesPath, 'utf8'));
// 場景描述：lines.json 可用 "_scene" 覆寫（各遊戲不同）；沒寫就用通用版
const SCENE = lines._scene || "You are the cheerful narrator of a toddler's video game, talking to a 4-year-old. Playful, warm, energetic, clearly articulated, like a friendly kids' TV host.";
delete lines._scene;
fs.mkdirSync(outDir, { recursive: true });

function pcmToWav(pcm, rate = 24000) {   // L16 mono → WAV
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + pcm.length, 4); h.write('WAVE', 8); h.write('fmt ', 12);
  h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(rate, 24);
  h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34); h.write('data', 36); h.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([h, pcm]);
}

async function gen(model, id, { text, dir }) {
  const prompt = `${SCENE}\nDelivery for this line: ${dir || 'upbeat and fun'}\nSay exactly this line and nothing else: "${text}"`;
  const body = {
    contents: [{ parts: [{ text: prompt }] }],
    generationConfig: { responseModalities: ['AUDIO'], speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: VOICE } } } },
  };
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  if (!r.ok) { const t = await r.text(); const e = new Error(`${model} HTTP ${r.status}: ${t.slice(0, 200)}`); e.status = r.status; throw e; }
  const j = await r.json();
  const part = j.candidates?.[0]?.content?.parts?.find(p => p.inlineData);
  if (!part) { const e = new Error('回應裡沒有音訊: ' + JSON.stringify(j).slice(0, 200)); e.noAudio = true; throw e; }
  const mime = part.inlineData.mimeType || '';
  const rate = +(mime.match(/rate=(\d+)/)?.[1] || 24000);
  return { buf: Buffer.from(part.inlineData.data, 'base64'), mime, rate };
}

(async () => {
  let model = MODELS[0], ok = 0, skip = 0;
  for (const [id, spec] of Object.entries(lines)) {
    const mp3 = path.join(outDir, id + '.mp3');
    if (fs.existsSync(mp3)) { skip++; continue; }
    let out, safe = false;
    for (let attempt = 0; attempt < 5; attempt++) {
      try { out = await gen(model, id, spec, safe); break; }
      catch (e) {
        if (e.status === 404 && model !== MODELS[1]) { console.log(`  ${model} 不存在，改用 ${MODELS[1]}`); model = MODELS[1]; continue; }
        if (e.status === 429 && attempt >= 1 && model !== MODELS[1]) { console.log(`  ${id}: 429 額度用完，改用 ${MODELS[1]}（額度分開算）`); model = MODELS[1]; continue; }
        if (e.status === 429 || e.status >= 500) { const wait = 15 * (attempt + 1); console.log(`  ${id}: ${e.message.slice(0, 80)} → 等 ${wait}s 重試`); await new Promise(r => setTimeout(r, wait * 1000)); continue; }
        if (e.noAudio) { console.log(`  ${id}: ${e.message.slice(0, 120)} → ${safe ? '再試一次' : '改用中性情境重試'}`); safe = true; continue; }   // SAFETY／空回應：換中性情境，不中止整批
        console.log(`  ${id}: ${e.message.slice(0, 120)}`); break;
      }
    }
    if (!out) { console.log(`FAIL ${id}`); continue; }
    const wav = path.join(outDir, id + '.wav');
    fs.writeFileSync(wav, /L16|pcm/i.test(out.mime) ? pcmToWav(out.buf, out.rate) : out.buf);
    execSync(`ffmpeg -y -loglevel error -i "${wav}" -af "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.05,areverse,silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.15,areverse,loudnorm=I=-16:TP=-1.5" -ac 1 -ar 24000 -b:a 64k "${mp3}"`);
    fs.unlinkSync(wav);
    const dur = execSync(`ffprobe -v error -show_entries format=duration -of csv=p=0 "${mp3}"`).toString().trim();
    console.log(`OK ${id.padEnd(4)} ${(+dur).toFixed(2)}s  ${spec.text}`); ok++;
    await new Promise(r => setTimeout(r, 1200));   // 免費級速率限制，放慢一點
  }
  console.log(`完成 ${ok} 句（跳過已存在 ${skip}）→ ${outDir}`);
})().catch(e => { console.error('錯誤:', e.message); process.exit(3); });
