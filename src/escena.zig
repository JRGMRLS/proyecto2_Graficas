//! Escena con transformación: la lista de objetos (en coordenadas locales del
//! diorama) más una rotación alrededor del eje Y que la coloca en el mundo.
//!
//! En lugar de mover los 60 cubos cada vez que el diorama gira, se transforma
//! cada rayo al espacio local, se intersecta contra los cubos sin modificar y
//! el resultado (punto y normal) se regresa al espacio del mundo. Los objetos
//! nunca se reconstruyen: girar el diorama solo cambia un seno y un coseno.
//!
//! Además, un cubo girado deja de estar alineado a los ejes, así que moverlo
//! rompería el método de slabs. Transformar el rayo lo evita.

const std = @import("std");
const Vec3 = @import("vec.zig").Vec3;
const Forma = @import("formas.zig").Forma;
const Intersect = @import("raytracer.zig").Intersect;
const Golpe = @import("raytracer.zig").Golpe;
const Material = @import("raytracer.zig").Material;

/// Rotación de ángulo θ alrededor del eje Y que pasa por el origen:
///
///     R(θ) = |  cos θ   0   sin θ |
///            |    0     1     0   |
///            | -sin θ   0   cos θ |
///
/// Es ortonormal, así que su inversa es su transpuesta, R(-θ), y conserva
/// longitudes y ángulos: la distancia a lo largo del rayo no cambia al pasar
/// de un espacio a otro.
///
/// Solo usa aritmética de Zig (sin llamadas a C), por eso sirve en comptime
/// y en las pruebas.
pub const RotacionY = struct {
    angulo: f32 = 0,
    seno: f32 = 0,
    coseno: f32 = 1,

    pub fn init(angulo: f32) RotacionY {
        return .{ .angulo = angulo, .seno = @sin(angulo), .coseno = @cos(angulo) };
    }

    /// Local -> mundo: R(θ)·v.
    pub fn aplicar(self: RotacionY, v: Vec3) Vec3 {
        return .{
            .x = self.coseno * v.x + self.seno * v.z,
            .y = v.y,
            .z = -self.seno * v.x + self.coseno * v.z,
        };
    }

    /// Mundo -> local: R(-θ)·v = R(θ)ᵀ·v.
    pub fn invertir(self: RotacionY, v: Vec3) Vec3 {
        return .{
            .x = self.coseno * v.x - self.seno * v.z,
            .y = v.y,
            .z = self.seno * v.x + self.coseno * v.z,
        };
    }
};

