const std = @import("std");
const rl = @import("raylib");
const Vec3 = @import("vec.zig").Vec3;
const Vec2 = @import("vec.zig").Vec2;
const V3FromColor = @import("raytracer.zig").V3FromColor;

/// Textura guardada en memoria de CPU.
///
/// Los píxeles se guardan ya convertidos a Vec3 (rgb en 0..1) para que
/// el muestreo dentro de cast_ray no tenga que convertir ni asignar memoria.
/// La fila 0 es la fila superior de la imagen.
///
/// La textura es dueña de su memoria: se crea con `init` o `fromImage` y se
/// libera con `deinit` usando el mismo allocator.
pub const Texture = struct {
    width: usize,
    height: usize,
    pixels: []Vec3,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize, fill: Vec3) !Texture {
        if (width == 0 or height == 0) return error.InvalidTextureSize;
        const count = std.math.mul(usize, width, height) catch return error.InvalidTextureSize;
        const pixels = try allocator.alloc(Vec3, count);
        @memset(pixels, fill);
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    /// Copia una rl.Image (por ejemplo, generada con rl.genImage*) a memoria propia.
    pub fn fromImage(allocator: std.mem.Allocator, image: rl.Image) !Texture {
        if (image.width <= 0 or image.height <= 0) return error.InvalidTextureSize;
        const width: usize = @intCast(image.width);
        const height: usize = @intCast(image.height);

        const colors = try rl.loadImageColors(image);
        defer rl.unloadImageColors(colors);
        if (colors.len < width * height) return error.InvalidTextureSize;

        const texture = try init(allocator, width, height, .zero());
        for (texture.pixels, colors[0..texture.pixels.len]) |*dst, src| {
            dst.* = V3FromColor(src);
        }
        return texture;
    }

    pub fn deinit(self: *Texture, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }

    /// Escritura con límites comprobados; fuera de rango no hace nada.
    pub fn setPixel(self: *Texture, x: usize, y: usize, color: Vec3) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[y * self.width + x] = color;
    }

    /// Lectura con límites comprobados; fuera de rango se ajusta al borde.
    pub fn getPixel(self: Texture, x: usize, y: usize) Vec3 {
        const cx = @min(x, self.width - 1);
        const cy = @min(y, self.height - 1);
        return self.pixels[cy * self.width + cx];
    }

    /// Muestreo por vecino más cercano (conserva el pixel-art nítido).
    /// `uv` fuera de [0, 1) se repite: solo se usa la parte fraccionaria.
    /// v = 0 es el borde inferior de la imagen y v = 1 el superior.
    pub fn sample(self: Texture, uv: Vec2) Vec3 {
        if (!std.math.isFinite(uv.x) or !std.math.isFinite(uv.y)) return self.pixels[0];

        const u = uv.x - @floor(uv.x);
        const v = uv.y - @floor(uv.y);

        const w: f32 = @floatFromInt(self.width);
        const h: f32 = @floatFromInt(self.height);

        // @min protege el caso en que el redondeo de u o v de exactamente 1.0.
        const x: usize = @min(self.width - 1, @as(usize, @intFromFloat(u * w)));
        const y: usize = @min(self.height - 1, @as(usize, @intFromFloat((1 - v) * h)));
        return self.pixels[y * self.width + x];
    }

    /// Muestreo bilineal que se ajusta al borde en vez de repetirse.
    /// Lo usa el skybox: cada cara es una imagen aparte y repetirla haría
    /// que el borde izquierdo se mezclara con el derecho (costura visible).
    /// Misma convención que `sample`: v = 0 abajo, v = 1 arriba.
    pub fn sampleBilineal(self: Texture, uv: Vec2) Vec3 {
        if (!std.math.isFinite(uv.x) or !std.math.isFinite(uv.y)) return self.pixels[0];

        const w: f32 = @floatFromInt(self.width);
        const h: f32 = @floatFromInt(self.height);

        // Posición continua medida desde el centro del píxel (0, 0).
        const fx = std.math.clamp(uv.x * w - 0.5, 0, w - 1);
        const fy = std.math.clamp((1 - uv.y) * h - 0.5, 0, h - 1);

        const x0: usize = @intFromFloat(fx);
        const y0: usize = @intFromFloat(fy);
        const x1 = @min(x0 + 1, self.width - 1);
        const y1 = @min(y0 + 1, self.height - 1);
        const tx = fx - @as(f32, @floatFromInt(x0));
        const ty = fy - @as(f32, @floatFromInt(y0));

        const arriba = mezclar(self.getPixel(x0, y0), self.getPixel(x1, y0), tx);
        const abajo = mezclar(self.getPixel(x0, y1), self.getPixel(x1, y1), tx);
        return mezclar(arriba, abajo, ty);
    }
};

