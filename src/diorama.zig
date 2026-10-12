//! Diorama: isla flotante pixel-art con cabaña, árbol, sendero, escultura
//! metálica y farol. Todo está construido con cajas alineadas a los ejes.
//!
//! Convenciones:
//!   - 1 unidad de mundo = 1 bloque. La mayoría de las cajas usan tile = 1,
//!     así una caja grande se ve como muchos bloques pero cuesta una sola
//!     intersección.
//!   - La superficie de césped está en y = 0 y la isla está centrada en el
//!     origen (x y z entre -7 y 7) para poder rotar la cámara a su alrededor.
//!   - La entrada de la cabaña mira hacia +z; el sendero sale por ahí.

const std = @import("std");
const Vec3 = @import("vec.zig").Vec3;
const Forma = @import("formas.zig").Forma;
const Cube = @import("cube.zig").Cube;
const Material = @import("raytracer.zig").Material;
const V3FromColor = @import("raytracer.zig").V3FromColor;
const htmlColor = @import("cute_colors.zig").htmlColor;
const texture = @import("texture.zig");
const Texture = texture.Texture;

fn v3(x: f32, y: f32, z: f32) Vec3 {
    return .{ .x = x, .y = y, .z = z };
}

// ---------------------------------------------------------------------------
// Texturas
// ---------------------------------------------------------------------------

/// Todas las texturas del diorama. Se generan una vez al iniciar y se liberan
/// al salir. Debe vivir en una dirección fija (los materiales guardan punteros).
pub const Texturas = struct {
    cesped_arriba: Texture,
    cesped_lado: Texture,
    piedra: Texture,
    adoquin: Texture,
    madera: Texture,
    corteza: Texture,
    hojas: Texture,
    tejas: Texture,
    metal: Texture,
    vidrio: Texture,
    lampara: Texture,

    /// Generador de cada campo, emparejado por nombre.
    const generadores = struct {
        const cesped_arriba = texture.pixelart.cespedArriba;
        const cesped_lado = texture.pixelart.cespedLado;
        const piedra = texture.pixelart.piedra;
        const adoquin = texture.pixelart.adoquin;
        const madera = texture.pixelart.madera;
        const corteza = texture.pixelart.corteza;
        const hojas = texture.pixelart.hojas;
        const tejas = texture.pixelart.tejas;
        const metal = texture.pixelart.metal;
        const vidrio = texture.pixelart.vidrio;
        const lampara = texture.pixelart.lampara;
    };

    pub fn init(gpa: std.mem.Allocator) !Texturas {
        var out: Texturas = undefined;
        var creadas: usize = 0;
        // Si alguna falla, se liberan las que ya se habían creado.
        errdefer inline for (std.meta.fields(Texturas), 0..) |campo, i| {
            if (i < creadas) @field(out, campo.name).deinit(gpa);
        };
        inline for (std.meta.fields(Texturas)) |campo| {
            @field(out, campo.name) = try texture.generar(gpa, @field(generadores, campo.name));
            creadas += 1;
        }
        return out;
    }

    pub fn deinit(self: *Texturas, gpa: std.mem.Allocator) void {
        inline for (std.meta.fields(Texturas)) |campo| {
            @field(self, campo.name).deinit(gpa);
        }
    }
};

// ---------------------------------------------------------------------------
// Materiales
// ---------------------------------------------------------------------------

const Propiedades = struct {
    color: Vec3,
    textura: *const Texture,
    textura_arriba: ?*const Texture = null,
    albedo: f32,
    especular: f32,
    exponente: f32,
    reflectividad: f32 = 0,
    transparencia: f32 = 0,
    // 1.0 (aire) cuando el material no es transparente.
    indice_refraccion: f32 = 1.0,
    emision: f32 = 0,
};

fn crearMaterial(p: Propiedades) Material {
    return .{
        .Color = p.color,
        .Textura = p.textura,
        .TexturaArriba = p.textura_arriba,
        .Especular = p.exponente,
        .Refractive_index = p.indice_refraccion,
        .Emision = p.emision,
        .Propiedades = .{
            .Albedo = p.albedo,
            .Especular = p.especular,
            .Reflectividad = p.reflectividad,
            .Transparencia = p.transparencia,
        },
    };
}

