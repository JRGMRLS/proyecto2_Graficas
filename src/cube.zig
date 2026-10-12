const std = @import("std");
const Vec3 = @import("vec.zig").Vec3;
const Vec2 = @import("vec.zig").Vec2;
const Intersect = @import("raytracer.zig").Intersect;
const Material = @import("raytracer.zig").Material;
const Cara = @import("raytracer.zig").Cara;
const Golpe = @import("raytracer.zig").Golpe;

/// Cubo (caja alineada a los ejes, AABB) definido por sus límites mínimo y máximo.
pub const Cube = struct {
    min: Vec3,
    max: Vec3,
    material: Material,
    /// Tamaño en unidades de mundo de una repetición de la textura.
    /// 0: la textura se estira una vez sobre cada cara (UV en [0, 1]).
    /// > 0: UV alineadas al mundo; una caja de 6x1x6 con tile = 1 se ve
    /// como 36 bloques en su cara superior, con un solo objeto.
    tile: f32 = 0,

    /// Distancia mínima para aceptar un impacto y evitar que el rayo
    /// choque con la misma superficie de la que sale.
    const epsilon: f32 = 1e-4;

    /// Crea un cubo a partir de su centro y la longitud de su lado.
    /// Usa aritmética directa en lugar de Vec3.add/subtract porque esas
    /// llaman a funciones de C y no se pueden evaluar en comptime.
    pub fn init(center: Vec3, size: f32, material: Material) Cube {
        const half = size * 0.5;
        return .{
            .min = .{ .x = center.x - half, .y = center.y - half, .z = center.z - half },
            .max = .{ .x = center.x + half, .y = center.y + half, .z = center.z + half },
            .material = material,
        };
    }

    pub fn intersect(self: Cube, origin: Vec3, direction: Vec3) ?Intersect {
        const g = self.golpe(origin, direction) orelse return null;
        return self.completar(g, origin, direction);
    }

    /// Solo la geometría del impacto (distancia, eje y lado). Es barato: no
    /// calcula punto ni UV. Escena lo usa para descartar candidatos y completa
    /// únicamente el más cercano.
    pub fn golpe(self: *const Cube, origin: Vec3, direction: Vec3) ?Golpe {
        // Método de slabs: el cubo es la intersección de tres "losas",
        // una por eje, cada una delimitada por dos planos paralelos.
        // https://en.wikipedia.org/wiki/Slab_method
        const o = [3]f32{ origin.x, origin.y, origin.z };
        const d = [3]f32{ direction.x, direction.y, direction.z };
        const lo = [3]f32{ self.min.x, self.min.y, self.min.z };
        const hi = [3]f32{ self.max.x, self.max.y, self.max.z };

        // Intervalo [t_near, t_far] en el que el rayo está dentro de todas las losas.
        var t_near: f32 = -std.math.inf(f32);
        var t_far: f32 = std.math.inf(f32);
        // Eje del plano que define t_near y t_far, para saber qué cara se golpea.
        var near_axis: usize = 0;
        var far_axis: usize = 0;

        inline for (0..3) |axis| {
            if (@abs(d[axis]) < 1e-8) {
                // El rayo es paralelo a esta losa: si el origen no está entre
                // sus dos planos, nunca la atravesará.
                if (o[axis] < lo[axis] or o[axis] > hi[axis]) return null;
            } else {
                const inv = 1.0 / d[axis];
                var t0 = (lo[axis] - o[axis]) * inv;
                var t1 = (hi[axis] - o[axis]) * inv;
                // t0 debe ser el plano por el que se entra y t1 por el que se sale.
                if (t0 > t1) std.mem.swap(f32, &t0, &t1);

                if (t0 > t_near) {
                    t_near = t0;
                    near_axis = axis;
                }
                if (t1 < t_far) {
                    t_far = t1;
                    far_axis = axis;
                }

                // Los intervalos no se traslapan: el rayo no toca el cubo.
                if (t_near > t_far) return null;
            }
        }

        // El cubo está completamente detrás del rayo.
        if (t_far < epsilon) return null;

        // Dirección degenerada (paralela a los tres ejes, es decir, cero):
        // ningún plano limita el intervalo y no hay cara que golpear.
        if (std.math.isInf(t_far)) return null;

        // Si t_near es positivo el origen está fuera y golpeamos la cara de entrada.
        // Si no, el origen está dentro del cubo y golpeamos la cara de salida.
        const outside = t_near > epsilon;
        const distance = if (outside) t_near else t_far;
        const axis = if (outside) near_axis else far_axis;

        // Normal hacia afuera de la cara golpeada.
        // Al entrar, la cara mira en sentido opuesto al rayo;
        // al salir, mira en el mismo sentido del rayo.
        const sign: f32 = if (outside)
            (if (d[axis] > 0) -1 else 1)
        else
            (if (d[axis] > 0) 1 else -1);

        return .{ .distancia = distance, .eje = @intCast(axis), .signo = sign };
    }

    /// Completa un `Golpe` con punto, normal, UV y cara.
    pub fn completar(self: *const Cube, g: Golpe, origin: Vec3, direction: Vec3) Intersect {
        var n = [3]f32{ 0, 0, 0 };
        n[g.eje] = g.signo;

        const cara = caraDesdeEje(g.eje, g.signo);
        const punto = origin.add(direction.scale(g.distancia));

        return .{
            .Material = &self.material,
            .Distancia = g.distancia,
            .Normal = .{ .x = n[0], .y = n[1], .z = n[2] },
            .Punto = punto,
            .UV = self.uvEn(cara, punto),
            .Cara = cara,
        };
    }

    fn caraDesdeEje(axis: usize, sign: f32) Cara {
        return switch (axis) {
            0 => if (sign > 0) .pos_x else .neg_x,
            1 => if (sign > 0) .pos_y else .neg_y,
            else => if (sign > 0) .pos_z else .neg_z,
        };
    }

    /// Convierte un punto sobre la cara `cara` en coordenadas UV en [0, 1].
    ///
    /// Cada cara se "mira" desde afuera, de frente a su normal:
    ///   - v crece hacia arriba (+y) en las caras laterales. En la de arriba
    ///     crece hacia -z y en la de abajo hacia +z.
    ///   - u crece hacia la derecha de quien mira. La derecha se calcula como
    ///     Up × Forward, igual que Camera.lookAt, para que la textura no
    ///     se vea espejeada en pantalla.
    ///
    /// Se normaliza con el tamaño de la caja en cada eje, así una caja no
    /// uniforme recibe la textura completa en cada cara.
    pub fn uvEn(self: Cube, cara: Cara, p: Vec3) Vec2 {
        if (self.tile > 0) {
            // Mismas direcciones de u y v que abajo, pero medidas en
            // coordenadas de mundo. Así cajas vecinas continúan el mismo
            // patrón y la repetición la resuelve Texture.sample.
            const s = 1 / self.tile;
            return switch (cara) {
                .pos_x => .{ .x = p.z * s, .y = p.y * s },
                .neg_x => .{ .x = -p.z * s, .y = p.y * s },
                .pos_z => .{ .x = -p.x * s, .y = p.y * s },
                .neg_z => .{ .x = p.x * s, .y = p.y * s },
                .pos_y => .{ .x = -p.x * s, .y = -p.z * s },
                .neg_y => .{ .x = -p.x * s, .y = p.z * s },
                .ninguna => .{ .x = 0, .y = 0 },
            };
        }

        // Posición relativa dentro de la caja, en [0, 1] por eje.
        const rx = (p.x - self.min.x) / (self.max.x - self.min.x);
        const ry = (p.y - self.min.y) / (self.max.y - self.min.y);
        const rz = (p.z - self.min.z) / (self.max.z - self.min.z);

        const uv: Vec2 = switch (cara) {
            // Mirando hacia -x: la derecha es +z.
            .pos_x => .{ .x = rz, .y = ry },
            // Mirando hacia +x: la derecha es -z.
            .neg_x => .{ .x = 1 - rz, .y = ry },
            // Mirando hacia -z: la derecha es -x.
            .pos_z => .{ .x = 1 - rx, .y = ry },
            // Mirando hacia +z: la derecha es +x.
            .neg_z => .{ .x = rx, .y = ry },
            // Desde arriba, con -z como "arriba" de la imagen: la derecha es -x.
            .pos_y => .{ .x = 1 - rx, .y = 1 - rz },
            // Desde abajo, con +z como "arriba" de la imagen: la derecha es -x.
            .neg_y => .{ .x = 1 - rx, .y = rz },
            .ninguna => .{ .x = 0, .y = 0 },
        };

        // Evita valores apenas fuera de [0, 1] por error de redondeo en los bordes,
        // que con la repetición de textura saltarían al lado opuesto.
        return .{
            .x = std.math.clamp(uv.x, 0, 1),
            .y = std.math.clamp(uv.y, 0, 1),
        };
    }
};

