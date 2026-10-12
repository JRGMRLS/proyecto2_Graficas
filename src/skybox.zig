const std = @import("std");
const Vec3 = @import("vec.zig").Vec3;
const Vec2 = @import("vec.zig").Vec2;
const texture = @import("texture.zig");
const Texture = texture.Texture;
const mezclar = texture.mezclar;

/// Cubemap de seis caras que se consulta cuando un rayo no golpea nada.
///
/// Cada cara es una Texture en memoria de CPU que se genera una sola vez en
/// `init` evaluando el cielo procedural (`cieloEn`) en la dirección de cada
/// píxel. Durante el render solo se elige la cara y se muestrea: no se genera
/// ni se asigna nada por rayo.
///
/// Convención de las caras (la misma de los cubemaps de OpenGL, que coincide
/// con esta cámara, donde Right = Up × Forward). Vista desde adentro del
/// cubo, cada cara tiene una normal `n`, un vector `derecha` (u crece hacia
/// él) y un vector `arriba` (v crece hacia él):
///
///     cara  n    derecha  arriba
///     +X    +x   -z       +y
///     -X    -x   +z       +y
///     +Y    +y   +x       -z
///     -Y    -y   +x       +z
///     +Z    +z   +x       +y
///     -Z    -z   -x       +y
///
/// Así ninguna cara se ve espejeada, y en las laterales el cielo queda arriba.
pub const Skybox = struct {
    caras: [6]Texture,

    pub const Cara = enum(u3) { pos_x, neg_x, pos_y, neg_y, pos_z, neg_z };

    const Base = struct { n: Vec3, derecha: Vec3, arriba: Vec3 };

    const bases = [6]Base{
        .{ .n = v3(1, 0, 0), .derecha = v3(0, 0, -1), .arriba = v3(0, 1, 0) },
        .{ .n = v3(-1, 0, 0), .derecha = v3(0, 0, 1), .arriba = v3(0, 1, 0) },
        .{ .n = v3(0, 1, 0), .derecha = v3(1, 0, 0), .arriba = v3(0, 0, -1) },
        .{ .n = v3(0, -1, 0), .derecha = v3(1, 0, 0), .arriba = v3(0, 0, 1) },
        .{ .n = v3(0, 0, 1), .derecha = v3(1, 0, 0), .arriba = v3(0, 1, 0) },
        .{ .n = v3(0, 0, -1), .derecha = v3(-1, 0, 0), .arriba = v3(0, 1, 0) },
    };

    /// Resolución de cada cara. Con muestreo bilineal y 256 px por cada 90°
    /// el cielo se ve suave a 640x480 (≈ 700 px por cada 90° en pantalla).
    pub const lado = 256;

    pub fn init(allocator: std.mem.Allocator) !Skybox {
        var out: Skybox = undefined;
        var creadas: usize = 0;
        errdefer for (out.caras[0..creadas]) |*t| t.deinit(allocator);

        const n: f32 = @floatFromInt(lado);
        for (&out.caras, 0..) |*cara, i| {
            cara.* = try Texture.init(allocator, lado, lado, .zero());
            creadas += 1;
            for (0..lado) |y| {
                for (0..lado) |x| {
                    // Centro del píxel; la fila 0 es la de arriba (v = 1).
                    const uv = Vec2{
                        .x = (@as(f32, @floatFromInt(x)) + 0.5) / n,
                        .y = 1 - (@as(f32, @floatFromInt(y)) + 0.5) / n,
                    };
                    const dir = direccionDe(@enumFromInt(i), uv);
                    cara.setPixel(x, y, cieloEn(dir));
                }
            }
        }
        return out;
    }

    pub fn deinit(self: *Skybox, allocator: std.mem.Allocator) void {
        for (&self.caras) |*t| t.deinit(allocator);
        self.* = undefined;
    }

    /// Color del cielo en la dirección `dir` (no necesita estar normalizada).
    pub fn muestrear(self: *const Skybox, dir: Vec3) Vec3 {
        const c = caraYUV(dir);
        return self.caras[@intFromEnum(c.cara)].sampleBilineal(c.uv);
    }

    /// Elige la cara por el componente dominante de la dirección y proyecta
    /// la dirección sobre ella:
    ///     u = (d·derecha / |d_max| + 1) / 2,   v = (d·arriba / |d_max| + 1) / 2
    pub fn caraYUV(dir: Vec3) struct { cara: Cara, uv: Vec2 } {
        const ax = @abs(dir.x);
        const ay = @abs(dir.y);
        const az = @abs(dir.z);

        var cara: Cara = undefined;
        var mayor: f32 = undefined;
        if (ax >= ay and ax >= az) {
            cara = if (dir.x >= 0) .pos_x else .neg_x;
            mayor = ax;
        } else if (ay >= az) {
            cara = if (dir.y >= 0) .pos_y else .neg_y;
            mayor = ay;
        } else {
            cara = if (dir.z >= 0) .pos_z else .neg_z;
            mayor = az;
        }
        if (!(mayor > 0)) return .{ .cara = .pos_z, .uv = .{ .x = 0.5, .y = 0.5 } };

        const b = bases[@intFromEnum(cara)];
        return .{
            .cara = cara,
            .uv = .{
                .x = (punto(dir, b.derecha) / mayor + 1) * 0.5,
                .y = (punto(dir, b.arriba) / mayor + 1) * 0.5,
            },
        };
    }

    /// Inversa de `caraYUV`: dirección unitaria que corresponde a (cara, uv).
    pub fn direccionDe(cara: Cara, uv: Vec2) Vec3 {
        const b = bases[@intFromEnum(cara)];
        const s = uv.x * 2 - 1;
        const t = uv.y * 2 - 1;
        return normalizar(.{
            .x = b.n.x + s * b.derecha.x + t * b.arriba.x,
            .y = b.n.y + s * b.derecha.y + t * b.arriba.y,
            .z = b.n.z + s * b.derecha.z + t * b.arriba.z,
        });
    }
};

