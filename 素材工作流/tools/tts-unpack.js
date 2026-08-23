// 把 AI Studio 批次收集的 {id: "data:audio/wav;base64,..."} JSON 拆成 wav，再用 ffmpeg 轉 mp3（64kbps 單聲道，修剪頭尾靜音）
// 用法: node tts-unpack.js <json> <輸出資料夾>
const fs = require('fs'), path = require('path'), { execSync } = require('child_process');
const [,, jsonPath, outDir] = process.argv;
const data = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
fs.mkdirSync(outDir, { recursive: true });
let n = 0;
for (const [id, url] of Object.entries(data)) {
  const b64 = url.split(',')[1]; const wav = path.join(outDir, id + '.wav');
  fs.writeFileSync(wav, Buffer.from(b64, 'base64'));
  const mp3 = path.join(outDir, id + '.mp3');
  execSync(`ffmpeg -y -loglevel error -i "${wav}" -af "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.05,areverse,silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.15,areverse,loudnorm=I=-16:TP=-1.5" -ac 1 -ar 24000 -b:a 64k "${mp3}"`);
  fs.unlinkSync(wav); n++;
}
console.log('unpacked', n, 'files ->', outDir);
