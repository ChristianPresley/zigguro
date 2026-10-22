---
title: Showcase
tags: [markdown, zigguro]
---
# Markdown showcase

Text with *emphasis*, **strong**, `inline code`, ~~strike~~, a [link](https://example.com),
an autolink www.example.com and a [[Wiki Page|wikilink]]. Inline math: $e^{i\pi} + 1 = 0$.

## Lists

- First item
- Second item with **bold**
  - Nested item
- [ ] An open task
- [x] A finished task

1. One
2. Two
10. Ten

## Quotes and callouts

> A plain quote
> on two lines.

> [!NOTE]
> Notes are blue.

> [!TIP] A useful tip
> Tips are green.

> [!WARNING]
> Warnings are amber.

> [!DANGER]
> Danger is red.

## Code

```zig
const std = @import("std");

pub fn main() void {
    std.debug.print("hello\n", .{});
}
```

$$
\int_0^1 x^2 \, dx = \frac{1}{3}
$$

## Table

| Left | Center | Right |
|:-----|:------:|------:|
| a    | b      | c     |
| longer cell text | 2 | 3.5 |

---

![An image](image.png)