pub const Materiales = struct {
    cesped: Material,
    piedra: Material,
    adoquin: Material,
    madera: Material,
    corteza: Material,
    hojas: Material,
    tejas: Material,
    metal: Material,
    vidrio: Material,
    lampara: Material,

    /// `t` debe seguir vivo mientras se usen los materiales.
    pub fn init(t: *const Texturas) Materiales {
        return .{
            // Césped: mate, casi sin brillo. Pasto arriba, tierra a los lados.
            .cesped = crearMaterial(.{
                .color = V3FromColor(htmlColor("#55963a")),
                .textura = &t.cesped_lado,
                .textura_arriba = &t.cesped_arriba,
                .albedo = 0.95,
                .especular = 0.04,
                .exponente = 8,
            }),
            // Piedra de la isla: áspera, un poco de brillo.
            .piedra = crearMaterial(.{
                .color = V3FromColor(htmlColor("#85858b")),
                .textura = &t.piedra,
                .albedo = 0.9,
                .especular = 0.1,
                .exponente = 12,
            }),
            // Adoquín del sendero: piedra pulida por el uso.
            .adoquin = crearMaterial(.{
                .color = V3FromColor(htmlColor("#a8a294")),
                .textura = &t.adoquin,
                .albedo = 0.9,
                .especular = 0.18,
                .exponente = 18,
            }),
            // Madera de tablas (paredes, puerta, piso).
            .madera = crearMaterial(.{
                .color = V3FromColor(htmlColor("#a8744a")),
                .textura = &t.madera,
                .albedo = 0.9,
                .especular = 0.12,
                .exponente = 20,
            }),
            // Corteza (tronco y esquinas de la cabaña): más mate que la madera.
            .corteza = crearMaterial(.{
                .color = V3FromColor(htmlColor("#6e4a2c")),
                .textura = &t.corteza,
                .albedo = 0.9,
                .especular = 0.05,
                .exponente = 10,
            }),
            .hojas = crearMaterial(.{
                .color = V3FromColor(htmlColor("#3c8234")),
                .textura = &t.hojas,
                .albedo = 0.92,
                .especular = 0.06,
                .exponente = 6,
            }),
            // Tejas de barro esmaltado: brillo moderado.
            .tejas = crearMaterial(.{
                .color = V3FromColor(htmlColor("#b04c30")),
                .textura = &t.tejas,
                .albedo = 0.85,
                .especular = 0.25,
                .exponente = 30,
            }),
            // Metal: poco difuso, brillo intenso y concentrado, muy reflectivo.
            .metal = crearMaterial(.{
                .color = V3FromColor(htmlColor("#b8bcc2")),
                .textura = &t.metal,
                .albedo = 0.45,
                .especular = 0.9,
                .exponente = 250,
                .reflectividad = 0.75,
            }),
            // Vidrio de color: casi todo se transmite; índice típico del vidrio.
            .vidrio = crearMaterial(.{
                .color = V3FromColor(htmlColor("#5ebccc")),
                .textura = &t.vidrio,
                .albedo = 0.2,
                .especular = 0.9,
                .exponente = 300,
                .reflectividad = 0.08,
                .transparencia = 0.8,
                .indice_refraccion = 1.5,
            }),
            // Farol: emite luz cálida propia.
            .lampara = crearMaterial(.{
                .color = V3FromColor(htmlColor("#ffe89a")),
                .textura = &t.lampara,
                .albedo = 0.6,
                .especular = 0.3,
                .exponente = 50,
                .emision = 0.9,
            }),
        };
    }
};

// ---------------------------------------------------------------------------
// Construcción de la escena
// ---------------------------------------------------------------------------

