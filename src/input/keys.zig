const xkb = @import("xkbcommon");

// Packed, it is important TODO
pub const ModMask = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
};

// The dictionary key for our hash map
pub const Keybind = struct {
    state: u32,
    modifiers: ModMask,
    keysym: xkb.Keysym,
};

pub const BindAction = union(enum) {
    next_state: u32,
    exec_lua: i32,
};
