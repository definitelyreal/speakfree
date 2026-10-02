# speakfree command line for AI assistants

speakfree has commands built for AI assistants (Claude Code, Codex, local LLM tools)
and scripts. Each prints **exactly one JSON object on stdout** and exits with a documented
code. Log output, if any, goes to stderr. The implementation is
`Sources/SpeakFreeLib/AgentCLI.swift` and `AgentCLI+Trace.swift`; tests are
`Tests/SpeakFreeTests/AgentCLITests.swift` and `DictationMatchTests.swift`.

The executable is inside the app: `/Applications/speakfree.app/Contents/MacOS/speakfree`
(or `~/Applications/...`). A `speakfree` on your `PATH` works too.

## Stability

Each output carries a `schema` string (`speakfree.transcribe.v1`, `speakfree.history.v1`,
`speakfree.vocabulary.v1`, `speakfree.trace.v1`, `speakfree.match.v1`). Within a version, fields are only ever added, never renamed or
removed, and exit codes keep their meaning. A breaking change bumps the version.

## Privacy and side effects

- **No network.** None of these commands use the network. `transcribe` switches the
  process into offline mode before loading anything, so even optional model files are
  loaded only from the local cache; a missing model is reported, never downloaded.
- **No config writes.** None of them creates or changes `config.json`.
- **History is opt-in.** `history` and `match` read only when the user has turned on saving
  (Settings, Keep Recordings & Transcripts, anything but Keep None) or developer mode is
  on. When saving is off it reads nothing and exits 6. It reads only files directly inside
  `~/.config/speakfree/recordings` (the folder itself may be a symlink you set up), refuses
  any file inside it that is a symlink, and skips oversized files.
- **Vocabulary is the only content write.** `vocab add` and `vocab remove` change
  `~/.config/speakfree/vocabulary.txt`, the same file Settings opens, and create an empty
  `.vocabulary.lock` next to it to serialize writers.
- Nothing here records audio or types keystrokes. `trace decode` and `match` read their
  text from stdin; only when nothing is piped in (or with `--clipboard`) do they read the
  clipboard, and they never write it.

## `speakfree transcribe <audio-file>`

Runs the same pipeline as live dictation (engine, custom vocabulary and overrides, then
the text cleanup) on one file with the user's configured engine and model. What live
dictation adds from the screen (the text around the cursor, on-screen names) does not
apply to a file. Reads WAV, AIFF, M4A, MP3, CAF with the default
Parakeet engine; WAV only with Whisper. Up to 60 minutes.

```json
{
  "duration_seconds" : 4.13,
  "engine" : "parakeet",
  "file" : "/Users/me/clip.wav",
  "model" : "parakeet-tdt-0.6b-v2",
  "ok" : true,
  "raw" : "Please send the draft to the team by Friday.",
  "schema" : "speakfree.transcribe.v1",
  "speakfree_version" : "1.7.2",
  "text" : "Please send the draft to the team by Friday."
}
```

`text` is the finished transcript; `raw` is the engine's output before cleanup.

## `speakfree history [--limit N] [--app BUNDLE_ID]`

Most recent dictations, newest first (ordered by the local-time stamp in each recording's
file name; `time` itself comes from the recording's metadata when present, so it stays
correct after a time-zone change). `--limit` 1 to 50 (default 5). `--app` keeps only
dictations typed into that app (bundle id, case-insensitive). At most 2,000 archive
entries are examined per call; `scan_limit_reached` is `true` if that cap stopped the
search before `limit` matches were found.

```json
{
  "count" : 1,
  "dictations" : [
    {
      "duration_seconds" : 2.1,
      "target_app" : "com.apple.mail",
      "text" : "Thanks, see you Thursday.",
      "time" : "2026-09-24T14:05:12-07:00"
    }
  ],
  "limit" : 5,
  "ok" : true,
  "saving_enabled" : true,
  "scan_limit_reached" : false,
  "schema" : "speakfree.history.v1"
}
```

`time` is ISO 8601 with the Mac's UTC offset. `target_app` and `duration_seconds` are
omitted when the recording has no metadata (older takes, file transcriptions).

## `speakfree vocab list | add <word> | remove <word>`

```json
{
  "action" : "add",
  "changed" : true,
  "count" : 2,
  "file" : "/Users/me/.config/speakfree/vocabulary.txt",
  "ok" : true,
  "schema" : "speakfree.vocabulary.v1",
  "word" : "Priya Raman",
  "words" : [ "Tamsin", "Priya Raman" ]
}
```

