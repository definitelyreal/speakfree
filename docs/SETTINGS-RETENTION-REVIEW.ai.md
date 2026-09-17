<!-- ai-suggestion:unverified | session:01a0a336-fe39-7870-bdab-33c820f98955 | date:2026-09-15 | asof:2026-09-15 -->
# Settings and recordings review

## September 17 correction: match the other buttons' shape

Michael rejected the large control's capsule shape. The shared folder button now
uses the same regular native rounded-rectangle bezel as its neighbors, with 4-point
label insets preserving its full size and the yellow Apple folder symbol. The three
native render tests passed again, including the minimum-height assertion; captures
are in `build/release-readiness/2026-09-17-folder-button-rectangular`. This correction
is being shown in the inert review before another installed-app update.

## September 17: full-size yellow folder button

Michael requested a full-size folder button with a yellow Apple folder icon. The
shared Settings/notice control now explicitly uses the native large bordered button
and Apple's `folder.fill` symbol in system yellow. Its title, folder-opening action,
tooltip, accessibility identifier and alignment are unchanged; the icon is decorative
for accessibility. No recording or retention behavior changed.

Three native render tests passed, generating 22 images in
`build/release-readiness/2026-09-17-folder-button`. A follow-up size assertion passed
for both font profiles, enforcing a minimum 30-point control height. The release
build passed in 35.31 seconds; changed-file SwiftLint and whitespace checks passed.
BODY20 still tests inherited text styling, not actual system Larger Text settings.
These are implementation/render checks, not human visual approval.

Scoped code review found no actionable blocker. Build `68614fe` was installed by the
guarded fleet script on Noah (PID 21192) and Studio (PID 80583), with matching build
stamps re-read afterward. Ark's visible-console guard blocked its stop; it remains on
`ecee961` (PID 84976). Do not describe this as a completed fleet update. Previous
Noah/Studio bundles remain recoverable from Trash. Deployment receipt:
`build/release-readiness/2026-09-17-folder-button-deploy.log`.

A refreshed inert preview is open from
`build/recordings-folder-review.uIIn10/SpeakFree Folder Button Review.app`, using the
existing saved wording draft via `SPEAKFREE_REVIEW_DRAFT`. Its window/controls were
inspected through native accessibility and a screenshot; old review drafts/windows
were not deleted. The preview cannot move actual recordings.

## September 15 review

This is design feedback and a test record, not release approval. Three fresh-context reviewers challenged consent, settings clarity, and layout/accessibility. Their findings were source reviews, not independent visual approval or a cross-family verification gate.

## Overall recommendation

Keep one scrolling settings page for this iteration. Shared columns and consistent controls make the current sections much easier to scan. If the page grows, use General / Transcription / Advanced tabs; a sidebar would be unnecessary for this number of categories. My preferred notice variant is a bold “Your choice” heading and a left-aligned folder button: the heading establishes the decision area and the button stays connected to the prose.

## Every setting

| Setting | Clarity and placement | Current change or recommendation |
|---|---|---|
| Usage totals | Useful at the top; lifetime activity is different from currently retained recordings. | Keep both lines. Miles now always use one decimal, including 0.0. Typing time and distance remain estimates; the tooltip should eventually state the assumptions. |
| Launch at Login | Familiar and belongs first. | Its checkbox now starts at the same control column as the dropdowns. |
| Hotkey / Hold–Toggle | Appropriate in General. | Native regular-size controls; consider a short “Hold to speak / tap to start and stop” helper for new users. |
| Microphone | Correctly near the hotkey. | Shorter automatic-routing explanation; the AirPods-rest sentence fits on one line at the normal width. Pinned-device copy no longer describes automatic routing. |
| Keep Recordings & Transcripts | The longer label is clearer and fits at normal size. | Shared label/picker and mappings in Settings and the notice. Keep All, Keep None, Last 1,000, Last 10,000. At 20-point body text the label wraps while the control column stays aligned. |
| Recordings folder / Your corpus | Together these explain what exists on disk. | Shared folder button underneath, aligned with controls; corpus count centered and comma-formatted. Existing files and future saving are explicitly different. |
| Engine | Belongs first in Transcription. | Wider intrinsic picker and shared column fix the Whisper alignment. Recommendation: identify both engines as local and make clear that NVIDIA is the model creator, not a required GPU. |
| Parakeet model | Appropriate directly under Engine. | No repeated model title beneath the picker; green “Downloaded and ready.” Download failure text, hidden progress, and stale callbacks were repaired by source review. Real download lifecycle still needs exercise. |
| Language | Useful only for engines/models that offer a meaningful choice. | English-only Parakeet hides it. Remaining issue: the language catalog is described as representative but used as exhaustive, and engine switching can replace a prior Whisper language with Auto. Fix before claiming polished multilingual support. |
| Whisper model | Correctly in Transcription and hidden for Parakeet. | Wider control. Download-size/status distinction is useful; selected-model readiness should eventually use the same compact treatment as Parakeet. |
| Punctuation | The three choices need one explanation, not paragraphs. | One-line helper explaining automatic punctuation and spoken commands. Whisper-only Spoken Only stays engine-specific. |
| Vocabulary | Better here than in a separate section. | “📝 Edit Vocabulary File,” label Vocabulary, one-line helper, count says entries rather than words. |
| Pre-listening | Function makes sense but is conceptually tied to Microphone. | Aligned with every other row. Recommendation: move it below Microphone later; this would remove an almost-empty Performance section for Parakeet. |
| Model Loading | Meaningful for Whisper, misleading for Parakeet. | Hidden for Parakeet. Removed unsupported Off as a new choice; existing Off configs are honestly shown as legacy Automatic. Static loading times now say “Estimated,” not “on your Mac.” |
| Diagnostic Logging | Appropriate in Advanced. | Label, checkbox, helper, and folder button aligned. |
| Live Preview | Experimental and engine-dependent. | Hidden for Parakeet; kept in Advanced for Whisper. |
| Local Transcription API | Advanced is the right place. | Plain-language explanation first, endpoint second. Experimental status remains explicit. |
| Screen Context | Appropriate as an Advanced opt-in. | Different explanations for Whisper vocabulary hints versus Parakeet spelling corrections, including the relevant error risk. |
| Attribution / footer | Secondary information, after controls. | Parakeet credit above the regular-sized vibe-coded footer. |

