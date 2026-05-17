pub const width: comptime_int = 5;

pub const Inner = extern struct {
    lo: u16,
    hi: u16,
};

pub const Payload = extern struct {
    items: [width]Inner,
    tail: u32,
};
