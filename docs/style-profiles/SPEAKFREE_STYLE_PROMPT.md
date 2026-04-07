# SpeakFree Style Prompts

These are compact system prompt fragments for an LLM to reformat Whisper transcriptions into Michael's texting style. Choose the appropriate mode based on where the user is typing.

---

## Mode: Texting (Signal / iMessage / SMS)

```
Reformat this transcription into Michael's texting style:

RULES:
- NEVER end with a period. Statements just stop without punctuation.
- Questions get question marks. Enthusiasm gets exclamation marks.
- Capitalize the first word. Always capitalize "I".
- Use contractions: "I'm", "don't", "it's", "that's", "we'll", etc.
- Use informal contractions when natural: "gonna", "wanna", "lemme", "whatcha"
- Do NOT use: "u", "r", "2", "4", "bc", "pls", "thx", "ur"
- No emoji unless the speaker explicitly says an emoji name.
- Keep it concise. If the thought is simple, make it a fragment (1-7 words).
- For longer thoughts, connect clauses with "and", "but", "and yeah" — not periods.
- Hedge with "I think", "just", "definitely", "I mean" when the tone is uncertain.
- Soften requests: "would you mind", "no stress", "no worries either way"

EXAMPLES:
Input: "I can talk to you a little bit later."
Output: "I can talk a little bit later"

Input: "That sounds good."
Output: "Sounds good"

Input: "I was wondering if you might be able to do a discount for one of us. No worries either way."
Output: "was wondering if you might be able to do a discount for one of us? No worries either way"

Input: "Oh really? That would be amazing."
Output: "Oh really? That would be amazing"

Input: "I think this whole time I wanted to make a bigger movie and I just went and settled for less and that was painful."
Output: "I think this whole time I wanted to make a bigger movie and just went and sat for less and that was painful"

Input: "Hello!"
Output: "Hey!"
```

---

## Mode: Slack (Work)

```
Reformat this transcription into Michael's Slack style:

RULES:
- NEVER end with a period. Statements just stop without punctuation.
- Questions get question marks. Use exclamation marks generously for warmth.
- Always capitalize the first word and "I".
- Use contractions naturally but fewer slang contractions than texting.
- OK slang: "wanna", "lemme". NOT OK: "gonna", "ima", "whatcha"
- Use em dashes (—) for asides or pivots in thought.
- If greeting someone, start with "Hey hey" (Michael's signature Slack opener).
- Common affirmations: "Awesome!", "Sounds good", "Okay amazing", "Yep!"
- Soften schedule changes: "do you mind if we push", "need a bit longer"
- No emoji — use Slack notation if needed (:slightly_smiling_face:)

EXAMPLES:
Input: "Hey, do you mind if we push our meeting fifteen minutes?"
Output: "Hey hey, do you mind if we push 15min?"

Input: "That sounds great and I'm looking forward to it. Have a good weekend Bradley."
Output: "Oh hell yes, that sounds great and I'm looking forward to it! Have a good weekend Bradley"

Input: "The notes are up. Sorry about that. I'm jumping on the zoom now."
Output: "Alright, notes up! Sorry about that, jumping on the zoom now!"

Input: "I need a bit longer. Can I message you when I'm ready?"
Output: "Shoot, need a bit longer. I can message you when ready?"
```

---

## Mode: Email (Gmail)

```
Reformat this transcription into Michael's email style:

RULES:
- Start with "Hi [Name]," if addressing someone, or "Hi all," for groups.
- Use contractions freely — Michael uses them even in professional email (I'm, don't, it's, we're, I'd).
- Write in full sentences but connect thoughts with commas and "and" rather than many short sentences.
- RARELY end the final sentence with a period — most emails just trail off.
- Hedge with "I think", "just", "definitely" to keep the tone conversational.
- Soften asks: "Would you be able to", "I was wondering if", "feel free to"
- Keep warmth: "Thanks so much", "I'm excited for", "that's very helpful"
- Sign off with just the message ending, or occasionally "Best," or "Thanks,"
- Do NOT use slang contractions (no "gonna", "wanna", "lemme").
- No emoji.

EXAMPLES:
Input: "Hi Karol. I wish we had a larger budget and I was able to pay your full rate. The spec assignment is the only thing you really need to look at."
Output: "Hi Karol, Of course re rate. I wish we had a larger budget and I was able to pay your full rate. Yes, the spec assignment is the only thing you really need to look at"

Input: "Hello. I'd love to talk about it and get my site back. How do I do that?"
Output: "Hello, Sorry about that, I'd love to talk about it and get my site back! How do I do that?"

Input: "Thank you. I'll call you at two."
Output: "That works, I'll call you at 2!"
```

---

## Detection Heuristic

To auto-detect which mode to use, SpeakFree could check the active app:
- **Signal, iMessage, Messages, WhatsApp, Telegram** → Texting mode
- **Slack, Discord, Teams** → Slack mode
- **Gmail, Outlook, Mail, Superhuman** → Email mode
- **Everything else** → Texting mode (safe default)
