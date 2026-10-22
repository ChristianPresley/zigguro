# Word movement

How the editor moves by word, subword and WORD. The rules live in
`packages/editor/src/model/edit/{movement.zig, word.zig, word_tailoring.zig}`.
Every row of the table below is a case in `movement_test.zig` (`word_stops`), so this page and the code agree.

## Classes

Each code point gets a class from its UAX #29 and General Category properties, tailored for code (UAX #29 §4.2.4):

- **ident**: letters, marks, digits, `_` (ExtendNumLet), plus the language's `word_chars`. Examples: `$` in JS/TS, `-` in CSS and HTML, `@` in Zig, `#` in C/C++.
- **punct**: punctuation and symbols. A run of them is one word, so `->`, `+=` and `!==` are single stops.
- **other**: CJK scripts (Han, Hiragana, Katakana, Hangul, Bopomofo), emoji (Extended_Pictographic), controls and invalid bytes. A run of the same class is one word.
- **space** and **newline**.

## Moves

- **Word right** (`cursor.wordRight`): an EOL is a stop of its own. Otherwise it skips whitespace and lands at the end of the next run (VS Code).
- **Word left** (`cursor.wordLeft`): an EOL is a stop of its own. Otherwise it skips whitespace and lands at the start of the previous run.
- **Subword** (`cursor.subwordLeft/Right`): stops inside identifiers at four kinds of boundary:
  - lower→Upper (`foo|Bar`);
  - Upper→Upper-lower (`HTTP|Server`);
  - letter↔digit (`utf|8`);
  - `_` and `-`, which are skipped like whitespace between subwords.
- **Word end** (Vim `e` / `ge`): ends of words, crossing blank lines.
- **WORD** (Vim `W` / `B`): runs of non-whitespace.
- **Delete word left** (`delete.wordLeft`): deletes from the caret to the word-left stop, so whitespace and the word before it go together.

## Stops

`¦` marks the caret. ⏎ is LF, ␍ is CR and → is a tab.