/// Interpolación lineal entre dos colores: a·(1 - t) + b·t.
pub fn mezclar(a: Vec3, b: Vec3, t: f32) Vec3 {
    return .{
        .x = a.x + (b.x - a.x) * t,
        .y = a.y + (b.y - a.y) * t,
        .z = a.z + (b.z - a.z) * t,
    };
}

// ---------------------------------------------------------------------------
// Texturas pixel-art procedurales (solo Zig).
// ---------------------------------------------------------------------------

fn rgb(comptime r: u8, comptime g: u8, comptime b: u8) Vec3 {
    return .{
        .x = @as(f32, r) / 255.0,
        .y = @as(f32, g) / 255.0,
        .z = @as(f32, b) / 255.0,
    };
}

/// Hash entero determinista para variar el tono de cada píxel sin usar aleatorios.
fn hash(x: usize, y: usize, seed: u32) u32 {
    var h: u32 = @truncate(x *% 374761393 +% y *% 668265263);
    h +%= seed *% 2246822519;
    h = (h ^ (h >> 13)) *% 1274126177;
    return h ^ (h >> 16);
}

/// Ladrillos de 16x16: filas de 4 px, ladrillos de 8 px desfasados
/// en filas alternas, con juntas de mortero y variación de tono.
pub fn ladrillos(allocator: std.mem.Allocator) !Texture {
    const size = 16;
    const mortero = rgb(0xc8, 0xc0, 0xb4);
    const tonos = [_]Vec3{
        rgb(0xa8, 0x44, 0x32),
        rgb(0x96, 0x3c, 0x2c),
        rgb(0xb8, 0x52, 0x3c),
    };

    var tex = try Texture.init(allocator, size, size, mortero);
    for (0..size) |y| {
        const fila = y / 4;
        const desfase: usize = if (fila % 2 == 0) 0 else 4;
        for (0..size) |x| {
            const es_junta_h = y % 4 == 3;
            const es_junta_v = (x + desfase) % 8 == 7;
            if (es_junta_h or es_junta_v) continue;

            const ladrillo = (x + desfase) / 8 + fila * 3;
            var color = tonos[hash(ladrillo, fila, 7) % tonos.len];
            // Algunos píxeles un poco más oscuros para dar textura.
            if (hash(x, y, 1) % 5 == 0) color = color.scale(0.85);
            tex.setPixel(x, y, color);
        }
    }
    return tex;
}

/// Textura de orientación de 16x16: tablero de 2 colores con una "F"
/// en el centro. La F no es simétrica ni horizontal ni verticalmente,
/// así que una cara espejeada o rotada se nota de inmediato.
/// Además la esquina superior izquierda es roja (u = 0, v = 1) y la
/// inferior derecha verde (u = 1, v = 0).
pub fn orientacion(allocator: std.mem.Allocator) !Texture {
    const size = 16;
    const claro = rgb(0xe8, 0xe0, 0xc8);
    const oscuro = rgb(0xc0, 0xb4, 0x98);
    const tinta = rgb(0x28, 0x30, 0x60);

    var tex = try Texture.init(allocator, size, size, claro);
    for (0..size) |y| {
        for (0..size) |x| {
            if ((x / 2 + y / 2) % 2 == 1) tex.setPixel(x, y, oscuro);
        }
    }

    // Letra F: 8 px de alto, trazo de 2 px.
    const f = [_][]const u8{
        "#######",
        "#######",
        "##.....",
        "#####..",
        "#####..",
        "##.....",
        "##.....",
        "##.....",
    };
    for (f, 0..) |fila, dy| {
        for (fila, 0..) |c, dx| {
            if (c == '#') tex.setPixel(5 + dx, 4 + dy, tinta);
        }
    }

    // Marcadores de esquina de 3x3.
    for (0..3) |dy| {
        for (0..3) |dx| {
            tex.setPixel(dx, dy, rgb(0xe0, 0x30, 0x30));
            tex.setPixel(size - 3 + dx, size - 3 + dy, rgb(0x30, 0xb0, 0x40));
        }
    }
    return tex;
}

