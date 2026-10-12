const Sphere = @import("sphere.zig").Sphere;
const Cube = @import("cube.zig").Cube;
const Intersect = @import("raytracer.zig").Intersect;
const Golpe = @import("raytracer.zig").Golpe;
const Material = @import("raytracer.zig").Material;
const Vec3 = @import("vec.zig").Vec3;

const tipo = enum {
    Sphere,
    Cube,
};

pub const Forma = union(tipo) {
    Sphere: Sphere,
    Cube: Cube,

    pub fn intersect(self: Forma, origin: Vec3, direction: Vec3) ?Intersect {
        return switch (self) {
            .Sphere => |a| a.intersect(origin, direction),
            .Cube => |a| a.intersect(origin, direction),
        };
    }

    /// Solo la geometría del impacto; ver `Cube.golpe`.
    pub fn golpe(self: *const Forma, origin: Vec3, direction: Vec3) ?Golpe {
        return switch (self.*) {
            .Sphere => |*a| a.golpe(origin, direction),
            .Cube => |*a| a.golpe(origin, direction),
        };
    }

    /// Completa un `Golpe` (de esta misma forma) con punto, normal y UV.
    pub fn completar(self: *const Forma, g: Golpe, origin: Vec3, direction: Vec3) Intersect {
        return switch (self.*) {
            .Sphere => |*a| a.completar(g, origin, direction),
            .Cube => |*a| a.completar(g, origin, direction),
        };
    }

    pub fn material(self: *const Forma) *const Material {
        return switch (self.*) {
            .Sphere => |*a| &a.material,
            .Cube => |*a| &a.material,
        };
    }
};