| Group | Unit | Direction | From | To | Language |
|---|---|---|---|---|---|
| code | word | forward | `¦const x = 1;` | `const¦ x = 1;` |  |
| code | word | forward | `const¦ x = 1;` | `const x¦ = 1;` |  |
| code | word | forward | `const x¦ = 1;` | `const x =¦ 1;` |  |
| code | word | forward | `const x = 1¦;` | `const x = 1;¦` |  |
| code | word | forward | `¦foo_bar.baz()` | `foo_bar¦.baz()` |  |
| code | word | forward | `foo_bar¦.baz()` | `foo_bar.¦baz()` |  |
| code | word | forward | `foo_bar.baz¦()` | `foo_bar.baz()¦` |  |
| code | word | forward | `a¦ -> b` | `a ->¦ b` |  |
| code | word | forward | `x¦ += 2` | `x +=¦ 2` |  |
| code | word | forward | `if (a¦ \|\| b)` | `if (a \|\|¦ b)` |  |
| code | word | forward | `¦0x1F + 3.5` | `0x1F¦ + 3.5` |  |
| code | word | forward | `0x1F + 3¦.5` | `0x1F + 3.¦5` |  |
| code | word | forward | `¦$scope.x` | `$¦scope.x` |  |
| code | word | forward | `¦$scope.x` | `$scope¦.x` | javascript |
| code | word | forward | `¦@import("std")` | `@¦import("std")` |  |
| code | word | forward | `¦@import("std")` | `@import¦("std")` | zig |
| code | word | forward | `¦margin-top: 0` | `margin-top¦: 0` | css |
| code | word | forward | `¦margin-top: 0` | `margin¦-top: 0` |  |
| code | word | backward | `const x = 1;¦` | `const x = 1¦;` |  |
| code | word | backward | `const x = 1¦;` | `const x = ¦1;` |  |
| code | word | backward | `const x ¦= 1;` | `const ¦x = 1;` |  |
| code | word | backward | `foo_bar.baz()¦` | `foo_bar.baz¦()` |  |
| code | word | backward | `foo_bar.baz¦()` | `foo_bar.¦baz()` |  |
| code | word | backward | `a ->¦ b` | `a ¦-> b` |  |
| code | word | backward | `    ¦x` | `¦    x` |  |
| whitespace and lines | word | forward | `a¦   ⏎b` | `a   ¦⏎b` |  |
| whitespace and lines | word | forward | `a   ¦⏎b` | `a   ⏎¦b` |  |
| whitespace and lines | word | forward | `a¦␍⏎b` | `a␍⏎¦b` |  |
| whitespace and lines | word | backward | `a⏎¦b` | `a¦⏎b` |  |
| whitespace and lines | word | backward | `a␍⏎¦b` | `a¦␍⏎b` |  |
| whitespace and lines | word | backward | `a⏎   ¦b` | `a⏎¦   b` |  |
| whitespace and lines | word | forward | `→¦→x y` | `→→x¦ y` |  |
| whitespace and lines | word | forward | `end¦` | `end¦` |  |
| whitespace and lines | word | backward | `¦start` | `¦start` |  |
| prose | word | forward | `¦Hello, world!` | `Hello¦, world!` |  |
| prose | word | forward | `Hello¦, world!` | `Hello,¦ world!` |  |
| prose | word | forward | `Hello, world¦!` | `Hello, world!¦` |  |
| prose | word | forward | `¦don't stop` | `don¦'t stop` |  |
| prose | word | forward | `¦naïve café` | `naïve¦ café` |  |
| prose | word | forward | `naïve¦ café` | `naïve café¦` |  |
| prose | word | backward | `naïve café¦` | `naïve ¦café` |  |
| prose | word | forward | `¦Straße—weiter` | `Straße¦—weiter` |  |
| prose | word | forward | `Straße¦—weiter` | `Straße—¦weiter` |  |
| prose | word | forward | `¦«quoted»` | `«¦quoted»` |  |
| prose | word | forward | `¦été` | `été¦` |  |
| CJK | word | forward | `¦中文字 abc` | `中文字¦ abc` |  |
| CJK | word | forward | `¦日本語テキスト` | `日本語テキスト¦` |  |
| CJK | word | forward | `¦한국어 단어` | `한국어¦ 단어` |  |
| CJK | word | forward | `¦abc中文` | `abc¦中文` |  |
| CJK | word | backward | `abc中文¦` | `abc¦中文` |  |
| CJK | word | forward | `¦中文，好` | `中文¦，好` |  |
| CJK | word | forward | `中文¦，好` | `中文，¦好` |  |
| emoji | word | forward | `¦👍👍 ok` | `👍👍¦ ok` |  |
| emoji | word | forward | `¦ok👍` | `ok¦👍` |  |
| emoji | word | forward | `¦👨‍👩‍👧 x` | `👨‍👩‍👧¦ x` |  |
| emoji | word | backward | `a 🎉🎉¦` | `a ¦🎉🎉` |  |
| Arabic and Hebrew | word | forward | `¦مرحبا بالعالم` | `مرحبا¦ بالعالم` |  |
| Arabic and Hebrew | word | backward | `مرحبا بالعالم¦` | `مرحبا ¦بالعالم` |  |
| Arabic and Hebrew | word | forward | `¦שלום עולם` | `שלום¦ עולם` |  |
| mixed punctuation | word | forward | `¦...rest` | `...¦rest` |  |
| mixed punctuation | word | forward | `x¦ !== y` | `x !==¦ y` |  |
| mixed punctuation | word | forward | `¦/* note */` | `/*¦ note */` |  |
| mixed punctuation | word | backward | `a::<T>()¦` | `a::<T¦>()` |  |
| mixed punctuation | word | forward | `path¦/to/file.zig` | `path/¦to/file.zig` |  |
| mixed punctuation | word | forward | `¦#include <x>` | `#¦include <x>` |  |
| mixed punctuation | word | forward | `¦#include <x>` | `#include¦ <x>` | c |
| Vim word ends and WORDs | word_end | forward | `¦foo bar` | `foo¦ bar` |  |
| Vim word ends and WORDs | word_end | forward | `fo¦o bar` | `foo bar¦` |  |
| Vim word ends and WORDs | word_end | forward | `foo¦⏎⏎  bar` | `foo⏎⏎  bar¦` |  |
| Vim word ends and WORDs | word_end | backward | `foo bar¦` | `foo¦ bar` |  |
| Vim word ends and WORDs | word_end | backward | `foo.ba¦r` | `foo.¦bar` |  |
| Vim word ends and WORDs | whitespace_word | forward | `¦a.b(c) next` | `a.b(c) ¦next` |  |
| Vim word ends and WORDs | whitespace_word | backward | `a.b(c) ne¦xt` | `a.b(c) ¦next` |  |
| Vim word ends and WORDs | whitespace_word | backward | `a.b(c) ¦next` | `¦a.b(c) next` |  |