// ---------------------------------------------------------------------------
// Pruebas. Se ejecutan con `zig build test`.
// ---------------------------------------------------------------------------

const testing = std.testing;
const tolerancia: f32 = 1e-4;

const material_prueba = Material{
    .Color = .{ .x = 1, .y = 1, .z = 1 },
    .Especular = 0,
    .Refractive_index = 0,
    .Propiedades = .{
        .Albedo = 1,
        .Especular = 0,
        .Reflectividad = 0,
        .Transparencia = 0,
    },
};

/// Cubo de lado 2 centrado en el origen: límites [-1, 1] en los tres ejes.
const cubo_unitario = Cube.init(.{ .x = 0, .y = 0, .z = 0 }, 2, material_prueba);

fn v3(x: f32, y: f32, z: f32) Vec3 {
    return .{ .x = x, .y = y, .z = z };
}

fn expectVec(expected: Vec3, actual: Vec3) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, tolerancia);
    try testing.expectApproxEqAbs(expected.y, actual.y, tolerancia);
    try testing.expectApproxEqAbs(expected.z, actual.z, tolerancia);
}

fn expectHit(
    cube: Cube,
    origin: Vec3,
    direction: Vec3,
    distancia: f32,
    punto: Vec3,
    normal: Vec3,
) !void {
    const hit = cube.intersect(origin, direction) orelse return error.TestExpectedHit;
    try testing.expectApproxEqAbs(distancia, hit.Distancia, tolerancia);
    try expectVec(punto, hit.Punto);
    try expectVec(normal, hit.Normal);
}

