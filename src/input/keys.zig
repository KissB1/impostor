const xkb = @import("xkbcommon");

// Packed it is important TODO
pub const ModMask = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
};

// The dictionary key for our hash map
pub const Keybind = struct {
    modifiers: ModMask,
    keysym: xkb.Keysym,
};
