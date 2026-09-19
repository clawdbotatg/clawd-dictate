# Expectations

Austin's rules for dictation, in plain words. Every surface (phone keyboard,
Mac tool, harness mic) is held to these. If a change breaks one, it is a bug.

## Always listening

- Turn it on once. It stays on.
- On the phone: when a text box is under my cursor and the clawd keyboard is up, it is listening. No tap, no button, no waiting.
- I never have to open the clawd dictate app. One hop after a call, Siri, or a reinstall is the most iOS allows. A second hop for the same reason is a bug.
- "Listening" means words appear. A red dot with no words is a bug, not a state.

## One field, one dictation

- Every text box is its own namespace. Words I say into one chat never land in another.
- When I click into a different box, the old dictation ends there and a new one starts in the new box. Nothing is carried over.
- Enter / Return ALWAYS stops dictation, on every surface. It still sends the message.
- Phone: listening starts again when the keyboard comes up or the cursor lands in another box, or tap the dot. Mac: double-tap Control again.
- Typing by hand always wins. Dictation never deletes what I typed.

## Fast

- Words show up as I say them, within about a second. A ten-second gap is a bug.
- Nothing runs at the start of a dictation that could slow the first words down (no big downloads).

## Never breaks itself

- The Mac tool's permissions survive `git pull`. Nothing rebuilds the launcher.
- A phone install ships the code I was told it ships. Check the build date before installing.
- Every change gets tested by me on the phone before anyone calls it done.

## When it does break

- The phone writes `dictate.log` in the shared container. Pull it before guessing:

```
xcrun devicectl device copy from --device 8B053FBC-B638-548F-B045-F5DDE25D3BDD \
  --source Library/dictate.log --destination /tmp/dictate.log \
  --domain-type appGroupDataContainer --domain-identifier group.com.clawd.dictate
```

  "Failed to retrieve the file node" means the file does not exist: the phone
  runs a build older than 2026-09-18 18:30 (the log moved under `Library/`;
  a root-level file fails with "File paths cannot contain '..'" and cannot be
  pulled at all), or the app has not run since it was installed. Install the
  current build before anything else.