test "init calcula los límites a partir del centro y el tamaño" {
    const c = Cube.init(v3(2, -3, 4), 6, material_prueba);
    try expectVec(v3(-1, -6, 1), c.min);
    try expectVec(v3(5, 0, 7), c.max);
}

test "rayo desde afuera golpea la cara de entrada" {
    // Rayo diagonal en el plano xy dirigido al centro: cruza el plano x = -1
    // (t = 3 / 0.8 = 3.75) después del plano y = -1 (t = 2 / 0.6 ≈ 3.33),
    // así que la última losa en la que entra es la de x.
    try expectHit(
        cubo_unitario,
        v3(-4, -3, 0),
        v3(0.8, 0.6, 0),
        3.75,
        v3(-1, -0.75, 0),
        v3(-1, 0, 0),
    );
}

test "rayo que no golpea el cubo" {
    // Diagonal que pasa por encima de la esquina: los intervalos de x y de y
    // no se traslapan.
    const d = v3(1, 1, 0).normalize();
    try testing.expect(cubo_unitario.intersect(v3(-5, 0, 0), d) == null);

    // El cubo queda detrás del origen del rayo.
    try testing.expect(cubo_unitario.intersect(v3(0, 0, 5), v3(0, 0, 1)) == null);
}

test "rayo paralelo a un eje y fuera del slab" {
    // La dirección no tiene componente en x ni en y, y el origen
    // está fuera del slab de y (y = 2 > 1): nunca entra.
    try testing.expect(cubo_unitario.intersect(v3(0, 2, -5), v3(0, 0, 1)) == null);
    // Igual, pero fuera del slab de x (x = -1.5 < -1).
    try testing.expect(cubo_unitario.intersect(v3(-1.5, 0, -5), v3(0, 0, 1)) == null);
}