pub const Escena = struct {
    /// Objetos en coordenadas locales del diorama. No se modifican.
    objetos: []const Forma,
    /// Transformación local -> mundo del diorama completo.
    rotacion: RotacionY = .{},
    /// Caja (espacio local) que contiene todos los objetos. Con ella un rayo
    /// que no toca el diorama (el cielo) se descarta con una sola prueba en
    /// lugar de una por objeto. null = no calculada: no se descarta nada.
    limites: ?Caja = null,

    pub const Caja = struct { min: Vec3, max: Vec3 };

    /// Escena sin rotación y con los límites calculados.
    pub fn init(objetos: []const Forma) Escena {
        return .{ .objetos = objetos, .limites = limitesDe(objetos) };
    }

    fn limitesDe(objetos: []const Forma) ?Caja {
        if (objetos.len == 0) return null;
        const inf = std.math.inf(f32);
        var caja = Caja{
            .min = .{ .x = inf, .y = inf, .z = inf },
            .max = .{ .x = -inf, .y = -inf, .z = -inf },
        };
        for (objetos) |objeto| {
            const lo: Vec3, const hi: Vec3 = switch (objeto) {
                .Cube => |c| .{ c.min, c.max },
                .Sphere => |s| .{
                    .{ .x = s.center.x - s.radius, .y = s.center.y - s.radius, .z = s.center.z - s.radius },
                    .{ .x = s.center.x + s.radius, .y = s.center.y + s.radius, .z = s.center.z + s.radius },
                },
            };
            caja.min = .{ .x = @min(caja.min.x, lo.x), .y = @min(caja.min.y, lo.y), .z = @min(caja.min.z, lo.z) };
            caja.max = .{ .x = @max(caja.max.x, hi.x), .y = @max(caja.max.y, hi.y), .z = @max(caja.max.z, hi.z) };
        }
        return caja;
    }

    /// false solo si el rayo (local) seguro no toca la caja de límites antes
    /// de `distancia_max`. Conservador: ante la duda devuelve true.
    fn alcanza(self: Escena, o: Vec3, d: Vec3, distancia_max: f32) bool {
        const caja = self.limites orelse return true;
        const oa = [3]f32{ o.x, o.y, o.z };
        const da = [3]f32{ d.x, d.y, d.z };
        const lo = [3]f32{ caja.min.x, caja.min.y, caja.min.z };
        const hi = [3]f32{ caja.max.x, caja.max.y, caja.max.z };
        var t_near: f32 = 0;
        var t_far: f32 = distancia_max;
        inline for (0..3) |i| {
            if (@abs(da[i]) < 1e-8) {
                if (oa[i] < lo[i] or oa[i] > hi[i]) return false;
            } else {
                const inv = 1.0 / da[i];
                const t0 = (lo[i] - oa[i]) * inv;
                const t1 = (hi[i] - oa[i]) * inv;
                t_near = @max(t_near, @min(t0, t1));
                t_far = @min(t_far, @max(t0, t1));
                if (t_near > t_far) return false;
            }
        }
        return true;
    }

    /// Intersección más cercana de un rayo dado en coordenadas del mundo.
    /// Devuelve Punto y Normal en coordenadas del mundo; UV y Cara quedan en
    /// el espacio local, porque la textura se mueve junto con el objeto.
    pub fn intersectar(self: Escena, origin: Vec3, direction: Vec3) ?Intersect {
        // 1. El rayo al espacio local. El origen es un punto y la dirección
        //    un vector; con una rotación pura (sin traslación) ambos se
        //    transforman igual.
        const o = self.rotacion.invertir(origin);
        const d = self.rotacion.invertir(direction);
        if (!self.alcanza(o, d, std.math.floatMax(f32))) return null;

        // Se busca el impacto más cercano solo con la geometría barata y se
        // completa (punto, UV) una única vez, al final.
        var mejor: Golpe = undefined;
        var indice: usize = 0;
        var hay = false;
        for (self.objetos, 0..) |*objeto, i| {
            const g = objeto.golpe(o, d) orelse continue;
            if (!hay or g.distancia < mejor.distancia) {
                mejor = g;
                indice = i;
                hay = true;
            }
        }
        if (!hay) return null;

        var hit = self.objetos[indice].completar(mejor, o, d);
        // 2. El resultado de regreso al mundo.
        //    - La distancia no cambia: la rotación conserva longitudes.
        //    - Las normales se transforman con la inversa transpuesta de la
        //      matriz del objeto, (R⁻¹)ᵀ. Para una rotación R⁻¹ = Rᵀ, así que
        //      (R⁻¹)ᵀ = R: la normal se rota igual que cualquier vector y
        //      sigue siendo unitaria y perpendicular a la cara.
        hit.Punto = self.rotacion.aplicar(hit.Punto);
        hit.Normal = self.rotacion.aplicar(hit.Normal);
        return hit;
    }

    /// true si algún objeto corta el rayo antes de `distancia_max`.
    /// Se usa para las sombras; se detiene en el primer impacto.
    pub fn bloquea(self: Escena, origin: Vec3, direction: Vec3, distancia_max: f32) bool {
        const o = self.rotacion.invertir(origin);
        const d = self.rotacion.invertir(direction);
        if (!self.alcanza(o, d, distancia_max)) return false;
        for (self.objetos) |*objeto| {
            const g = objeto.golpe(o, d) orelse continue;
            if (g.distancia < distancia_max) return true;
        }
        return false;
    }

    /// Fracción de luz (por canal RGB) que llega sin obstruir a lo largo del
    /// rayo hasta `distancia_max`. Se usa para las sombras:
    ///   - (1, 1, 1): nada se interpone.
    ///   - (0, 0, 0): un objeto opaco bloquea la luz; se detiene ahí.
    ///   - Cada objeto transparente multiplica por Transparencia·tinte, así el
    ///     vidrio deja una sombra parcial del color del vidrio.
    /// Cube y Sphere devuelven un solo impacto por objeto, así que cada
    /// objeto transparente filtra la luz una vez.
    pub fn transmision(self: Escena, origin: Vec3, direction: Vec3, distancia_max: f32) Vec3 {
        const o = self.rotacion.invertir(origin);
        const d = self.rotacion.invertir(direction);
        var paso: Vec3 = .{ .x = 1, .y = 1, .z = 1 };
        if (!self.alcanza(o, d, distancia_max)) return paso;
        for (self.objetos) |*objeto| {
            const g = objeto.golpe(o, d) orelse continue;
            if (g.distancia >= distancia_max) continue;

            const mat = objeto.material();
            const t = mat.Propiedades.Transparencia;
            if (t <= 0) return .{ .x = 0, .y = 0, .z = 0 };

            // Solo el vidrio necesita UV (color de la textura): el punto y las
            // coordenadas se calculan aquí y no para cada candidato.
            const hit = objeto.completar(g, o, d);
            const filtro = Material.tinte(mat.colorEn(hit.UV, hit.Cara));
            paso = .{
                .x = paso.x * t * filtro.x,
                .y = paso.y * t * filtro.y,
                .z = paso.z * t * filtro.z,
            };
        }
        return paso;
    }
};

// ---------------------------------------------------------------------------
// Pruebas
// ---------------------------------------------------------------------------

const testing = std.testing;
const Cube = @import("cube.zig").Cube;
const tolerancia: f32 = 1e-4;

fn v3(x: f32, y: f32, z: f32) Vec3 {
    return .{ .x = x, .y = y, .z = z };
}

fn expectVec(expected: Vec3, actual: Vec3) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, tolerancia);
    try testing.expectApproxEqAbs(expected.y, actual.y, tolerancia);
    try testing.expectApproxEqAbs(expected.z, actual.z, tolerancia);
}