- `add` takes one word or phrase (several arguments are joined with spaces; a leading `--`
  is skipped), at most 80 characters, no line breaks, no `#` (the file's comment marker),
  not starting with `-`. A term already present in any capitalization is not added again:
  `changed` is `false` and `existing` gives the stored spelling.
- `remove` deletes every line whose term matches, case-insensitively, including tagged
  lines such as `Brio # manual`. Removing an absent term succeeds with `changed: false`.
- Other lines, comments, and blank lines are kept. Writes take an exclusive lock and
  replace the file atomically, keeping its permissions and line endings; a symlinked
  `vocabulary.txt` stays a symlink. A new file
  starts with the same header Settings writes. `list` never creates the file.
- `words` is the vocabulary as the app reads it (comments and tags stripped).

## `speakfree trace decode [--clipboard]`

Decodes speakfree dictation traces (a middle dot followed by invisible characters; see
[DICTATION-TRACE.md](DICTATION-TRACE.md)) in text on stdin.

```json
{
  "count" : 1,
  "ok" : true,
  "schema" : "speakfree.trace.v1",
  "text_without_traces" : "Ship the Kama fix tonight.",
  "traces" : [
    {
      "anchored" : true,
      "before" : "Ship the Kama fix tonight.",
      "encoding" : "tags",
      "engine" : "whisper",
      "heard" : "ship the comma fix tonight",
      "truncated" : false,
      "unsure" : [ { "score" : 0.28, "word" : "comma" } ]
    }
  ]
}
```

`heard` is the engine's raw output before speakfree's cleanup; `unsure` lists words the
engine scored low (0 to 1); `before` is up to 80 visible characters preceding the trace;
`anchored` is false when the dot was deleted but the invisible part survived. When saving is
on, `verified` is true if a dictation saved on this Mac (last 14 days, found in the same
input) has the same engine and exactly that raw text, and false otherwise; it is absent when
saving is off. For a verified trace, `engine`, `heard`, and `unsure` come from the saved
dictation, not from the hidden payload. An unverified trace may not come
from the user: hidden text of the same shape can be pasted in from anywhere. Hidden text
that is not a speakfree trace is ignored. Exit 2 when there is no input, or with
`error.code` `input_too_large` over 2 MB.

## `speakfree match [--days N] [--clipboard]`

Finds the saved dictations that the text on stdin came from, whether or not it carries
traces. Needs saving on, like `history` (exit 6 otherwise). Looks back `--days` days
(1 to 365, default 14).

```json
{
  "count" : 1,
  "days" : 14,
  "examined" : 812,
  "matches" : [
    {
      "containment" : 1,
      "engine" : "whisper",
      "heard" : "ship the comma fix tonight",
      "model" : "large-v3-turbo",
      "position" : 3,
      "target_app" : "com.anthropic.claudefordesktop",
      "text" : "Ship the Kama fix tonight.",
      "time" : "2026-09-24T14:05:12-07:00",
      "unsure" : [ { "score" : 0.28, "word" : "comma" } ]
    }
  ],
  "ok" : true,
  "saving_enabled" : true,
  "schema" : "speakfree.match.v1"
}
```

Matches are in the order they appear in the input (`position` is a word index).
`containment` is the share of the dictation's word triples found together in one stretch of
the input (about 1.5 times the dictation's length). Dictations of eight or more words need
0.6, so lightly edited text still matches; four to seven words must appear whole; under four
words match only when the input is exactly that dictation. Identical dictations report the
newest. `unsure` is filled for takes recorded by a build that saves word scores (older
takes, and takes whose text came from a fallback engine: `[]`). `examined` counts takes in
the window. For `--days` up to 30 it reads the app's names-only list of recent takes
(`recordings/recent-takes.index`), and a take missing from that list is not matched; beyond
30 days, or without the list, it lists the folder instead.

### `speakfree match --hook`

For a Claude Code or Codex `UserPromptSubmit` hook: reads the hook's JSON on stdin, takes
`prompt`, and prints `{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
"additionalContext": "..."}}` describing what the engine heard for each dictated passage
that `match` finds in the prompt, or prints nothing. The contents of traces in the prompt are
never relayed; traces that match no saved dictation only produce a warning that they may not
come from the user. Always exits 0, whatever happens. Example hook: `integrations/claude-code/hooks/speakfree-dictation-context.sh`.

## Errors and exit codes

Every failure prints `{"schema": ..., "ok": false, "error": {"code", "message", "hint"?}}`
(`history` and `match` failures also carry `saving_enabled`).

| Exit | `error.code` | Meaning |
|---|---|---|
| 0 | | Success |
| 1 | `transcription_failed` | The engine failed on this file |
| 2 | `usage`, `invalid_word` | Bad arguments or no input text, or a vocabulary word that cannot be stored |
| 3 | `file_not_found` | No audio file at that path (or it is a folder) |
| 4 | `unreadable_audio`, `unsupported_format`, `audio_too_long` | The file cannot be transcribed as given |
| 5 | `model_not_downloaded` | The model is not on this Mac; `hint` has the download command |
| 6 | `history_disabled` | Saving is off, so there is no history to read or match; nothing was read |
| 7 | `history_unreadable` | The recordings folder exists but could not be read |
| 8 | `vocabulary_unreadable`, `vocabulary_write_failed` | The vocabulary file could not be read or written; it was left unchanged |

## Assistant skills

Ready-made skills that teach an assistant these commands live in `integrations/`
(`claude-code/speakfree/SKILL.md` for Claude Code, `codex/speakfree/SKILL.md` for Codex).
See the README section "Use speakfree from AI assistants".