// ---------------------------------------------------------------------------
// Texturas del diorama. Cada una es una función pura (x, y) -> color sobre
// una cuadrícula de 16x16; `generar` la convierte en una Texture.
// ---------------------------------------------------------------------------

pub const lado_pixelart = 16;

pub fn generar(allocator: std.mem.Allocator, comptime pixel: fn (usize, usize) Vec3) !Texture {
    var tex = try Texture.init(allocator, lado_pixelart, lado_pixelart, .zero());
    for (0..lado_pixelart) |y| {
        for (0..lado_pixelart) |x| {
            tex.setPixel(x, y, pixel(x, y));
        }
    }
    return tex;
}

/// Escala el brillo de un color sin llamar a Raylib (limitado a 1).
fn tono(c: Vec3, k: f32) Vec3 {
    return .{ .x = @min(1, c.x * k), .y = @min(1, c.y * k), .z = @min(1, c.z * k) };
}

pub const pixelart = struct {
    fn verdeCesped(x: usize, y: usize) Vec3 {
        const n = hash(x, y, 11) % 100;
        const c = if (n < 30)
            rgb(0x5a, 0x9e, 0x3c)
        else if (n < 68)
            rgb(0x4c, 0x8c, 0x32)
        else if (n < 90)
            rgb(0x68, 0xae, 0x44)
        else
            rgb(0x3e, 0x78, 0x2a);
        // Manchas de 2x2 algo más oscuras para romper la uniformidad.
        return if (hash(x / 2, y / 2, 12) % 5 == 0) tono(c, 0.88) else c;
    }

    /// Césped visto desde arriba, con algunas flores amarillas y blancas.
    pub fn cespedArriba(x: usize, y: usize) Vec3 {
        const f = hash(x, y, 97);
        if (f % 53 == 0) return rgb(0xf2, 0xd6, 0x4e);
        if (f % 59 == 1) return rgb(0xf4, 0xf0, 0xe6);
        return verdeCesped(x, y);
    }

    /// Costado de un bloque de césped: franja verde irregular arriba y tierra abajo.
    pub fn cespedLado(x: usize, y: usize) Vec3 {
        const borde = 2 + hash(x, 0, 5) % 3;
        if (y < borde) return verdeCesped(x, y);
        if (y == borde) return rgb(0x5e, 0x6a, 0x2e);
        const n = hash(x, y, 6) % 100;
        if (n < 4) return rgb(0x9c, 0x94, 0x8a);
        return if (n < 40)
            rgb(0x8a, 0x5e, 0x3c)
        else if (n < 75)
            rgb(0x7a, 0x52, 0x34)
        else
            rgb(0x96, 0x6a, 0x44);
    }

    /// Roca gris con grietas y zonas de 4x4 con distinto brillo.
    pub fn piedra(x: usize, y: usize) Vec3 {
        const grieta = (y == 5 and x >= 1 and x <= 6) or
            (x == 6 and y >= 5 and y <= 9) or
            (y == 12 and x >= 9 and x <= 14) or
            (x == 9 and y >= 9 and y <= 12) or
            (y == 2 and x >= 11 and x <= 13);
        if (grieta) return rgb(0x56, 0x56, 0x5c);

        const n = hash(x, y, 21) % 100;
        const c = if (n < 40)
            rgb(0x8c, 0x8c, 0x92)
        else if (n < 75)
            rgb(0x7c, 0x7c, 0x82)
        else if (n < 93)
            rgb(0x9e, 0x9e, 0xa4)
        else
            rgb(0x6a, 0x6a, 0x70);
        const k: f32 = switch (hash(x / 4, y / 4, 22) % 3) {
            0 => 0.92,
            1 => 1.0,
            else => 1.06,
        };
        return tono(c, k);
    }

    /// Adoquines claros de 3x3 con junta oscura, en filas desfasadas.
    pub fn adoquin(x: usize, y: usize) Vec3 {
        const fila = y / 4;
        const xs = x + (fila % 2) * 2;
        const cx = xs % 4;
        const cy = y % 4;
        if (cx == 3 or cy == 3) return rgb(0x5c, 0x58, 0x50);
        const c = switch (hash(xs / 4, fila, 71) % 3) {
            0 => rgb(0xae, 0xa8, 0x98),
            1 => rgb(0x9a, 0x94, 0x86),
            else => rgb(0xbc, 0xb4, 0xa2),
        };
        if (cx == 0 and cy == 0) return tono(c, 1.12);
        if (cx == 2 or cy == 2) return tono(c, 0.88);
        return c;
    }

    /// Tablas horizontales de 3 px con juntas, clavos y vetas.
    pub fn madera(x: usize, y: usize) Vec3 {
        const junta_color = rgb(0x5a, 0x3a, 0x22);
        const tabla = y / 4;
        if (y % 4 == 3) return junta_color;
        const junta = (tabla * 7 + 3) % 16;
        if (x == junta) return junta_color;
        if (y % 4 == 1 and (x == (junta + 1) % 16 or (x + 1) % 16 == junta))
            return rgb(0x3c, 0x34, 0x30);
        const tonos = [_]Vec3{
            rgb(0xb0, 0x7a, 0x48),
            rgb(0xa2, 0x6e, 0x40),
            rgb(0xba, 0x84, 0x50),
            rgb(0x9c, 0x68, 0x3c),
        };
        const c = tonos[tabla % tonos.len];
        return if (hash(x / 3, y, 31) % 4 == 0) tono(c, 0.9) else c;
    }

    /// Corteza: franjas verticales cafés con surcos oscuros.
    pub fn corteza(x: usize, y: usize) Vec3 {
        const surco = rgb(0x3e, 0x2a, 0x1a);
        if (x % 4 == 0 and hash(x, y / 2, 42) % 4 != 0) return surco;
        if (hash(x, y / 3, 44) % 11 == 0) return surco;
        const tonos = [_]Vec3{
            rgb(0x6e, 0x4a, 0x2c),
            rgb(0x7c, 0x56, 0x34),
            rgb(0x62, 0x42, 0x28),
        };
        return tonos[(hash(x, 0, 41) + hash(x, y, 43) % 2) % tonos.len];
    }

    /// Follaje: verdes en racimos de 2x2 con brillos sueltos.
    pub fn hojas(x: usize, y: usize) Vec3 {
        const n = hash(x, y, 53) % 100;
        const c = if (n < 35)
            rgb(0x2e, 0x6a, 0x2a)
        else if (n < 72)
            rgb(0x3c, 0x82, 0x34)
        else if (n < 94)
            rgb(0x52, 0x9a, 0x42)
        else
            rgb(0x6e, 0xb4, 0x52);
        return if (hash(x / 2, y / 2, 51) % 4 == 0) tono(c, 0.8) else c;
    }

    /// Tejas de barro de 8x4, desfasadas por fila, con sombra inferior.
    pub fn tejas(x: usize, y: usize) Vec3 {
        const fila = y / 4;
        const xs = x + (fila % 2) * 4;
        const cx = xs % 8;
        const cy = y % 4;
        if (cy == 3) return rgb(0x6e, 0x2a, 0x1c);
        const c = switch (hash(xs / 8, fila, 81) % 3) {
            0 => rgb(0xb8, 0x4e, 0x30),
            1 => rgb(0xa6, 0x44, 0x2a),
            else => rgb(0xc4, 0x5a, 0x38),
        };
        if (cx == 7) return tono(c, 0.78);
        if (cy == 0) return tono(c, 1.12);
        return c;
    }

    /// Placa de acero cepillado con bisel, remaches y un brillo diagonal.
    pub fn metal(x: usize, y: usize) Vec3 {
        if (x == 0 or y == 0) return rgb(0xe2, 0xe6, 0xea);
        if (x == 15 or y == 15) return rgb(0x6c, 0x70, 0x78);
        if ((x == 2 or x == 13) and (y == 2 or y == 13)) return rgb(0x7a, 0x7e, 0x86);
        if (x + y >= 12 and x + y <= 14) return rgb(0xd8, 0xdc, 0xe2);
        const c = switch (hash(0, y, 61) % 3) {
            0 => rgb(0xb4, 0xb8, 0xbe),
            1 => rgb(0xa4, 0xa8, 0xb0),
            else => rgb(0xc4, 0xc8, 0xcc),
        };
        return if (hash(x, y, 62) % 7 == 0) tono(c, 0.95) else c;
    }

    /// Vidrio turquesa con marco oscuro y dos reflejos diagonales.
    pub fn vidrio(x: usize, y: usize) Vec3 {
        if (x == 0 or x == 15 or y == 0 or y == 15) return rgb(0x2e, 0x74, 0x86);
        if ((x + y == 9 or x + y == 10) and y >= 2 and y <= 12) return rgb(0xdc, 0xf4, 0xf8);
        if (x + y == 13 and y >= 3 and y <= 11) return rgb(0xa6, 0xde, 0xe8);
        return if (hash(x, y, 91) % 4 == 0) rgb(0x52, 0xae, 0xc0) else rgb(0x5e, 0xbc, 0xcc);
    }

    /// Farol: cuatro paneles cálidos separados por un marco en cruz.
    pub fn lampara(x: usize, y: usize) Vec3 {
        if (x == 0 or x == 15 or y == 0 or y == 15) return rgb(0x3a, 0x32, 0x2c);
        if (x == 7 or x == 8 or y == 7 or y == 8) return rgb(0x5a, 0x48, 0x36);
        if (x == 1 or x == 14 or y == 1 or y == 14 or x == 6 or x == 9 or y == 6 or y == 9)
            return rgb(0xff, 0xc8, 0x5a);
        return rgb(0xff, 0xf0, 0xb0);
    }
};