pub const Diorama = struct {
    gpa: std.mem.Allocator,
    formas: std.ArrayList(Forma) = .empty,

    pub fn deinit(self: *Diorama) void {
        self.formas.deinit(self.gpa);
    }

    /// Caja entre `min` y `max` con la textura alineada al mundo (1 bloque = 1 unidad).
    pub fn addBox(self: *Diorama, min: Vec3, max: Vec3, mat: Material) !void {
        try self.formas.append(self.gpa, .{ .Cube = .{ .min = min, .max = max, .material = mat, .tile = 1 } });
    }

    /// Cubo con la textura completa en cada cara (para piezas pequeñas).
    pub fn addCube(self: *Diorama, center: Vec3, size: f32, mat: Material) !void {
        try self.formas.append(self.gpa, .{ .Cube = Cube.init(center, size, mat) });
    }

    /// Losa rectangular: x en [x0, x1], z en [z0, z1], y en [y0, y1].
    pub fn addPlatform(self: *Diorama, x0: f32, x1: f32, z0: f32, z1: f32, y0: f32, y1: f32, mat: Material) !void {
        try self.addBox(v3(x0, y0, z0), v3(x1, y1, z1), mat);
    }

    pub const Eje = enum { x, z };

    /// Pared descrita con un mapa de caracteres, fila superior primero:
    ///   '#' madera, 'L' tronco (esquinas), 'W' vidrio, '.' hueco.
    /// Cada celda mide 1x1 y la pared tiene 1 de grosor. `inicio_u` es el inicio
    /// a lo largo de `eje`, `inicio_t` el inicio en el eje perpendicular y `base_y` la base.
    /// Las celdas iguales se agrupan en rectángulos para usar pocas cajas.
    pub fn addWall(self: *Diorama, mats: *const Materiales, mapa: []const []const u8, eje: Eje, inicio_u: f32, inicio_t: f32, base_y: f32) !void {
        const max_celdas = 8;
        const alto = mapa.len;
        const ancho = mapa[0].len;
        if (alto > max_celdas or ancho > max_celdas) return error.ParedDemasiadoGrande;
        for (mapa) |fila| if (fila.len != ancho) return error.ParedIrregular;

        // mapa[0] es la fila de arriba; `celda(f, c)` usa f = 0 para la de abajo.
        const celda = struct {
            fn f(m: []const []const u8, fila: usize, col: usize) u8 {
                return m[m.len - 1 - fila][col];
            }
        }.f;

        var usado = [_][max_celdas]bool{[_]bool{false} ** max_celdas} ** max_celdas;

        for (0..alto) |fila| {
            for (0..ancho) |col| {
                if (usado[fila][col]) continue;
                const c = celda(mapa, fila, col);
                if (c == '.') continue;

                // Crece a lo ancho y luego hacia arriba mientras el carácter sea el mismo.
                var w: usize = 1;
                while (col + w < ancho and !usado[fila][col + w] and celda(mapa, fila, col + w) == c) w += 1;
                var h: usize = 1;
                crecer: while (fila + h < alto) : (h += 1) {
                    for (col..col + w) |k| {
                        if (usado[fila + h][k] or celda(mapa, fila + h, k) != c) break :crecer;
                    }
                }
                for (fila..fila + h) |ff| {
                    for (col..col + w) |cc| usado[ff][cc] = true;
                }

                // Material y rango de grosor (dentro de [0, 1]) de cada tipo de celda.
                const Pieza = struct { mat: Material, g0: f32, g1: f32 };
                const pieza: Pieza = switch (c) {
                    '#' => .{ .mat = mats.madera, .g0 = 0, .g1 = 1 },
                    'L' => .{ .mat = mats.corteza, .g0 = 0, .g1 = 1 },
                    // Panel delgado centrado en el hueco: deja ver el interior
                    // y por ambos lados, lo que servirá para la refracción.
                    'W' => .{ .mat = mats.vidrio, .g0 = 0.4, .g1 = 0.6 },
                    else => return error.CaracterDeParedDesconocido,
                };

                const ua = inicio_u + @as(f32, @floatFromInt(col));
                const ub = ua + @as(f32, @floatFromInt(w));
                const ya = base_y + @as(f32, @floatFromInt(fila));
                const yb = ya + @as(f32, @floatFromInt(h));
                const ta = inicio_t + pieza.g0;
                const tb = inicio_t + pieza.g1;

                switch (eje) {
                    .x => try self.addBox(v3(ua, ya, ta), v3(ub, yb, tb), pieza.mat),
                    .z => try self.addBox(v3(ta, ya, ua), v3(tb, yb, ub), pieza.mat),
                }
            }
        }
    }

    /// Isla escalonada: capa de césped, dos terrazas para el árbol y capas de
    /// piedra cada vez más pequeñas hacia abajo, más rocas flotantes sueltas.
    pub fn addIsland(self: *Diorama, mats: *const Materiales) !void {
        // Superficie principal.
        try self.addPlatform(-7, 7, -7, 7, -1, 0, mats.cesped);
        // Terrazas (diferentes alturas) en la esquina -x, -z.
        try self.addPlatform(-7, -2.5, -7, -1.5, 0, 1, mats.cesped);
        try self.addPlatform(-7, -4, -7, -4, 1, 2, mats.cesped);

        // Capas de piedra, de mayor a menor, algo desplazadas para que
        // la silueta no sea una pirámide perfecta.
        try self.addPlatform(-6, 6, -6, 6, -3, -1, mats.piedra);
        try self.addPlatform(-5, 4, -4, 5, -5, -3, mats.piedra);
        try self.addPlatform(-3, 2, -2, 3, -7, -5, mats.piedra);
        try self.addPlatform(-1.5, 0.5, -0.5, 1.5, -8.5, -7, mats.piedra);
        // Salientes bajo el borde.
        try self.addPlatform(4, 6, -6, -4, -4, -3, mats.piedra);
        try self.addPlatform(-6, -5, 3, 6, -4, -3, mats.piedra);

        // Rocas flotando junto a la isla.
        try self.addCube(v3(-10, -2, 2), 1.2, mats.piedra);
        try self.addCube(v3(6, -4.5, 9.5), 0.9, mats.piedra);
        try self.addCube(v3(-2, -7, 8), 0.8, mats.piedra);
    }

    /// Cabaña de 5x5 con esquinas de tronco, puerta al frente (+z),
    /// ventanas alineadas de frente a atrás y techo de tejas escalonado.
    pub fn addCabin(self: *Diorama, mats: *const Materiales) !void {
        // Huella: x en [-1, 4], z en [-5, 0]. Paredes de 4 bloques de alto.
        const x0 = -1;
        const z0 = -5;

        // Frente (z en [-1, 0]): puerta al centro y dos ventanas.
        try self.addWall(mats, &.{
            "L###L",
            "LW#WL",
            "L#.#L",
            "L#.#L",
        }, .x, x0, -1, 0);
        // Fondo (z en [-5, -4]): ventanas en las mismas columnas que al frente,
        // así se puede ver a través de la cabaña.
        try self.addWall(mats, &.{
            "L###L",
            "LW#WL",
            "L###L",
            "L###L",
        }, .x, x0, z0, 0);
        // Costados (entre las esquinas): una ventana centrada.
        const costado = [_][]const u8{
            "###",
            "#W#",
            "###",
            "###",
        };
        try self.addWall(mats, &costado, .z, -4, -1, 0);
        try self.addWall(mats, &costado, .z, -4, 3, 0);

        // Piso interior.
        try self.addBox(v3(0, 0, -4), v3(3, 0.1, -1), mats.madera);

        // Puerta abierta hacia afuera, girada sobre el marco derecho.
        try self.addBox(v3(1.88, 0, 0.02), v3(2.04, 2, 0.95), mats.madera);

        // Techo a dos aguas escalonado (cumbrera a lo largo de x), con alero.
        try self.addBox(v3(-1.6, 4, -5.6), v3(4.6, 5, 0.6), mats.tejas);
        try self.addBox(v3(-1.6, 5, -4.6), v3(4.6, 6, -0.4), mats.tejas);
        try self.addBox(v3(-1.6, 6, -3.6), v3(4.6, 7, -1.4), mats.tejas);

        // Chimenea de piedra.
        try self.addBox(v3(2.6, 5, -4.4), v3(3.4, 8, -3.6), mats.piedra);
    }

    /// Árbol sobre la terraza alta: tronco y copa en dos niveles.
    pub fn addTree(self: *Diorama, mats: *const Materiales, base: Vec3) !void {
        const x = base.x;
        const y = base.y;
        const z = base.z;
        try self.addBox(v3(x - 0.5, y, z - 0.5), v3(x + 0.5, y + 3.5, z + 0.5), mats.corteza);
        try self.addBox(v3(x - 2, y + 2.5, z - 2), v3(x + 2, y + 4.5, z + 2), mats.hojas);
        try self.addBox(v3(x - 1, y + 4.5, z - 1), v3(x + 1, y + 5.5, z + 1), mats.hojas);
    }

    /// Sendero de losas de adoquín separadas, con un leve zigzag,
    /// desde `inicio` avanzando `n` pasos hacia +z.
    pub fn addPath(self: *Diorama, mats: *const Materiales, inicio: Vec3, n: usize) !void {
        const zigzag = [_]f32{ 0, 0.25, -0.15, 0.2, -0.2, 0.1, -0.05 };
        for (0..n) |i| {
            const fi: f32 = @floatFromInt(i);
            const dx = zigzag[i % zigzag.len];
            const x = inicio.x + dx;
            const z = inicio.z + 0.15 + fi * 1.1;
            try self.addBox(v3(x - 0.45, inicio.y, z), v3(x + 0.45, inicio.y + 0.12, z + 0.85), mats.adoquin);
        }
    }

    /// Escultura de cubos metálicos apilados sobre un pedestal de piedra.
    pub fn addSculpture(self: *Diorama, mats: *const Materiales, base: Vec3) !void {
        const x = base.x;
        const y = base.y;
        const z = base.z;
        try self.addBox(v3(x - 0.7, y, z - 0.7), v3(x + 0.7, y + 0.6, z + 0.7), mats.piedra);
        try self.addCube(v3(x, y + 1.1, z), 1.0, mats.metal);
        try self.addCube(v3(x + 0.12, y + 1.95, z - 0.1), 0.7, mats.metal);
        try self.addCube(v3(x - 0.05, y + 2.5, z + 0.05), 0.4, mats.metal);
    }

    /// Farol: poste de madera con un bloque luminoso encima.
    pub fn addLamp(self: *Diorama, mats: *const Materiales, base: Vec3) !void {
        try self.addBox(v3(base.x - 0.1, base.y, base.z - 0.1), v3(base.x + 0.1, base.y + 1.6, base.z + 0.1), mats.corteza);
        try self.addCube(v3(base.x, base.y + 1.85, base.z), 0.5, mats.lampara);
    }
};

