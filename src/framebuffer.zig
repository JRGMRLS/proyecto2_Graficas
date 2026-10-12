const std = @import("std");
const rl = @import("raylib");

/// Buffer de color en memoria de CPU. Los hilos de render escriben en
/// `pixels` (un arreglo de Zig, sin tocar Raylib); solo el hilo principal lo
/// sube a la GPU en `swap_buffers`.
pub const Framebuffer = struct {
    width: i32,
    height: i32,
    /// width * height colores, fila por fila (la fila 0 es la de arriba).
    pixels: []rl.Color,
    background_color: rl.Color,
    current_color: rl.Color,
    /// Textura de la GPU, creada una sola vez y actualizada cada cuadro.
    texture: ?rl.Texture = null,

    pub fn init(allocator: std.mem.Allocator, width: i32, height: i32, background_color: ?rl.Color, draw_color: ?rl.Color) !Framebuffer {
        const bg_color = background_color orelse rl.Color.black;
        const pixels = try allocator.alloc(rl.Color, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
        @memset(pixels, bg_color);
        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .background_color = bg_color,
            .current_color = draw_color orelse rl.Color.white,
        };
    }

    /// Debe llamarse desde el hilo principal (libera la textura de la GPU).
    pub fn deinit(self: *Framebuffer, allocator: std.mem.Allocator) void {
        if (self.texture) |t| rl.unloadTexture(t);
        allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn clear(self: *Framebuffer) void {
        @memset(self.pixels, self.background_color);
    }

    pub fn set_pixel(self: *Framebuffer, x: i32, y: i32) !void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return error.BadCoordinates;
        self.pixels[@as(usize, @intCast(y)) * @as(usize, @intCast(self.width)) + @as(usize, @intCast(x))] = self.current_color;
    }

    /// Las filas [y0, y1) como un slice propio: un hilo que reciba solo este
    /// slice no puede escribir fuera de su región.
    pub fn filas(self: *Framebuffer, y0: usize, y1: usize) []rl.Color {
        const w: usize = @intCast(self.width);
        return self.pixels[y0 * w .. y1 * w];
    }

    pub fn set_background_color(self: *Framebuffer, color: rl.Color) void {
        self.background_color = color;
    }

    pub fn set_current_color(self: *Framebuffer, color: rl.Color) void {
        self.current_color = color;
    }

    /// Vista Image de Raylib sobre `pixels` (no copia ni es dueña de la memoria).
    fn imagen(self: Framebuffer) rl.Image {
        return .{
            .data = @ptrCast(self.pixels.ptr),
            .width = self.width,
            .height = self.height,
            .mipmaps = 1,
            .format = .uncompressed_r8g8b8a8,
        };
    }

    pub fn render_to_file(self: Framebuffer, filename: [:0]const u8) !void {
        if (!self.imagen().exportToFile(filename)) return error.CouldntWriteFile;
    }

    /// Solo desde el hilo principal, con ningún hilo de render activo.
    /// `subir` indica que `pixels` cambió desde la última vez; si no, se
    /// vuelve a dibujar la textura que ya está en la GPU sin copiar nada.
    pub fn swap_buffers(self: *Framebuffer, subir: bool) !void {
        // Raylib maneja Image (RAM) y Texture (VRAM). La textura se crea una
        // vez y solo se copian los píxeles a la VRAM cuando hay imagen nueva.
        if (self.texture == null) self.texture = try rl.loadTextureFromImage(self.imagen());
        const texture = self.texture.?;
        if (subir) rl.updateTexture(texture, @ptrCast(self.pixels.ptr));

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.drawTexture(texture, 0, 0, .white);
    }
};
