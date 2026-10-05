<!-- ai-suggestion:unverified | session:unknown | date:2026-10-04 | asof:2026-10-04 -->
# Dictation trace: let an AI see what the speech engine heard

When you dictate a prompt to an AI assistant, the assistant only sees speakfree's finished
text. If the engine misheard a word ("Kama" for "comma"), or speakfree's cleanup turned a
spoken word into punctuation, the model has no way to know. speakfree offers three ways to
give the model what the engine actually heard. All three are optional and local.

| Way | What you do | What the model gets |
|---|---|---|
| **Dictation trace** | Turn it on in Settings | A dot after each dictation, carrying the raw engine text invisibly |
| **Hook** | Install one Claude Code or Codex hook | The raw engine text for every dictated part of each prompt, added as context |
| **Match** | Run `speakfree match` on any text | The saved dictations that text came from, even if the dots were deleted |

"What the engine heard" means: the engine's raw output before speakfree's text cleanup
(spoken punctuation, custom vocabulary, capitalization, formatting), plus the words the
engine was unsure of, each with the engine's own confidence from 0 to 1 (Whisper: token
probability, a word is listed below 0.50; Parakeet: token confidence, below 0.60).

No phonemes. Neither engine exposes what sounds it recognized, only the words it chose. A
pronunciation dictionary run over those words (macOS can do this locally) would only restate
the words in another alphabet, which a model can already infer, so it adds no information
and is not included.

## 1. The dictation trace

Off by default. Alpha and development builds have a compact **Dictation Trace (Testing)**
menu below Settings, with four choices:

| Choice | What is inserted after the same target and privacy checks |
|---|---|
| Off | Finished dictation only |
| Text + · trace (TAG) | Finished dictation, then a dot carrying this take's payload |
| · trace only (TAG) | The dot and payload, omitting the finished dictation |
| Expanded text + raw trace (recommended) | Finished dictation, then the same payload as readable JSON |

Expanded text is the readable baseline for comparison. The TAG modes remain experiments:
text fields or model providers may strip them, and surviving characters do not establish
that an AI can read them. One visible dot contains many Unicode scalars, not a compressed
single-character summary. It carries the raw words themselves and the available uncertain
words from this take, subject to the existing caps below; it is not an ID or archive pointer.

**The two new modes are limited to recognized AI chat apps and approved browser pages.**
Terminals and editors are excluded even if named in a custom app list. If an AI app is
classified as containing a terminal pane, or its bundle identity cannot be read and matched,
these modes are blocked there too: speakfree
cannot establish which pane has focus. A blocked experiment inserts the finished text.
This keeps added multiline raw text from executing shell input, and keeps dot-only from
replacing a command. The older Text + TAG and selectors modes retain their existing targets
and the editor/terminal limitations below.

Each take snapshots the selected mode and app/host lists before transcription starts. A
change while that transcription runs applies to later takes. If any gate blocks dot-only,
the finished text is inserted normally. Copy/recovery paths retain the original readable
finished text in every mode. Saved history and corpus sidecars remain the ordinary finished
and raw dictation, without this output decoration. Choosing Off reverses the experiment.
The two new modes are also blocked at runtime outside alpha/development builds.
Opening the status menu or Settings refreshes the trace selection from disk. An unrelated
Settings save preserves a later CLI mode or allowlist change; only an intentional trace
selection replaces that mode.
If the config cannot be read or parsed, an unrelated save keeps the last loaded app/host
lists and turns trace off rather than re-enabling a stale selection.
For later dictations, each exact expanded header plus valid one-line trace JSON is removed
from cursor context, preserving surrounding finished and user text. Capitalization and recognition hints use the finished words;
malformed or lookalike blocks remain ordinary text. The remembered context also uses the
original finished words, including in dot-only mode.

The matching control is in **Settings, Advanced, Dictation Trace**. From Terminal:

```bash
speakfree set-trace tags        # or: off; alpha/dev also supports tags-only and expanded
```

In Text + TAG mode, after each dictation into an app on the list, speakfree types one space,
one visible middle dot, and the encoded payload:

