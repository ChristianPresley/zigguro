# Wayland IME (E01.F04.S03.T01)

Run on GNOME (Mutter), KDE Plasma (KWin) and Sway, with zigguro on
Wayland (`ZG_PLATFORM=wayland`). Repeat with fcitx5 (Pinyin, then Mozc)
and with IBus (Anthy or libpinyin).

- [ ] Type Pinyin in the editor: the preedit shows inline, underlined,
      with its cursor; choosing a candidate inserts it and ends the
      preedit.
- [ ] The candidate window sits under the caret, and follows it while
      the view scrolls and when the window moves to a monitor with a
      different scale.
- [ ] Mozc: convert a phrase, then move between clauses with the arrow
      keys; the selected clause is highlighted.
- [ ] Reconversion or correction that deletes text before the caret
      (fcitx5 Pinyin backspace into a committed word, IBus surrounding
      text) removes the right characters, including non-ASCII ones.
- [ ] Click elsewhere in the text during a preedit: the preedit ends
      and the IME sees the new surrounding text.
- [ ] Focus a password field: the IME switches off or shows no
      suggestions, and nothing typed is learned.
- [ ] In the terminal panel, the IME commits to the shell and offers no
      auto-correction.
- [ ] Switch to another application mid-preedit and back: the preedit
      is gone and typing works.
- [ ] Shortcuts (Ctrl+S, Ctrl+Shift+P) still work while the IME is
      enabled but not composing.