const material_prueba = Material{
    .Color = .{ .x = 1, .y = 1, .z = 1 },
    .Especular = 0,
    .Refractive_index = 1,
    .Propiedades = .{ .Albedo = 1, .Especular = 0, .Reflectividad = 0, .Transparencia = 0 },
};

test "invertir deshace aplicar y se conserva la longitud" {
    const r = RotacionY.init(0.7);
    const v = v3(1.5, -2, 3.25);
    try expectVec(v, r.invertir(r.aplicar(v)));
    try expectVec(v, r.aplicar(r.invertir(v)));
    const a = r.aplicar(v);
    try testing.expectApproxEqAbs(v.x * v.x + v.y * v.y + v.z * v.z, a.x * a.x + a.y * a.y + a.z * a.z, tolerancia);
}

test "90 grados lleva +x a -z y +z a +x" {
    const r = RotacionY.init(std.math.pi / 2.0);
    try expectVec(v3(0, 0, -1), r.aplicar(v3(1, 0, 0)));
    try expectVec(v3(1, 0, 0), r.aplicar(v3(0, 0, 1)));
    try expectVec(v3(0, 1, 0), r.aplicar(v3(0, 1, 0)));
}

test "rotar la escena mueve el impacto, el punto y la normal" {
    // Cubo local de lado 2 centrado en (3, 0, 0). Con la escena girada 90°
    // queda centrado en (0, 0, -3) del mundo.
    const objetos = [_]Forma{.{ .Cube = Cube.init(v3(3, 0, 0), 2, material_prueba) }};
    const escena = Escena{ .objetos = &objetos, .rotacion = .init(std.math.pi / 2.0) };

    // Sin rotar, un rayo por el eje z no lo toca.
    const sin_rotar = Escena{ .objetos = &objetos };
    try testing.expect(sin_rotar.intersectar(v3(0, 0, -10), v3(0, 0, 1)) == null);

    // Rotado, el rayo golpea la cara que en local es +x (en el mundo mira a -z).
    const hit = escena.intersectar(v3(0, 0, -10), v3(0, 0, 1)) orelse return error.TestExpectedHit;
    try testing.expectApproxEqAbs(@as(f32, 6), hit.Distancia, tolerancia);
    try expectVec(v3(0, 0, -4), hit.Punto);
    try expectVec(v3(0, 0, -1), hit.Normal);
    try testing.expectEqual(.pos_x, hit.Cara);
}

test "la normal rotada sigue siendo unitaria y opuesta al rayo que entra" {
    const objetos = [_]Forma{.{ .Cube = Cube.init(v3(0, 0, 0), 2, material_prueba) }};
    const escena = Escena{ .objetos = &objetos, .rotacion = .init(0.5) };
    // Rayo hacia el centro desde una dirección arbitraria en el plano xz.
    const dir = v3(-0.6, 0, -0.8);
    const hit = escena.intersectar(v3(6, 0, 8), dir) orelse return error.TestExpectedHit;
    const n = hit.Normal;
    try testing.expectApproxEqAbs(@as(f32, 1), @sqrt(n.x * n.x + n.y * n.y + n.z * n.z), tolerancia);
    try testing.expect(n.x * dir.x + n.y * dir.y + n.z * dir.z < 0);
}

test "bloquea respeta la distancia máxima en la escena rotada" {
    const objetos = [_]Forma{.{ .Cube = Cube.init(v3(3, 0, 0), 2, material_prueba) }};
    const escena = Escena{ .objetos = &objetos, .rotacion = .init(std.math.pi / 2.0) };
    try testing.expect(escena.bloquea(v3(0, 0, -10), v3(0, 0, 1), 20));
    try testing.expect(!escena.bloquea(v3(0, 0, -10), v3(0, 0, 1), 5));
}

test "transmision: el vidrio tiñe la luz y lo opaco la bloquea" {
    var vidrio = material_prueba;
    vidrio.Color = v3(0, 1, 0);
    vidrio.Propiedades.Transparencia = 0.8;
    const solo_vidrio = [_]Forma{.{ .Cube = Cube.init(v3(0, 0, 0), 2, vidrio) }};
    const escena = Escena{ .objetos = &solo_vidrio };
    const paso = escena.transmision(v3(0, 0, -10), v3(0, 0, 1), 20);
    try testing.expect(paso.y > paso.x and paso.x > 0);
    try testing.expect(paso.y < 1);

    const con_muro = [_]Forma{
        .{ .Cube = Cube.init(v3(0, 0, 0), 2, vidrio) },
        .{ .Cube = Cube.init(v3(0, 0, 4), 2, material_prueba) },
    };
    const bloqueada = (Escena{ .objetos = &con_muro }).transmision(v3(0, 0, -10), v3(0, 0, 1), 20);
    try expectVec(v3(0, 0, 0), bloqueada);
    // Más allá de la luz no cuenta.
    try expectVec(v3(1, 1, 1), escena.transmision(v3(0, 0, -10), v3(0, 0, 1), 5));
}
