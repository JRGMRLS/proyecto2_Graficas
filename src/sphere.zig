const std = @import("std");
const Vec3 = @import("vec.zig").Vec3;
const Intersect = @import("raytracer.zig").Intersect;
const Material = @import("raytracer.zig").Material;
const Golpe = @import("raytracer.zig").Golpe;

pub const Sphere = struct {
    center: Vec3,
    radius: f32,
    material: Material,

    /// Distancia mínima para aceptar un impacto (misma idea que en Cube).
    const epsilon: f32 = 1e-4;

    pub fn intersect(self: Sphere, origin: Vec3, direction: Vec3) ?Intersect {
        const g = self.golpe(origin, direction) orelse return null;
        return self.completar(g, origin, direction);
    }

    pub fn golpe(self: *const Sphere, origin: Vec3, direction: Vec3) ?Golpe {
        //https://en.wikipedia.org/wiki/Line%E2%80%93sphere_intersection
        // origin - center
        const center_to_origin = origin.subtract(self.center);

        // Estos son a,b y c como en ax^2 + bx + c = 0
        // a = direction·direction siempre es 1 si direction está normalizado.
        const b = 2 * direction.dotProduct(center_to_origin);
        const c = center_to_origin.dotProduct(center_to_origin) - self.radius * self.radius;

        const discriminante = b * b - 4.0 * c;
        if (discriminante < 0) return null;

        // Las dos soluciones, t0 <= t1:
        //   t0: donde el rayo entra a la esfera.
        //   t1: donde el rayo sale de la esfera.
        const raiz = @sqrt(discriminante);
        const t0 = (-b - raiz) / 2;
        const t1 = (-b + raiz) / 2;

        // Si t0 es positivo el origen está afuera y golpeamos la entrada.
        // Si t0 <= 0 < t1 el origen está dentro (por ejemplo, un rayo
        // refractado) y el impacto válido es la salida.
        // Si ambas son negativas la esfera está detrás del rayo.
        const solucion = if (t0 > epsilon) t0 else if (t1 > epsilon) t1 else return null;
        return .{ .distancia = solucion };
    }

    pub fn completar(self: *const Sphere, g: Golpe, origin: Vec3, direction: Vec3) Intersect {
        const point = origin.add(direction.scale(g.distancia));
        // La normal siempre apunta hacia afuera, igual que en Cube; quien
        // la usa decide si invertirla según el lado por el que llega el rayo.
        const norm = point.subtract(self.center).scale(1 / self.radius);
        return .{
            .Material = &self.material,
            .Distancia = g.distancia,
            .Normal = norm,
            .Punto = point,
        };
    }
};

// ---------------------------------------------------------------------------
// Pruebas
// ---------------------------------------------------------------------------

const testing = std.testing;
const tolerancia: f32 = 1e-4;

const esfera_unitaria = Sphere{
    .center = .{ .x = 0, .y = 0, .z = 0 },
    .radius = 1,
    .material = .{
        .Color = .{ .x = 1, .y = 1, .z = 1 },
        .Especular = 0,
        .Refractive_index = 1,
        .Propiedades = .{ .Albedo = 1, .Especular = 0, .Reflectividad = 0, .Transparencia = 0 },
    },
};

test "esfera: desde afuera golpea la entrada" {
    const hit = esfera_unitaria.intersect(.{ .x = 0, .y = 0, .z = -5 }, .{ .x = 0, .y = 0, .z = 1 }) orelse return error.TestExpectedHit;
    try testing.expectApproxEqAbs(@as(f32, 4), hit.Distancia, tolerancia);
    try testing.expectApproxEqAbs(@as(f32, -1), hit.Normal.z, tolerancia);
}

test "esfera: desde adentro golpea la salida con normal hacia afuera" {
    const hit = esfera_unitaria.intersect(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = 1 }) orelse return error.TestExpectedHit;
    try testing.expectApproxEqAbs(@as(f32, 1), hit.Distancia, tolerancia);
    try testing.expectApproxEqAbs(@as(f32, 1), hit.Normal.z, tolerancia);
}

test "esfera: detrás del rayo no hay impacto" {
    try testing.expect(esfera_unitaria.intersect(.{ .x = 0, .y = 0, .z = 5 }, .{ .x = 0, .y = 0, .z = 1 }) == null);
}