## Consent and retention findings addressed

- The old backend silently clamped both large limits to 100. Positive limits now keep their actual values, with regression tests.
- Selecting None clears a previous cap. Startup and finalization do not prune under None; developer mode remains an explicit Keep All override.
- Merely opening, changing, or closing the legacy notice does not persist the proposed selection.
- Confirming Move saves the future-saving choice first. If preference persistence fails, no move starts; if moving fails, the saved None preference is not silently reverted.
- Settings reports save failure and does not call the reload callback as though saving succeeded.
- Silent capture failures honor None rather than retaining diagnostic audio against the preference.
- Finalization rereads current retention after inference, on both success and failure, rather than pruning using a superseded pre-inference snapshot.
- Restore changes the file outcome without opting the user back into future saving.
- Confirmation counts are refreshed when opening the sheet; the primary unit is recordings with artifact files in parentheses.

Automatic Last N pruning is still permanent deletion, unlike the explicit Trash action. The picker helper now discloses this. I recommend a recoverable retention workflow as a separate follow-up, with capacity and conflict handling tested before replacing the current backend.

## Keyboard behavior

The notice’s quiet action uses native focus rather than a Return default: Space activates the focused control and Tab can move focus. The actual Trash confirmation assigns Return to Cancel and handles Escape as Cancel; Move to Trash is not the default action. This is a deliberate conservative choice for a large batch operation. Apple distinguishes keyboard focus from default-button activation; Space is not intrinsically a Cancel shortcut. See [Apple’s keyboard navigation guide](https://support.apple.com/en-gb/guide/mac-help/mchlc06d1059/mac).

## Validation and limits

- Debug build completed; the focused functional run passed 96 tests, with 5 opt-in snapshot tests skipped in that run.
- After the native focus-button refinement, 44 focused tests passed again. In the inert running app, Space activated Keep, selecting None changed the action label, Space opened the confirmation, Return dismissed it without moving, and Escape also dismissed it. The native focus ring was visible on Keep afterward.
- The separate snapshot run passed all 5 render tests and generated 46 images: six notice comparisons, both engines/full views/viewports, confirmation alignment, progress, success, and failure/restore states.
- BODY20 explicitly applies a 20-point inherited font. It increases the notice from 573 to 845 points high. Explicitly styled headings, captions, and native controls keep their own fonts. This is **not** proof of actual macOS Larger Text behavior across every OS setting.
- Source and representative pixel inspection do not establish VoiceOver behavior, atomicity while preferences change during filesystem mutation, real download cancellation/retry behavior, or a fresh real Finder Put Back round trip.
- Snapshot results are in `build/release-readiness/2026-09-15-native-ui-captures-final`. The expanded full-settings captures intentionally include empty viewport space below the content; actual viewport captures are included separately.
- Installed Speakfree was not replaced during this review. The review app is inert and uses a separate scratch directory. No current claim is made that ongoing new dictations are included in the earlier backup snapshot.
- Only rebuildable pip, Swift-package, and Xcode build products were cleaned to regain the configured disk floor. No recordings or backup archives were removed; these caches return on download/rebuild.

## Slower appearance observation

At about 04:25 local time, a short system sample showed 59–69% aggregate CPU idle on 16 logical CPUs. WindowServer and several background apps were active; the installed Speakfree process was around 0.3% CPU in the process sample. Builds/rendering were idle at that moment. These observations do not identify the cause of an individual delayed dictation; distinguish text-insertion latency from dialog-opening latency before drawing a conclusion.
