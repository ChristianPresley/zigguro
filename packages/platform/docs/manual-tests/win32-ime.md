# Manual test: Win32 IME (E01.F02.S03.T01)

IMEs cannot be driven reliably in CI, so run this checklist on real Windows
10 or 11 for any change to `packages/platform/src/win32/ime.zig` or to the
IME paths in `win32/backend.zig`. Use a text field that reports its caret
with `set_ime_state` and draws `ime_preedit`.

Run each block at 100%, 150% and 200% display scale.

## Setup

- [ ] Add the input methods in Settings > Time & language > Language &
  region: Japanese (Microsoft IME), Chinese Simplified (Microsoft
  Pinyin), Korean (Microsoft IME) and Vietnamese (Telex).
- [ ] Start `zigguro` and focus a text field. Switch input methods with
  Win+Space.

## Japanese (Microsoft IME)

- [ ] Type `nihongo`: the underlined preedit "にほんご" appears inline at
  the caret, with no separate composition window.
- [ ] Press Space: the converted clause is highlighted (the selected
  clause range), and the candidate list opens below the caret line
  without covering it.
- [ ] Press Enter: "日本語" is inserted once (no double insertion) and the
  preedit disappears.
- [ ] Start a composition, then click elsewhere in the text: the
  composition is committed, not lost.
- [ ] Type in a password field: the IME stays off.

## Chinese (Microsoft Pinyin)

- [ ] Type `zhongwen`: the pinyin preedit shows inline, candidates below.
- [ ] Press 1: "中文" is inserted once.
- [ ] Press Esc during a composition: the preedit is cleared and nothing
  is inserted.

## Korean (Microsoft IME)

- [ ] Type `gksrmf` (한글): each syllable composes inline and commits
  when the next one starts; the final syllable commits on Space.
- [ ] Hanja conversion (the Hanja key or right Ctrl) opens the candidate
  list below the caret line.

## Vietnamese (Telex)

- [ ] Type `tieesng vieejt`: "tiếng việt" is inserted, with no stray
  letters from the Telex keys.

## Keys while composing

- [ ] Arrow keys and Backspace during a composition edit the preedit and
  do not reach the editor as key events.
- [ ] After the composition ends, the same keys reach the editor again.
