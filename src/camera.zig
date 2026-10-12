const Vec3 = @import("vec.zig").Vec3;
const std = @import("std");

pub const Camera = struct {
    Postition: Vec3,
    Forward: Vec3,
    Right: Vec3,
    Up: Vec3,

    pub fn init(position: Vec3, target: Vec3) Camera {
        var out = Camera{
            .Forward = .zero(), //Se va a reemplazar
            .Postition = position,
            .Right = .{ .x = 1, .y = 0, .z = 0 },
            .Up = .{ .x = 0, .y = 1, .z = 0 },
        };
        out.lookAt(target);
        return out;
    }

    //https://www.scratchapixel.com/lessons/mathematics-physics-for-computer-graphics/lookat-function//framing-lookat-function.html
    pub fn lookAt(self: *Camera, target: Vec3) void {
        // 100% bien
        self.Forward = target.subtract(self.Postition).normalize();

        // Luego usamos producto cruz para sacar al vector que define
        // a la derecha porque eso nos dará un vector normal al plano
        // definido por forward y algún otro vector, y eso hará que right sea
        // perpendicular a ambos.
        // Esta estimación es 2-3, porque necesitamos otro vector para sacar el
        // producto cruz y este debe ser up, pero en esta misma función redefine up también.
        // Usamos up, asumiendo que no está muy lejos del nuevo up que calcularemos.
        // El orden del operación importa, si ponemos Forward primero, calcularmos Left, no Right
        self.Right = Vec3.crossProduct(self.Up, self.Forward).normalize();

        // En este caso, Up sí cumplirá con ser 100% perpendicular a right y forward,
        // pero tiene el error transitivo de right.
        // De nuevo, el orden importa, si ponemos Right primero, calcularmos Down, no Up
        self.Up = Vec3.crossProduct(self.Forward, self.Right).normalize();
    }
};
