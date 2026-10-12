const Color = @import("raylib").Color;
const builtin = @import("builtin");

pub fn htmlColor(comptime html: []const u8) Color {
    {
        const endian = comptime builtin.target.cpu.arch.endian();
        if (endian == .big) @compileError("No implementado para big endian");
    }

    comptime var i = 1;
    if (html[0] != '#')
        @compileError("Expected colors in the format #rrggbbaa, #rrggbb, #rgba or #rgb");

    const modes = enum {
        RRGGBBAA,
        RRGGBB,
        RGBA,
        RGB,
    };

    const mode: modes = switch (html.len) {
        9 => .RRGGBBAA,
        7 => .RRGGBB,
        5 => .RGBA,
        4 => .RGB,
        else => @compileError("Expected colors in the format #rrggbbaa, #rrggbb, #rgba or #rgb"),
    };

    comptime var r: u8 = 0;
    comptime var g: u8 = 0;
    comptime var b: u8 = 0;
    comptime var a: u8 = switch (mode) {
        .RGB, .RRGGBB => 0xff,
        .RGBA, .RRGGBBAA => 0,
    };

    inline while (i < html.len) : (i += 1) {
        const ch = html[i];
        switch (mode) {
            .RRGGBBAA => {
                switch (i) {
                    1 => r |= comptime hex_to_nibble(ch) << 4,
                    2 => r |= comptime hex_to_nibble(ch),
                    3 => g |= comptime hex_to_nibble(ch) << 4,
                    4 => g |= comptime hex_to_nibble(ch),
                    5 => b |= comptime hex_to_nibble(ch) << 4,
                    6 => b |= comptime hex_to_nibble(ch),
                    7 => a |= comptime hex_to_nibble(ch) << 4,
                    8 => a |= comptime hex_to_nibble(ch),
                    else => unreachable,
                }
            },
            .RRGGBB => {
                switch (i) {
                    1 => r |= comptime hex_to_nibble(ch) << 4,
                    2 => r |= comptime hex_to_nibble(ch),
                    3 => g |= comptime hex_to_nibble(ch) << 4,
                    4 => g |= comptime hex_to_nibble(ch),
                    5 => b |= comptime hex_to_nibble(ch) << 4,
                    6 => b |= comptime hex_to_nibble(ch),
                    else => unreachable,
                }
            },
            .RGBA => {
                switch (i) {
                    1 => {
                        const h = comptime hex_to_nibble(ch);
                        r |= h << 4;
                        r |= h;
                    },
                    2 => {
                        const h = comptime hex_to_nibble(ch);
                        g |= h << 4;
                        g |= h;
                    },
                    3 => {
                        const h = comptime hex_to_nibble(ch);
                        b |= h << 4;
                        b |= h;
                    },
                    4 => {
                        const h = comptime hex_to_nibble(ch);
                        a |= h << 4;
                        a |= h;
                    },
                    else => unreachable,
                }
            },
            .RGB => {
                switch (i) {
                    1 => {
                        const h = comptime hex_to_nibble(ch);
                        r |= h << 4;
                        r |= h;
                    },
                    2 => {
                        const h = comptime hex_to_nibble(ch);
                        g |= h << 4;
                        g |= h;
                    },
                    3 => {
                        const h = comptime hex_to_nibble(ch);
                        b |= h << 4;
                        b |= h;
                    },
                    else => unreachable,
                }
            },
        }
    }

    return .{ .r = r, .g = g, .b = b, .a = a };
}

fn hex_to_nibble(ch: u8) u8 {
    return switch (ch) {
        '0' => 0,
        '1' => 0x1,
        '2' => 0x2,
        '3' => 0x3,
        '4' => 0x4,
        '5' => 0x5,
        '6' => 0x6,
        '7' => 0x7,
        '8' => 0x8,
        '9' => 0x9,
        'a' => 0xa,
        'b' => 0xb,
        'c' => 0xc,
        'd' => 0xd,
        'e' => 0xe,
        'f' => 0xf,
        else => unreachable,
    };
}