```
Ship the Kama fix tonight. ·<invisible>
```

The payload is a small JSON object:

```json
{"speakfree_trace":1,"engine":"whisper","heard":"ship the comma fix tonight","unsure":["comma 0.28"]}
```

Two invisible encodings:

- **tags** (Unicode TAG characters, U+E0020 to U+E007E): one encoded character per
  character of the JSON. Non-ASCII text is written as `\u` escapes. The idea is that a model
  that receives these characters may recover the JSON. This has not been established for
  the destination app and AI model: an app, or the model provider, may strip TAG characters, since they are a known
  way to hide text. The survival test below checks the app; sending the test sentence and
  asking the model what follows the dot checks the rest.
- **selectors**, a legacy Settings/CLI option (variation selectors U+FE00 to U+FE0F and
  U+E0100 to U+E01EF): one per byte, following the dot. This is fragile: repeated selectors
  do not form a normal variation sequence, and visible rendering is permitted for misplaced
  selectors. A Swift grapheme count is not proof of invisibility. The behavior is described
  in [Unicode 18.0, section 3.6.2](https://unicode.org/versions/Unicode18.0.0/core-spec/chapter-3/#G30602).
  `speakfree trace decode` recovers preserved payloads; selectors are not a recommended mode.

Which one survives depends on the app. Run the two-minute survival test (below) to find out.

### Where it is added

Only when **all** of these hold:

- The trace is on.
- The app you started dictating in is still frontmost when the text is inserted, and it is
  on the list: Claude, Codex / ChatGPT, VS Code, Cursor, Windsurf, Terminal, iTerm, Warp,
  Ghostty, kitty, Alacritty, WezTerm, and browsers (Chrome, Safari, Brave, Arc, Edge).
- In a browser, the page is Claude or ChatGPT (`claude.ai`, `chatgpt.com`,
  `chat.openai.com`), read from the page's address through Accessibility. If speakfree
  cannot read the address, no trace.
- Secure Input is off and the field is not a password field.

Messages, Mail, Slack, WhatsApp, Signal, Telegram, Discord, Teams, Outlook, Superhuman, and
Zoom are not on the list and never get a trace unless you write your own app list that
includes them. If the text
cannot be inserted and falls back to the clipboard, the copy has no trace. Your next
dictation ignores the dot when deciding capitalization and spacing.

To change the lists, edit `~/.config/speakfree/config.json`:

```json
"dictationTrace": "tags",
"dictationTraceApps": ["com.anthropic.claudefordesktop", "com.microsoft.VSCode"],
"dictationTraceWebHosts": ["claude.ai"]
```

Setting `dictationTraceApps` replaces the default list entirely. The page check applies only to
browsers speakfree recognizes (Chrome, Safari, Brave, Arc, Edge, Firefox, Opera, Vivaldi, Orion);
any other browser you add gets a trace on every page, webmail included. A long dictation's trace
carries the first 2,000 characters (marked `"truncated":true`); `speakfree match` still
finds the whole take.

**Editors and terminals get it in every field.** speakfree cannot tell the Claude Code panel
in VS Code or Cursor from the file you are editing or the commit message box, nor Claude
Code in a terminal from a plain shell prompt. So with the trace on, dictating into a source
file, a commit message, a pull request description, or a shell command leaves the invisible
trace there too, and it will travel with that code or commit (to a public repository, if
that is where it goes) and can break a shell command. If you dictate into those places,
remove the editors and terminals from your list (`dictationTraceApps`) and use the hook
instead, which adds nothing to the text itself.

### Privacy

A trace puts your raw spoken words into whatever you dictated into, which the app then sends
wherever it sends your text (for an AI assistant, its model provider). The raw words are
usually the same as the visible text, but they can include things the cleanup removed, such
as a word you said and then corrected by voice. That is why the trace is off by default,
limited to AI and coding apps, and never added in chat or mail apps.

## 2. Decoding traces

```bash
pbpaste | speakfree trace decode          # or: speakfree trace decode --clipboard
```

Prints each trace with the visible text just before it, and the text with traces removed.
When saving is on, each trace also gets `verified`: true when one of your saved dictations
has exactly that raw text, false when none does. A false trace may not be yours: anyone can
hide text of the same shape in a web page or file you paste from, so treat it as unverified. A trace can only be verified when its dictation is found in the same text, so a dictation of under four words inside longer text shows as unverified even when it is yours.
The Claude Code and Codex skills know this command: ask "decode the dictation traces in
this text".

## 3. Assembling the dots: `speakfree match`

If you deleted the dots, dictated in pieces, or jumped between apps, `match` finds which of
your saved dictations a piece of text came from:

```bash
pbpaste | speakfree match                 # last 14 days; --days 30 to look further back
```

It needs saving turned on (Settings, Keep Recordings & Transcripts), reads only the local
recordings folder, and returns, for each dictation it finds in the text, the time, the app,
the finished text, the raw engine text (`heard`), and the unsure words. Matching is by word
triples that must sit together in one stretch of the text: a dictation of eight or more
words still matches after light edits, one of four to seven words must appear whole, and
one under four words matches only when the whole text is that dictation. A typed sentence
that happens to repeat something you once dictated word for word will also match.

## 4. The hook: raw words with every prompt, no dots needed

`integrations/claude-code/hooks/speakfree-dictation-context.sh` is a `UserPromptSubmit` hook
for Claude Code, and works unchanged for Codex. On each prompt it matches the prompt against
your saved dictations (saving must be on) and adds the raw engine text for each dictated
part as context. It adds nothing when the engine heard exactly what was inserted and was
sure of every word, and it can never block a prompt. It never passes on the contents of a
trace found in the prompt: only your saved dictations count as what you said. If the prompt
holds traces that match none of them, it tells the model they may not be yours. Install
steps are at the top of the script.

Speed, measured 2026-09-24 on an M3 MacBook, release build, 100 runs, against a synthetic
archive of 25,000 takes (5,000 in the 14-day window, the size of a heavy user's two weeks):

| Path | p50 | p90 |
|---|---|---|
| Hook script, prompt with a dictated passage | 55 ms | 56 ms |
| Hook script, prompt with no dictation | 52 ms | 53 ms |
| `speakfree match --hook` called directly, dictated passage | 52 ms | 53 ms |

Reproduce with `scripts/make-match-fixture.py` and `scripts/bench-match-hook.py`. The app
keeps a names-only list of recent takes (`recordings/recent-takes.index`, no transcript
text) so `match` does not list the whole recordings folder on every prompt; listing an
80,000-file folder instead roughly doubles the time. The app refreshes the list from the folder at each launch
(covering the last 30 days; `--days` beyond 30 lists the folder), and
trashing or pruning recordings removes their names from it. These timings are with the
files already in the disk cache; the first prompt after a restart can take longer.

Codex: its hooks use the same event name (`UserPromptSubmit`), the same `prompt` input
field, and the same `hookSpecificOutput.additionalContext` output, configured in
`~/.codex/config.toml` or `hooks.json` (see the script header). Codex saves context over
about 2,500 tokens to a file and shows the model a preview; this hook's output is far
smaller.

## 5. Two-minute survival test

```bash
python3 scripts/trace-survival-test.py
```

For each app (Claude, Codex, VS Code, terminal Claude Code, Chrome on claude.ai, Safari on
chatgpt.com) and each encoding, it puts a traced test sentence on the clipboard; you paste
it (without sending), press Return, copy it back, press Return. It reports SURVIVED,
DAMAGED, STRIPPED, or NOT COPIED for each. It only uses the clipboard. Type `s` to skip an
app, or name apps: `python3 scripts/trace-survival-test.py claude chrome`.

Limits: speakfree inserts into Electron apps and browsers by pasting, which is what the test
does, but into Terminal and iTerm it may type with simulated key presses, so a terminal
result is a guide rather than proof. Copying back shows what the text box kept, not what
reached the model. The test sentences are ordinary clipboard entries, so a clipboard-history
app may record them (they contain only the synthetic test sentence).
