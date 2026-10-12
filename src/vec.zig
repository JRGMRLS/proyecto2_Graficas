//! Vectores propios en Zig puro. Raylib se reserva para ventana, entrada,
//! imágenes y presentación; toda la matemática del trazador de rayos vive aquí
//! (sin llamadas a C, se inlinea y sirve en comptime).

const std = @import("std");

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub inline fn zero() Vec3 {
        return .{ .x = 0, .y = 0, .z = 0 };
    }

    pub inline fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub inline fn subtract(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub inline fn scale(a: Vec3, k: f32) Vec3 {
        return .{ .x = a.x * k, .y = a.y * k, .z = a.z * k };
    }

    pub inline fn dotProduct(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub inline fn crossProduct(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub inline fn length(a: Vec3) f32 {
        return @sqrt(a.dotProduct(a));
    }

    /// Vector cero si la longitud es cero (no produce NaN).
    pub inline fn normalize(a: Vec3) Vec3 {
        const l = a.length();
        if (l == 0) return a;
        return a.scale(1 / l);
    }

    /// Producto componente a componente (filtros de color).
    pub inline fn mul(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
    }
};

test "operaciones básicas de Vec3" {
    const a = Vec3{ .x = 1, .y = 2, .z = 3 };
    const b = Vec3{ .x = 4, .y = -5, .z = 6 };
    try std.testing.expectEqual(@as(f32, 12), a.dotProduct(b));
    const c = a.crossProduct(b);
    try std.testing.expectEqual(@as(f32, 0), c.dotProduct(a));
    try std.testing.expectEqual(@as(f32, 0), c.dotProduct(b));
    try std.testing.expectApproxEqAbs(@as(f32, 1), a.normalize().length(), 1e-6);
    try std.testing.expectEqual(Vec3.zero(), Vec3.zero().normalize());
}