// ---------------------------------------------------------------------------
// Cielo de atardecer procedural. Solo se evalúa al crear el cubemap.
// Como es una función de la dirección, dos caras vecinas calculan el mismo
// color en su borde común y no aparecen costuras.
// ---------------------------------------------------------------------------

/// Dirección hacia el sol: bajo sobre el horizonte, del lado (+x, -z), que es
/// hacia donde mira la cámara en su posición inicial.
const dir_sol = normalizar(v3(0.42, 0.075, -0.9));

const cenit = rgb(0x1c, 0x1a, 0x48);
const cielo_medio = rgb(0x5e, 0x3a, 0x78);
const cielo_bajo = rgb(0xd8, 0x62, 0x78);
const horizonte = rgb(0xff, 0xa8, 0x5c);
const sol_halo = rgb(0xff, 0x8a, 0x3c);
const sol_disco = rgb(0xff, 0xf4, 0xd0);
const nube_sombra = rgb(0x4e, 0x32, 0x5c);
const nube_luz = rgb(0xff, 0xb0, 0x8a);
const montana_cima = rgb(0x3a, 0x26, 0x46);
const suelo_cerca = rgb(0x22, 0x18, 0x2e);
const suelo_nadir = rgb(0x0a, 0x08, 0x12);

pub fn cieloEn(d: Vec3) Vec3 {
    const h = d.y;
    const sol = @max(0, punto(d, dir_sol));

    // Silueta de montañas lejanas: su altura depende solo del azimut, y se
    // evalúa sobre el círculo (x, z) para que no haya corte en ±π.
    const horiz = @sqrt(d.x * d.x + d.z * d.z);
    const cx = if (horiz > 0) d.x / horiz else 1;
    const cz = if (horiz > 0) d.z / horiz else 0;
    const cresta = 0.02 + 0.07 * fbm(cx * 2.2 + 17.3, cz * 2.2 - 4.1, 4);

    if (h < cresta) {
        // Montañas y suelo: más oscuro hacia abajo, con algo de bruma
        // cálida justo bajo la cresta (luz del atardecer en la distancia).
        var c = mezclar(montana_cima, suelo_cerca, suavizado(0, 0.12, cresta - h));
        c = mezclar(c, suelo_nadir, suavizado(0, 0.7, -h));
        const bruma = @exp(-(cresta - h) * 60) * (0.25 + 0.35 * sol * sol);
        return mezclar(c, horizonte, bruma);
    }

    // Degradado vertical del horizonte al cenit.
    const t = @sqrt(@max(0, h));
    var c = if (t < 0.4)
        mezclar(horizonte, cielo_bajo, t / 0.4)
    else if (t < 0.72)
        mezclar(cielo_bajo, cielo_medio, (t - 0.4) / 0.32)
    else
        mezclar(cielo_medio, cenit, (t - 0.72) / 0.28);

    // Halo del sol: amplio y tenue, más intenso cerca del horizonte.
    const halo = std.math.pow(f32, sol, 6) * 0.55 + std.math.pow(f32, sol, 48) * 0.5;
    c = mezclar(c, sol_halo, @min(1, halo * (1 - 0.5 * t)));

    // Nubes: ruido proyectado sobre un plano alto, así se achican y se
    // juntan hacia el horizonte como nubes reales en perspectiva.
    if (h > 0.02) {
        const escala = 1.6 / (h + 0.12);
        const densidad = fbm(d.x * escala + 3.7, d.z * escala - 8.2, 5);
        const cobertura = suavizado(0.5, 0.72, densidad) * suavizado(0.03, 0.2, h);
        if (cobertura > 0) {
            // Del lado del sol las nubes se encienden en naranja; del otro
            // lado quedan en violeta oscuro. Los bordes finos reciben más luz.
            const luz = std.math.clamp(0.25 + 0.75 * std.math.pow(f32, sol, 3) + 0.25 * (1 - t), 0, 1);
            var nube = mezclar(nube_sombra, nube_luz, luz);
            nube = mezclar(nube, nube_sombra, suavizado(0.65, 0.95, densidad) * 0.5);
            c = mezclar(c, nube, cobertura * 0.9);
        }
    }

    // Disco del sol con borde suave, encima de todo.
    c = mezclar(c, sol_disco, suavizado(0.9990, 0.9996, sol));
    return c;
}

