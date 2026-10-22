pub fn countWords(text: []const u8) usize {
    var n: usize = 0;
    var in_word = false;
    for (text) |c| {
        const space = c == ' ' or c == '\n';
        if (!space and !in_word) n += 1;
        in_word = !space;
    }
    return n;
}