pub fn buildDiorama(gpa: std.mem.Allocator, mats: *const Materiales) !Diorama {
    var d: Diorama = .{ .gpa = gpa };
    errdefer d.deinit();

    try d.addIsland(mats);
    try d.addCabin(mats);
    // Tronco al centro de la terraza alta (y = 2).
    try d.addTree(mats, v3(-5.5, 2, -5.5));
    // De la puerta (x en [1, 2], z = 0) hasta el borde frontal de la isla.
    try d.addPath(mats, v3(1.5, 0, 0), 6);
    // Escultura en la esquina frontal opuesta al árbol.
    try d.addSculpture(mats, v3(4.5, 0, 4.5));
    // Farol junto a la entrada.
    try d.addLamp(mats, v3(-0.5, 0, 0.7));

    return d;
}

// ---------------------------------------------------------------------------
// Pruebas
// ---------------------------------------------------------------------------

test "el diorama se construye sin fugas y con una cantidad moderada de cubos" {
    var t = try Texturas.init(std.testing.allocator);
    defer t.deinit(std.testing.allocator);
    const mats = Materiales.init(&t);
    var d = try buildDiorama(std.testing.allocator, &mats);
    defer d.deinit();

    try std.testing.expect(d.formas.items.len > 30);
    try std.testing.expect(d.formas.items.len < 120);
}

test "addWall agrupa celdas iguales y deja huecos" {
    var t = try Texturas.init(std.testing.allocator);
    defer t.deinit(std.testing.allocator);
    const mats = Materiales.init(&t);
    var d: Diorama = .{ .gpa = std.testing.allocator };
    defer d.deinit();

    // Pared maciza de 3x2: debe quedar en una sola caja.
    try d.addWall(&mats, &.{ "###", "###" }, .x, 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), d.formas.items.len);
    const caja = d.formas.items[0].Cube;
    try std.testing.expectEqual(@as(f32, 3), caja.max.x - caja.min.x);
    try std.testing.expectEqual(@as(f32, 2), caja.max.y - caja.min.y);

    // Con una puerta al centro: dos columnas a los lados + dintel.
    d.formas.clearRetainingCapacity();
    try d.addWall(&mats, &.{ "###", "#.#", "#.#" }, .z, 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 3), d.formas.items.len);
}