// ---------------------------------------------------------------------------
// Utilidades
// ---------------------------------------------------------------------------

fn v3(x: f32, y: f32, z: f32) Vec3 {
    return .{ .x = x, .y = y, .z = z };
}

fn rgb(comptime r: u8, comptime g: u8, comptime b: u8) Vec3 {
    return .{
        .x = @as(f32, r) / 255.0,
        .y = @as(f32, g) / 255.0,
        .z = @as(f32, b) / 255.0,
    };
}

fn punto(a: Vec3, b: Vec3) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

fn normalizar(a: Vec3) Vec3 {
    const l = @sqrt(punto(a, a));
    return .{ .x = a.x / l, .y = a.y / l, .z = a.z / l };
}

/// smoothstep: 0 antes de `a`, 1 después de `b`, curva suave entre ambos.
fn suavizado(a: f32, b: f32, x: f32) f32 {
    const t = std.math.clamp((x - a) / (b - a), 0, 1);
    return t * t * (3 - 2 * t);
}

/// Valor pseudoaleatorio en [0, 1) para una celda entera.
fn azar(ix: i32, iy: i32) f32 {
    var h: u32 = @as(u32, @bitCast(ix)) *% 374761393 +% @as(u32, @bitCast(iy)) *% 668265263;
    h = (h ^ (h >> 13)) *% 1274126177;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h & 0xffffff)) / 16777216.0;
}

/// Ruido de valor 2D con interpolación suave, en [0, 1).
fn ruido(x: f32, y: f32) f32 {
    const fx = @floor(x);
    const fy = @floor(y);
    const ix: i32 = @intFromFloat(fx);
    const iy: i32 = @intFromFloat(fy);
    const tx = suavizado(0, 1, x - fx);
    const ty = suavizado(0, 1, y - fy);
    const a = azar(ix, iy);
    const b = azar(ix + 1, iy);
    const c = azar(ix, iy + 1);
    const e = azar(ix + 1, iy + 1);
    const arriba = a + (b - a) * tx;
    const abajo = c + (e - c) * tx;
    return arriba + (abajo - arriba) * ty;
}

