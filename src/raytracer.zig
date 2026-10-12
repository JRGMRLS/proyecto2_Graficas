const std = @import("std");
const rl = @import("raylib");
const Vec3 = @import("vec.zig").Vec3;
const Vec2 = @import("vec.zig").Vec2;
const Texture = @import("texture.zig").Texture;

pub fn V3FromColor(src: rl.Color) Vec3 {
    const x: f32 = @floatFromInt(src.r);
    const y: f32 = @floatFromInt(src.g);
    const z: f32 = @floatFromInt(src.b);
    return .{ .x = x / 255, .y = y / 255, .z = z / 255 };
}

pub fn V3ToColor(color: Vec3) rl.Color {
    const r: u8 = @intFromFloat(@max(0, @min(255, color.x * 255)));
    const g: u8 = @intFromFloat(@max(0, @min(255, color.y * 255)));
    const b: u8 = @intFromFloat(@max(0, @min(255, color.z * 255)));
    return .{ .r = r, .g = g, .b = b, .a = 0xff };
}

pub const Light = struct {
    Color: Vec3,
    Position: Vec3,
    Intensity: f32,
};

pub const Material = struct {
    //xyz como rgb, pero reducimos conversiones primero haciendo mate en f32 y luego convertimos de regreso a u8
    // Color base. Se usa como respaldo cuando el material no tiene textura.
    Color: Vec3,
    Especular: f32,
    Refractive_index: f32,
    Propiedades: struct {
        Albedo: f32,
        Especular: f32,
        Reflectividad: f32,
        Transparencia: f32,
    },
    // Textura opcional. Es un puntero: la textura vive en main y se crea
    // una sola vez, así cast_ray nunca carga ni asigna memoria.
    Textura: ?*const Texture = null,
    // Texturas opcionales para las caras superior (+y) e inferior (-y).
    // Si son null se usa `Textura`. Sirven, por ejemplo, para el bloque de
    // césped: pasto arriba y tierra con borde verde a los lados.
    TexturaArriba: ?*const Texture = null,
    TexturaAbajo: ?*const Texture = null,
    // Cuántas veces se repite la textura en cada cara (u, v).
    EscalaUV: Vec2 = .{ .x = 1, .y = 1 },
    // Luz propia: se suma el color de la superficie multiplicado por este
    // factor sin depender de las luces ni de las sombras (lámparas).
    Emision: f32 = 0,

    /// Color difuso en el punto: la textura de la cara si existe, si no el color base.
    pub fn colorEn(self: *const Material, uv: Vec2, cara: Cara) Vec3 {
        const elegida = switch (cara) {
            .pos_y => self.TexturaArriba orelse self.Textura,
            .neg_y => self.TexturaAbajo orelse self.Textura,
            else => self.Textura,
        };
        const tex = elegida orelse return self.Color;
        return tex.sample(.{ .x = uv.x * self.EscalaUV.x, .y = uv.y * self.EscalaUV.y });
    }

    /// Filtro que aplica el material a la luz que lo atraviesa:
    /// mezcla entre blanco (no tiñe) y el color de la superficie.
    ///     filtro = (1 - k)·(1, 1, 1) + k·color,   k = tinte_transmision
    pub fn tinte(color: Vec3) Vec3 {
        const k = tinte_transmision;
        return .{
            .x = 1 - k + k * color.x,
            .y = 1 - k + k * color.y,
            .z = 1 - k + k * color.z,
        };
    }
};

/// Qué tanto tiñe un material transparente la luz que transmite.
/// 0: vidrio incoloro; 1: la luz sale del color exacto del vidrio.
pub const tinte_transmision: f32 = 0.4;

/// Separación que se aplica al origen de los rayos secundarios (reflexión,
/// refracción y sombra) para que no vuelvan a chocar con la superficie de la
/// que salen por error de redondeo ("acné"). Es mayor que el epsilon con el
/// que Cube y Sphere aceptan impactos.
pub const epsilon_rayo: f32 = 1e-3;

/// Mueve `punto` una distancia epsilon sobre la normal, hacia el lado de la
/// superficie al que apunta `direccion`: afuera si el rayo sale de ella,
/// adentro si el rayo entra (refracción).
pub fn desplazar(punto: Vec3, normal: Vec3, direccion: Vec3) Vec3 {
    const lado: f32 = if (direccion.dotProduct(normal) < 0) -1 else 1;
    return punto.add(normal.scale(lado * epsilon_rayo));
}

/// Vector reflejado de `incidente` respecto a la normal unitaria `normal`:
///     R = I - 2 (I·N) N
/// Funciona con N de cualquiera de los dos lados, porque (I·N) N no cambia
/// si se invierte N.
pub fn reflejar(incidente: Vec3, normal: Vec3) Vec3 {
    return incidente.subtract(normal.scale(2 * incidente.dotProduct(normal)));
}

