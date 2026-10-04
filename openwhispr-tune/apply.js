// Writes name-recognition settings into OpenWhispr's settings store
// (Chromium localStorage, a LevelDB folder). OpenWhispr must be quit — tune.sh handles that.
//
//   node apply.js <leveldb dir> <prompt file> [comma-separated dictionary words]
//
// Prints the dictionary that was written (JSON) when words were given.
const { ClassicLevel } = require('classic-level');
const fs = require('fs');
const [dir, promptFile, wordsArg] = process.argv.slice(2);

const K = k => Buffer.concat([Buffer.from('_file://\x00\x01', 'latin1'), Buffer.from(k, 'latin1')]);
const V = s => /^[\x00-\xff]*$/.test(s)
  ? Buffer.concat([Buffer.from([1]), Buffer.from(s, 'latin1')])     // Latin-1 string
  : Buffer.concat([Buffer.from([0]), Buffer.from(s, 'utf16le')]);   // UTF-16 string

const settings = {
  cloudTranscriptionModel: 'whisper-large-v3',   // full model: better with names than turbo
  useCleanupModel: 'true',                        // turn on the correction pass
  cleanupMode: 'providers',                       // "Bring your own key" providers
  cleanupProvider: 'groq',
  cleanupModel: 'openai/gpt-oss-120b',
  'customPrompt.cleanup': fs.readFileSync(promptFile, 'utf8'),
};
let words = null;
if (wordsArg && wordsArg.trim()) {
  words = [...new Set(wordsArg.split(',').map(w => w.trim()).filter(Boolean))];
  settings.customDictionary = JSON.stringify(words);
}

(async () => {
  const db = new ClassicLevel(dir, { keyEncoding: 'buffer', valueEncoding: 'buffer' });
  for (const [k, v] of Object.entries(settings)) await db.put(K(k), V(v));
  await db.close();
  if (words) console.log(JSON.stringify(words));
})();