/// Suma de octavas de ruido (fractal), normalizada a [0, 1).
fn fbm(x: f32, y: f32, octavas: u32) f32 {
    var suma: f32 = 0;
    var amplitud: f32 = 0.5;
    var total: f32 = 0;
    var px = x;
    var py = y;
    for (0..octavas) |_| {
        suma += amplitud * ruido(px, py);
        total += amplitud;
        // Se rota un poco cada octava para no alinear el ruido con los ejes.
        const nx = px * 1.6 - py * 1.2;
        py = px * 1.2 + py * 1.6;
        px = nx;
        amplitud *= 0.5;
    }
    return suma / total;
}

// ---------------------------------------------------------------------------
// Pruebas
// ---------------------------------------------------------------------------

const testing = std.testing;

test "caraYUV elige la cara por el componente dominante" {
    try testing.expectEqual(Skybox.Cara.pos_x, Skybox.caraYUV(v3(2, 1, -1)).cara);
    try testing.expectEqual(Skybox.Cara.neg_y, Skybox.caraYUV(v3(0.3, -5, 1)).cara);
    try testing.expectEqual(Skybox.Cara.neg_z, Skybox.caraYUV(v3(0.3, 0.2, -1)).cara);
}

test "direccionDe es la inversa de caraYUV" {
    const uvs = [_]Vec2{ .{ .x = 0.1, .y = 0.2 }, .{ .x = 0.5, .y = 0.5 }, .{ .x = 0.93, .y = 0.71 } };
    for (0..6) |i| {
        for (uvs) |uv| {
            const cara: Skybox.Cara = @enumFromInt(i);
            const r = Skybox.caraYUV(Skybox.direccionDe(cara, uv));
            try testing.expectEqual(cara, r.cara);
            try testing.expectApproxEqAbs(uv.x, r.uv.x, 1e-5);
            try testing.expectApproxEqAbs(uv.y, r.uv.y, 1e-5);
        }
    }
}

test "las caras laterales tienen el cielo arriba y no están espejeadas" {
    // En las cuatro caras laterales v = 1 es hacia +y.
    for ([_]Skybox.Cara{ .pos_x, .neg_x, .pos_z, .neg_z }) |cara| {
        try testing.expect(Skybox.direccionDe(cara, .{ .x = 0.5, .y = 0.95 }).y > 0);
    }
    // Recorrer u de izquierda a derecha en una cara lateral debe coincidir
    // con la derecha de la cámara (Up × Forward) al mirar esa cara.
    for ([_]Skybox.Cara{ .pos_x, .neg_x, .pos_z, .neg_z }) |cara| {
        const f = Skybox.direccionDe(cara, .{ .x = 0.5, .y = 0.5 });
        const derecha = Vec3.crossProduct(v3(0, 1, 0), f);
        const paso = Skybox.direccionDe(cara, .{ .x = 0.9, .y = 0.5 }).subtract(f);
        try testing.expect(punto(paso, derecha) > 0);
    }
}

test "el cubemap no tiene costuras entre caras vecinas" {
    var sky = try Skybox.init(testing.allocator);
    defer sky.deinit(testing.allocator);
    // Direcciones sobre aristas y esquinas del cubo, empujadas un poco a
    // cada lado: el color no debe saltar al cambiar de cara.
    const bordes = [_]Vec3{
        v3(1, 0.3, 1), v3(-1, 0.2, 1),   v3(1, 1, 0.4), v3(0.2, -1, -1),
        v3(1, 1, 1),   v3(-1, 0.05, -1),
    };
    for (bordes) |b| {
        const e: f32 = 2e-3;
        const a = sky.muestrear(b.add(v3(e, e, e)));
        const c = sky.muestrear(b.subtract(v3(e, e, e)));
        try testing.expect(@abs(a.x - c.x) < 0.06);
        try testing.expect(@abs(a.y - c.y) < 0.06);
        try testing.expect(@abs(a.z - c.z) < 0.06);
    }
}

test "el cielo es más oscuro abajo que en el horizonte" {
    const abajo = cieloEn(v3(0, -1, 0));
    const horiz = cieloEn(normalizar(v3(-0.9, 0.15, 0.4)));
    try testing.expect(abajo.x + abajo.y + abajo.z < horiz.x + horiz.y + horiz.z);
}