/// Dirección refractada según la ley de Snell, o null si hay reflexión
/// interna total.
///
/// `normal` es la normal hacia afuera del objeto e `indice` el índice de
/// refracción del objeto (el medio exterior es aire, n = 1).
///   - Entrando (I·N < 0): n1 = 1, n2 = indice, se usa N.
///   - Saliendo (I·N > 0): se intercambian, n1 = indice, n2 = 1, y la normal
///     se invierte para que apunte hacia el lado del que viene el rayo.
///
/// Con η = n1 / n2 y cos θi = -I·N (N ya del lado del rayo):
///     sin² θt = η² (1 - cos² θi)                     (Snell: n1 sin θi = n2 sin θt)
///     k = 1 - sin² θt = cos² θt
///     si k < 0 → reflexión interna total
///     T = η I + (η cos θi - √k) N
pub fn refractar(incidente: Vec3, normal: Vec3, indice: f32) ?Vec3 {
    var cosi = incidente.dotProduct(normal);
    var n1: f32 = 1;
    var n2: f32 = if (indice > 0) indice else 1;
    var n = normal;

    if (cosi > 0) {
        // El rayo va del interior al exterior.
        std.mem.swap(f32, &n1, &n2);
        n = n.scale(-1);
    } else {
        cosi = -cosi;
    }

    const eta = n1 / n2;
    const k = 1 - eta * eta * (1 - cosi * cosi);
    if (k < 0) return null;

    return incidente.scale(eta).add(n.scale(eta * cosi - @sqrt(k))).normalize();
}

/// Cara golpeada, nombrada por la dirección de su normal hacia afuera.
/// `ninguna` se usa en formas que no tienen caras (la esfera).
pub const Cara = enum {
    ninguna,
    pos_x,
    neg_x,
    pos_y,
    neg_y,
    pos_z,
    neg_z,
};

/// Resultado barato de una intersección: solo la geometría esencial.
/// `eje` y `signo` describen la cara golpeada en cajas; la esfera los ignora.
pub const Golpe = struct {
    distancia: f32,
    eje: u8 = 0,
    signo: f32 = 1,
};

pub const Intersect = struct {
    // Apunta al material de la forma golpeada; las formas viven más que
    // cualquier Intersect, así que no se copia por impacto.
    Material: *const Material,
    Distancia: f32,
    Normal: Vec3,
    Punto: Vec3,
    // Coordenadas de textura en el punto golpeado, normalmente en [0, 1].
    UV: Vec2 = .{ .x = 0, .y = 0 },
    Cara: Cara = .ninguna,
};

// ---------------------------------------------------------------------------
// Pruebas
// ---------------------------------------------------------------------------

const testing = std.testing;
const tolerancia: f32 = 1e-4;

fn v3(x: f32, y: f32, z: f32) Vec3 {
    return .{ .x = x, .y = y, .z = z };
}

fn expectVec(expected: Vec3, actual: Vec3) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, tolerancia);
    try testing.expectApproxEqAbs(expected.y, actual.y, tolerancia);
    try testing.expectApproxEqAbs(expected.z, actual.z, tolerancia);
}

test "reflejar invierte la componente normal" {
    const i = v3(1, -1, 0).normalize();
    try expectVec(v3(1, 1, 0).normalize(), reflejar(i, v3(0, 1, 0)));
    // El resultado no depende del lado de la normal.
    try expectVec(v3(1, 1, 0).normalize(), reflejar(i, v3(0, -1, 0)));
}

test "refractar a incidencia normal no desvía el rayo" {
    const t = refractar(v3(0, 0, 1), v3(0, 0, -1), 1.5) orelse return error.TestUnexpectedNull;
    try expectVec(v3(0, 0, 1), t);
}

test "refractar cumple Snell al entrar y al salir" {
    // 45° de aire a vidrio: sin θt = sin 45° / 1.5.
    const i = v3(1, -1, 0).normalize();
    const t = refractar(i, v3(0, 1, 0), 1.5) orelse return error.TestUnexpectedNull;
    try testing.expectApproxEqAbs(@sin(@as(f32, std.math.pi / 4.0)) / 1.5, t.x, tolerancia);
    try testing.expect(t.y < 0);

    // De regreso (normal hacia afuera, mismo sentido que el rayo) vuelve a 45°.
    const s = refractar(t, v3(0, -1, 0), 1.5) orelse return error.TestUnexpectedNull;
    try expectVec(i, s);
}

test "refractar detecta reflexión interna total" {
    // Ángulo crítico del vidrio ≈ 41.8°; a 60° desde adentro no sale.
    const i = v3(@sin(@as(f32, std.math.pi / 3.0)), @cos(@as(f32, std.math.pi / 3.0)), 0);
    try testing.expect(refractar(i, v3(0, 1, 0), 1.5) == null);
}
