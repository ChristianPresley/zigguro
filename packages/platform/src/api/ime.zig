//! Input method (IME) state the app reports to the platform.

/// The kind of text being edited; IMEs use it to pick a layout or disable
/// themselves (`password`, `terminal`).
pub const ImePurpose = enum(u8) {
    /// Free text.
    normal,
    /// Letters only.
    alpha,
    /// Digits only.
    digits,
    /// A number, possibly with sign and separators.
    number,
    /// A phone number.
    phone,
    /// A URL.
    url,
    /// An email address.
    email,
    /// A person's name.
    name,
    /// A password; IMEs must not learn or show it.
    password,
    /// A numeric PIN.
    pin,
    /// A date.
    date,
    /// A time.
    time,
    /// A date and time.
    datetime,
    /// A terminal; IMEs should avoid auto-correction.
    terminal,
};

/// Text around the caret, so an IME can offer context-aware candidates and
/// emit `Event.ime_delete_surrounding`. Offsets are bytes into `text`.
pub const Surrounding = struct {
    /// UTF-8 text around the caret; backends may truncate it to the
    /// protocol limit (4000 bytes on text-input-v3).
    text: []const u8,
    /// Caret position.
    cursor_byte: u32,
    /// Selection anchor; equal to `cursor_byte` when nothing is selected.
    anchor_byte: u32,
};
