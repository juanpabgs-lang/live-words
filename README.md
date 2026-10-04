# Live Words

**See your words appear while you talk, like macOS dictation (F5), but for your dictation app.**

Apps like **OpenWhispr**, **Wispr Flow** and **superwhisper** only show text *after* you stop talking. Live Words adds a small floating bar at the bottom of your screen that fills in **word by word as you speak**, so you know it's hearing you right.

```
 ┌──────────────────────────────────────────────────────────────┐
 │ ●  …so on Monday I want to finish the landing page, then on  │
 │    Tuesday I'll record the video for the launch              │
 └──────────────────────────────────────────────────────────────┘
```

- Free, and **runs 100% on your Mac**. It uses Apple's own on-device speech engine, the same one behind macOS dictation. No API key, no account, and no audio leaves your computer.
- Doesn't change your dictation app at all. Your app still does the final transcription and pastes it like before. Live Words is just the live preview.
- Shows up on whichever screen you're working on, even with multiple monitors.

---

## Install (one command)

**Requires macOS 26 (Tahoe) or newer.**

1. Open **Terminal** (press `⌘ Space`, type `Terminal`, press Enter).
2. Paste this and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/juanpabgs-lang/live-words/main/install.sh | bash
```

3. When macOS asks to let **Live Words** use the microphone, click **Allow**.

That's it. A speech-bubble icon appears in your menu bar, and Live Words starts automatically every time you log in.

> **First time only:** if your Mac doesn't have Apple's developer tools yet, a window pops up asking to install them (needed to build the app). Click **Install**, wait for it to finish (a few minutes), then paste the same command again.

---

## Using it

Just dictate the way you always do. When your dictation app starts listening, the bar appears:

| What you see | Meaning |
|---|---|
| 🔴 pulsing dot + "Listening…" | It's hearing you, words are coming |
| Bright white text | Words it's sure about |
| Dimmer text at the end | Words it's still figuring out (they can change) |
| 🟢 green dot, then fades | You stopped; your dictation app is pasting the final text |

**Menu bar icon (speech bubble):**
- **Show live words**: turn the bar on or off.
- **Language**: English, or Spanish (Spain / Mexico / US). The first switch to a new language downloads Apple's speech model for it, which takes about a minute.
- **Open at Login**: on by default.
- **Quit Live Words**

**Why the bar and the pasted text can differ slightly:** the bar uses Apple's instant on-device engine, and your dictation app uses its own (usually bigger and slower) model for the final text. The bar is the live preview; the pasted text is the final version.

---

## Supported dictation apps

Out of the box: **OpenWhispr**, **Wispr Flow**, **superwhisper**. Live Words notices when one of them turns the mic on, so it works with any hotkey and with both "hold to talk" and "tap to start/stop".

Using a different app? Add its bundle ID to the list (replace `com.example.yourapp`):

```bash
defaults write com.jpbarrios.livewords watchApps -array com.gizmolabs.openwhispr com.electron.wispr-flow com.superduper.superwhisper com.example.yourapp
```

Then quit Live Words from the menu bar and open it again. (To find an app's bundle ID: `osascript -e 'id of app "AppName"'`)

---

## Custom words (names, companies, jargon)

If you use **OpenWhispr**, Live Words reads the words in OpenWhispr's **Dictionary** tab automatically and uses them to recognize names better. Add a word there once and both the live bar and OpenWhispr's final text get better.

### 🎯 Optional: make OpenWhispr way better at names

By default, OpenWhispr + Groq often mangles company and product names ("Pallantir", "Higgs field", "Eleven Labs"). This optional tuner changes three settings:

1. **Whisper Large v3** instead of Turbo: the full model is noticeably better with names, and still about 1 second on Groq.
2. **A name-fixing pass**: after transcribing, a fast AI model (GPT-OSS 120B on your Groq key) fixes **only** misspelled names and brands. It keeps your exact words, filler, swearing and English/Spanish mixing, and it undoes Whisper's auto-censoring ("f\*\*\*ing" becomes "fucking"). It also handles "X, no wait, Y" corrections. It adds about half a second.
3. **(Optional) A clean dictionary**: OpenWhispr's "auto-learn" tends to fill the dictionary with junk like "the", "and" and misspellings, which hurts accuracy. You can replace it with just your real names.

**Needs:** OpenWhispr set up with **Groq** and your own API key, plus [Node.js](https://nodejs.org).

```bash
git clone https://github.com/juanpabgs-lang/live-words.git ~/live-words
~/live-words/openwhispr-tune/tune.sh
```

To also replace your dictionary with your own list of names:

```bash
~/live-words/openwhispr-tune/tune.sh --words "Palantir, Higgsfield, ElevenLabs, Your Company"
```

It **backs up your OpenWhispr settings first** and prints an undo command. OpenWhispr closes for a few seconds and reopens. You can edit `openwhispr-tune/prompt.txt` to change how the name-fixing pass behaves.

---

## Troubleshooting

**No bar appears**
1. Is the speech-bubble icon in your menu bar? If not, open **Live Words** from Applications.
2. Click the icon. If it says **"Needs microphone access"**: open System Settings → Privacy & Security → Microphone and turn on **Live Words**.
3. Make sure **Show live words** is checked.
4. Check the log: `tail -20 ~/Library/Logs/LiveWords.log`. Each dictation should show `dictation app started recording` followed by `first words after …s`. If you never see "started recording", your dictation app isn't in the supported list (see above).

**Words are slow or wrong:** check that the language in the menu matches what you're speaking.

**Update to the latest version:** run the install command again.

**Uninstall:**

```bash
curl -fsSL https://raw.githubusercontent.com/juanpabgs-lang/live-words/main/uninstall.sh | bash
```

---

## How it works (for the curious)

1. Every 50 ms, Live Words asks macOS's audio system (CoreAudio) whether your dictation app is using the mic. This is read-only; it never touches the other app.
2. When the app starts listening, Live Words opens the mic too. This is normal shared access, no exclusive grab, so your dictation app is unaffected. It streams the audio into Apple's `SpeechAnalyzer` + `DictationTranscriber` (new in macOS 26), fully on-device.
3. Partial results stream into a floating, click-through panel on the screen you're using.
4. When your app stops listening, Live Words closes the mic and fades the bar out.

Everything is in one Swift file: [`LiveWords.swift`](LiveWords.swift).

### Developing

```bash
./build.sh                 # build into ./build/LiveWords.app
./build.sh install         # build, install to /Applications, relaunch
./build/LiveWords.app/Contents/MacOS/LiveWords --demo some-speech.wav   # play a recording through the bar
```

Make a test recording: `say -o t.aiff "hello world" && afconvert -f WAVE -d LEI16@16000 -c 1 t.aiff t.wav`

## License

MIT