test "rayo paralelo a un eje y dentro del slab" {
    // Paralelo a los slabs de x y de y, con el origen dentro de ambos:
    // solo el slab de z limita el intervalo.
    try expectHit(
        cubo_unitario,
        v3(0.5, 0.25, -5),
        v3(0, 0, 1),
        4,
        v3(0.5, 0.25, -1),
        v3(0, 0, -1),
    );
    // Origen exactamente sobre un plano del slab paralelo (x = 1).
    // Evita el caso 0 * inf = NaN.
    try expectHit(
        cubo_unitario,
        v3(1, 0, 5),
        v3(0, 0, -1),
        4,
        v3(1, 0, 1),
        v3(0, 0, 1),
    );
}

test "rayo con origen dentro del cubo golpea la cara de salida" {
    // Desde el centro: la normal apunta hacia afuera, en el mismo sentido del rayo.
    try expectHit(cubo_unitario, v3(0, 0, 0), v3(1, 0, 0), 1, v3(1, 0, 0), v3(1, 0, 0));

    // Desde un punto descentrado, hacia el lado lejano.
    try expectHit(cubo_unitario, v3(0.5, 0, 0), v3(-1, 0, 0), 1.5, v3(-1, 0, 0), v3(-1, 0, 0));

    // En diagonal: sale primero por y (t = 0.5 / 0.6) antes que por x (t = 1 / 0.8).
    try expectHit(
        cubo_unitario,
        v3(0, 0.5, 0.25),
        v3(0.8, 0.6, 0),
        0.5 / 0.6,
        v3(0.8 * (0.5 / 0.6), 1, 0.25),
        v3(0, 1, 0),
    );
}

test "rayo que golpea las seis caras de los tres ejes principales" {
    // Cubo desplazado y de lado 2 para comprobar que se usan min y max reales.
    const centro = v3(3, -2, 7);
    const cubo = Cube.init(centro, 2, material_prueba);

    const ejes = [_]Vec3{ v3(1, 0, 0), v3(0, 1, 0), v3(0, 0, 1) };
    for (ejes) |eje| {
        for ([_]f32{ -1, 1 }) |lado| {
            // Normal de la cara que se espera golpear.
            const normal = eje.scale(lado);
            // Origen a 5 unidades del centro, en el lado de esa cara,
            // disparando hacia el centro. La cara está a 1 unidad del centro.
            const origin = centro.add(normal.scale(5));
            const direction = normal.scale(-1);

            try expectHit(cubo, origin, direction, 4, centro.add(normal), normal);
        }
    }
}

test "caja no uniforme definida con min y max" {
    const caja = Cube{
        .min = v3(-1, -2, -3),
        .max = v3(1, 2, 3),
        .material = material_prueba,
    };
    try expectHit(caja, v3(0, 10, 0), v3(0, -1, 0), 8, v3(0, 2, 0), v3(0, 1, 0));
    try expectHit(caja, v3(0, 0, -10), v3(0, 0, 1), 7, v3(0, 0, -3), v3(0, 0, -1));
}