// ---------------------------------------------------------------------------
// Pruebas
// ---------------------------------------------------------------------------

const testing = std.testing;

test "sample usa vecino más cercano con v hacia arriba" {
    var tex = try Texture.init(testing.allocator, 2, 2, .zero());
    defer tex.deinit(testing.allocator);
    const rojo = Vec3{ .x = 1, .y = 0, .z = 0 };
    const verde = Vec3{ .x = 0, .y = 1, .z = 0 };
    tex.setPixel(0, 0, rojo); // arriba a la izquierda
    tex.setPixel(1, 1, verde); // abajo a la derecha

    try testing.expectEqual(rojo, tex.sample(.{ .x = 0.25, .y = 0.75 }));
    try testing.expectEqual(verde, tex.sample(.{ .x = 0.75, .y = 0.25 }));
}

test "sample repite la textura fuera de [0, 1)" {
    var tex = try Texture.init(testing.allocator, 2, 2, .zero());
    defer tex.deinit(testing.allocator);
    const rojo = Vec3{ .x = 1, .y = 0, .z = 0 };
    tex.setPixel(0, 0, rojo);

    try testing.expectEqual(rojo, tex.sample(.{ .x = 1.25, .y = 1.75 }));
    try testing.expectEqual(rojo, tex.sample(.{ .x = -0.75, .y = -0.25 }));
    try testing.expectEqual(rojo, tex.sample(.{ .x = 3.25, .y = 0.75 }));
    // Bordes exactos no se salen del arreglo.
    _ = tex.sample(.{ .x = 1, .y = 1 });
    _ = tex.sample(.{ .x = 0, .y = 0 });
    _ = tex.sample(.{ .x = std.math.nan(f32), .y = 0 });
}

test "texturas procedurales se generan sin fugas" {
    var a = try ladrillos(testing.allocator);
    defer a.deinit(testing.allocator);
    var b = try orientacion(testing.allocator);
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 16 * 16), a.pixels.len);
    try testing.expectEqual(@as(usize, 16 * 16), b.pixels.len);
}

test "init rechaza tamaño cero" {
    try testing.expectError(error.InvalidTextureSize, Texture.init(testing.allocator, 0, 4, .zero()));
}