test "cada cara se identifica y su centro tiene UV (0.5, 0.5)" {
    const casos = [_]struct { normal: Vec3, cara: Cara }{
        .{ .normal = v3(1, 0, 0), .cara = .pos_x },
        .{ .normal = v3(-1, 0, 0), .cara = .neg_x },
        .{ .normal = v3(0, 1, 0), .cara = .pos_y },
        .{ .normal = v3(0, -1, 0), .cara = .neg_y },
        .{ .normal = v3(0, 0, 1), .cara = .pos_z },
        .{ .normal = v3(0, 0, -1), .cara = .neg_z },
    };
    for (casos) |c| {
        const hit = cubo_unitario.intersect(c.normal.scale(5), c.normal.scale(-1)) orelse
            return error.TestExpectedHit;
        try testing.expectEqual(c.cara, hit.Cara);
        try testing.expectApproxEqAbs(@as(f32, 0.5), hit.UV.x, tolerancia);
        try testing.expectApproxEqAbs(@as(f32, 0.5), hit.UV.y, tolerancia);
    }
}

test "UV: la esquina superior derecha de cada cara, vista desde afuera, es (1, 1)" {
    // Para cada cara: la esquina que queda arriba a la derecha de quien la mira
    // de frente, con derecha = Up × Forward (la misma convención de la cámara).
    const casos = [_]struct { cara: Cara, esquina: Vec3 }{
        .{ .cara = .pos_x, .esquina = v3(1, 1, 1) },
        .{ .cara = .neg_x, .esquina = v3(-1, 1, -1) },
        .{ .cara = .pos_z, .esquina = v3(-1, 1, 1) },
        .{ .cara = .neg_z, .esquina = v3(1, 1, -1) },
        .{ .cara = .pos_y, .esquina = v3(-1, 1, -1) },
        .{ .cara = .neg_y, .esquina = v3(-1, -1, 1) },
    };
    for (casos) |c| {
        const uv = cubo_unitario.uvEn(c.cara, c.esquina);
        try testing.expectApproxEqAbs(@as(f32, 1), uv.x, tolerancia);
        try testing.expectApproxEqAbs(@as(f32, 1), uv.y, tolerancia);
    }
}

test "UV en una caja no uniforme se normaliza por el tamaño de cada eje" {
    const caja = Cube{ .min = v3(0, 0, 0), .max = v3(4, 2, 8), .material = material_prueba };
    // Rayo hacia +z que golpea la cara -z en x = 1, y = 0.5.
    const hit = caja.intersect(v3(1, 0.5, -3), v3(0, 0, 1)) orelse return error.TestExpectedHit;
    try testing.expectEqual(Cara.neg_z, hit.Cara);
    try testing.expectApproxEqAbs(@as(f32, 0.25), hit.UV.x, tolerancia);
    try testing.expectApproxEqAbs(@as(f32, 0.25), hit.UV.y, tolerancia);
}

test "UV alineadas al mundo con tile repiten la textura por unidad" {
    const losa = Cube{ .min = v3(-3, -1, -3), .max = v3(3, 0, 3), .material = material_prueba, .tile = 1 };
    // Cara superior en x = 1.25, z = -2.5: u = -x, v = -z.
    const hit = losa.intersect(v3(1.25, 5, -2.5), v3(0, -1, 0)) orelse return error.TestExpectedHit;
    try testing.expectEqual(Cara.pos_y, hit.Cara);
    try testing.expectApproxEqAbs(@as(f32, -1.25), hit.UV.x, tolerancia);
    try testing.expectApproxEqAbs(@as(f32, 2.5), hit.UV.y, tolerancia);

    // Con tile = 2 la misma posición avanza la mitad.
    var losa2 = losa;
    losa2.tile = 2;
    const uv2 = losa2.uvEn(.pos_y, v3(1.25, 0, -2.5));
    try testing.expectApproxEqAbs(@as(f32, -0.625), uv2.x, tolerancia);
    try testing.expectApproxEqAbs(@as(f32, 1.25), uv2.y, tolerancia);
}

test "dirección cero no produce intersección" {
    try testing.expect(cubo_unitario.intersect(v3(0, 0, 0), v3(0, 0, 0)) == null);
}
