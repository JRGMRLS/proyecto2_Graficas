const std = @import("std");
const builtin = @import("builtin");

const rl = @import("raylib");
const Vec3 = @import("vec.zig").Vec3;
const Framebuffer = @import("framebuffer.zig").Framebuffer;
const Forma = @import("formas.zig").Forma;
const diorama = @import("diorama.zig");
const Escena = @import("escena.zig").Escena;
const Camera = @import("camera.zig").Camera;
const Light = @import("raytracer.zig").Light;
const Intersect = @import("raytracer.zig").Intersect;
const Material = @import("raytracer.zig").Material;
const reflejar = @import("raytracer.zig").reflejar;
const refractar = @import("raytracer.zig").refractar;
const desplazar = @import("raytracer.zig").desplazar;
const epsilon_rayo = @import("raytracer.zig").epsilon_rayo;
const Skybox = @import("skybox.zig").Skybox;

const htmlColor = @import("cute_colors.zig").htmlColor;
const V3FromColor = @import("raytracer.zig").V3FromColor;
const V3ToColor = @import("raytracer.zig").V3ToColor;

const Clock = std.Io.Clock.real;

const width = 640;
const height = 480;

// Luz ambiental: evita que las caras sin luz directa o en sombra queden
// completamente negras y se pierda la forma de los bloques.
const luz_ambiental: f32 = 0.35;

// Rebotes máximos de un rayo (reflexión o refracción). Con 3 alcanza para
// entrar a un vidrio, salir por el otro lado y sombrear lo que hay detrás.
const profundidad_max: u32 = 3;

pub fn main() !void {
    var alloc = switch (builtin.mode) {
        .Debug, .ReleaseSafe => std.heap.DebugAllocator(.{}).init,
        .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
    };
    const gpa: std.mem.Allocator = switch (builtin.mode) {
        .Debug, .ReleaseSafe => alloc.allocator(),
        .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
    };
    defer switch (builtin.mode) {
        .Debug, .ReleaseSafe => _ = alloc.deinit(),
        .ReleaseFast, .ReleaseSmall => {},
    };

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var framebuffer = try Framebuffer.init(
        gpa,
        width,
        height,
        htmlColor("#b8bec9"),
        .white,
    );

    rl.setTraceLogLevel(.warning);
    rl.initWindow(width, height, "Raytracer!!!");
    defer rl.closeWindow();
    // Declarado después de closeWindow, se ejecuta antes: la textura de la
    // GPU se libera con la ventana todavía abierta.
    defer framebuffer.deinit(gpa);
    rl.setTargetFPS(60);

    var last_frame_time = Clock.now(io);
    var delta: i64 = 1;

    // Texturas y materiales se crean una sola vez. `texturas` no se mueve
    // de aquí porque los materiales guardan punteros a sus campos.
    var texturas = try diorama.Texturas.init(gpa);
    defer texturas.deinit(gpa);
    const materiales = diorama.Materiales.init(&texturas);

    // Cubemap del cielo: se genera una sola vez y queda en memoria hasta
    // salir. Los rayos que no golpean nada solo lo muestrean.
    var skybox = try Skybox.init(gpa);
    defer skybox.deinit(gpa);

    var construccion = try diorama.buildDiorama(gpa, &materiales);
    defer construccion.deinit();
    const objetos = construccion.formas.items;
    std.debug.print("Diorama: {d} cubos\n", .{objetos.len});

    // Sol alto, desde el lado de la entrada (+z) y un poco hacia +x:
    // ilumina el frente de la cabaña y proyecta sombras hacia atrás a la derecha.
    const lights = [_]Light{
        .{
            .Color = V3FromColor(htmlColor("#fff4e0")),
            .Intensity = 1.25,
            .Position = .{ .x = 6, .y = 19, .z = 22 },
        },
    };

    // Cámara orbital alrededor del origen. La vista inicial es de tres cuartos,
    // desde arriba y desde la esquina (-x, +z), donde se ven la entrada,
    // el sendero, el árbol y la escultura.
    const camera_target: Vec3 = .{ .x = 0, .y = -1, .z = 0 };

    // Zoom: `distancia_objetivo` cambia con la rueda o las teclas y
    // `camera_distance` la sigue con un suavizado exponencial.
    const distancia_min: f32 = 12;
    const distancia_max: f32 = 45;
    const distancia_inicial: f32 = 23;
    var distancia_objetivo: f32 = distancia_inicial;
    var camera_distance: f32 = distancia_inicial;
    // Con + / - sostenido la distancia se multiplica por e^(±1.2·dt):
    // ~3.3 veces por segundo, igual de rápido de cerca que de lejos.
    const velocidad_zoom: f32 = 1.2;
    // Cada muesca de la rueda acerca (o aleja) un 10 %.
    const factor_rueda: f32 = 0.9;
    // Qué tan rápido la distancia real alcanza a la objetivo (1/s).
    const suavizado_zoom: f32 = 12;

    var camera: Camera = .init(.{ .x = 0, .y = 0, .z = distancia_inicial }, camera_target);

    const cameraTurnSpeed: f32 = std.math.pi / 2.0;
    var camera_x_angle: f32 = 3.0 * std.math.pi / 4.0;
    var camera_y_angle: f32 = 0.45;

    const camera_y_angle_max = std.math.pi / 4.0;
    const camera_y_angle_min = -camera_y_angle_max;

    // Rotación del diorama alrededor del eje Y (radianes). Es independiente
    // de la cámara: no cambia su posición ni su orientación.
    const velocidad_rotacion_diorama: f32 = std.math.pi / 2.0;
    var angulo_diorama: f32 = 0;
    var giro_automatico = false;

    // Los cubos se construyen una sola vez; girar el diorama solo actualiza
    // la rotación de la escena.
    var escena = Escena.init(objetos);

    // Un cuadro puede tardar bastante en renderizarse en CPU. Se limita dt
    // para que una pausa larga (mover la ventana, por ejemplo) no produzca
    // un salto enorme en la rotación o el zoom.
    const dt_max: f32 = 0.25;

    // ------------------------------------------------------------------
    // CONTROLES (documentación temporal)
    //   A / D          Orbitar la cámara a la izquierda / derecha.
    //   W / S          Subir / bajar la cámara (limitado a ±45°).
    //   Q / E          Girar el diorama sobre su eje Y (la cámara no se mueve).
    //   R              Activar / desactivar el giro automático del diorama.
    //   T              Alternar render secuencial / concurrente.
    //   Rueda          Acercar / alejar la cámara.
    //   + / -          Acercar / alejar la cámara (teclado principal o numérico;
    //                  en teclados en español también funcionan las teclas
    //                  físicas donde están + y -).
    //   Esc            Salir.
    // Todas las velocidades se multiplican por dt, así que no dependen de los FPS.
    // ------------------------------------------------------------------

    // Hilos de render: uno por núcleo lógico, con tope. Io.Threaded reutiliza
    // sus hilos entre cuadros, así que no se crean hilos nuevos por cuadro.
    const hilos: usize = blk: {
        const n = std.Thread.getCpuCount() catch 1;
        break :blk std.math.clamp(n, 1, max_hilos);
    };
    var modo: ModoRender = .concurrente;
    std.debug.print("Hilos de render: {d}\n", .{hilos});

    // Verificación: el render concurrente debe dar exactamente la misma
    // imagen que el secuencial. Se comparan byte a byte y se imprimen tiempos.
    {
        const ref = try gpa.alloc(rl.Color, framebuffer.pixels.len);
        defer gpa.free(ref);
        camera.lookAt(camera_target);
        const ctx = contexto(&framebuffer, escena, &lights, &skybox, camera);
        const ta = Clock.now(io);
        renderSecuencial(ref, ctx);
        const tb = Clock.now(io);
        renderConcurrente(io, framebuffer.pixels, ctx, hilos);
        const tc = Clock.now(io);
        const iguales = std.mem.eql(u8, std.mem.sliceAsBytes(ref), std.mem.sliceAsBytes(framebuffer.pixels));
        std.debug.print("Secuencial: {d} ms | Concurrente: {d} ms | imágenes {s}\n", .{
            @divTrunc(ta.durationTo(tb).toMicroseconds(), 1000),
            @divTrunc(tb.durationTo(tc).toMicroseconds(), 1000),
            if (iguales) "idénticas" else "DISTINTAS",
        });
    }

    var ultimo_estado: ?EstadoVista = null;

    while (!rl.windowShouldClose()) {
        defer {
            const now = Clock.now(io);
            delta = last_frame_time.durationTo(now).toMicroseconds();
            last_frame_time = now;
        }
        const dt: f32 = @min(dt_max, @as(f32, @floatFromInt(delta)) / 1_000_000);

        // Órbita de la cámara.
        if (rl.isKeyDown(.a)) {
            camera_x_angle += cameraTurnSpeed * dt;
        }
        if (rl.isKeyDown(.d)) {
            camera_x_angle -= cameraTurnSpeed * dt;
        }
        if (rl.isKeyDown(.w)) {
            camera_y_angle += cameraTurnSpeed * dt;
            camera_y_angle = @max(camera_y_angle_min, @min(camera_y_angle_max, camera_y_angle));
        }
        if (rl.isKeyDown(.s)) {
            camera_y_angle -= cameraTurnSpeed * dt;
            camera_y_angle = @max(camera_y_angle_min, @min(camera_y_angle_max, camera_y_angle));
        }

        // Rotación del diorama.
        if (rl.isKeyDown(.q)) {
            angulo_diorama += velocidad_rotacion_diorama * dt;
        }
        if (rl.isKeyDown(.e)) {
            angulo_diorama -= velocidad_rotacion_diorama * dt;
        }
        if (rl.isKeyPressed(.r)) giro_automatico = !giro_automatico;
        if (giro_automatico) angulo_diorama += velocidad_rotacion_diorama * 0.5 * dt;
        // Mantiene el ángulo en [-π, π) para no perder precisión con el tiempo.
        // Solo se ajusta al salirse: aplicar @mod en cada cuadro metería
        // errores de redondeo que harían girar el diorama sin tocar nada.
        if (@abs(angulo_diorama) > std.math.pi) {
            angulo_diorama = std.math.wrap(angulo_diorama, std.math.pi);
        }
        if (angulo_diorama != escena.rotacion.angulo) {
            escena.rotacion = .init(angulo_diorama);
        }

        // Zoom. La rueda da un salto por muesca (es un evento, no algo que se
        // mantiene presionado); las teclas se integran con dt.
        const rueda = rl.getMouseWheelMove();
        if (rueda != 0) {
            distancia_objetivo *= std.math.pow(f32, factor_rueda, rueda);
        }
        const acercar = rl.isKeyDown(.equal) or rl.isKeyDown(.kp_add) or rl.isKeyDown(.right_bracket);
        const alejar = rl.isKeyDown(.minus) or rl.isKeyDown(.kp_subtract) or rl.isKeyDown(.slash);
        if (acercar) distancia_objetivo *= @exp(-velocidad_zoom * dt);
        if (alejar) distancia_objetivo *= @exp(velocidad_zoom * dt);
        distancia_objetivo = std.math.clamp(distancia_objetivo, distancia_min, distancia_max);
        // Acercamiento exponencial independiente de los FPS: en cada cuadro se
        // recorre la fracción 1 - e^(-k·dt) de lo que falta.
        camera_distance += (distancia_objetivo - camera_distance) * (1 - @exp(-suavizado_zoom * dt));
        // El suavizado nunca llega exacto al objetivo: al quedar a menos de
        // 0.1 % se fija, para que la imagen deje de cambiar y de re-renderizarse.
        if (@abs(distancia_objetivo - camera_distance) < 1e-3 * distancia_objetivo) camera_distance = distancia_objetivo;

        // Coordenadas esféricas: la distancia al objetivo es siempre
        // camera_distance, sin importar la inclinación.
        const horizontal = @cos(camera_y_angle) * camera_distance;
        camera.Postition.x = camera_target.x + @cos(camera_x_angle) * horizontal;
        camera.Postition.y = camera_target.y + @sin(camera_y_angle) * camera_distance;
        camera.Postition.z = camera_target.z + @sin(camera_x_angle) * horizontal;

        camera.lookAt(camera_target);

        if (rl.isKeyPressed(.t)) {
            modo = if (modo == .concurrente) .secuencial else .concurrente;
            std.debug.print("Render: {s}\n", .{@tagName(modo)});
            ultimo_estado = null;
        }

        // Solo se vuelve a trazar si cambió algo que afecta la imagen: la
        // cámara (posición y orientación) o la rotación del diorama. Si no,
        // se vuelve a presentar la misma textura sin tocar la CPU.
        const estado: EstadoVista = .{
            .camara = camera.Postition,
            .adelante = camera.Forward,
            .angulo_diorama = escena.rotacion.angulo,
        };
        const cambio = ultimo_estado == null or !std.meta.eql(ultimo_estado.?, estado);
        if (cambio) {
            switch (modo) {
                .secuencial => renderSecuencial(framebuffer.pixels, contexto(&framebuffer, escena, &lights, &skybox, camera)),
                .concurrente => renderConcurrente(io, framebuffer.pixels, contexto(&framebuffer, escena, &lights, &skybox, camera), hilos),
            }
            ultimo_estado = estado;
        }

        try framebuffer.swap_buffers(cambio);
    }
}

/// Todo lo que determina la imagen además de la escena fija y las luces.
const EstadoVista = struct {
    camara: Vec3,
    adelante: Vec3,
    angulo_diorama: f32,
};

const ModoRender = enum { secuencial, concurrente };

/// Tope de hilos de render.
const max_hilos: usize = 16;

/// Filas por tarea. Pequeño para balancear la carga (las filas con cristal
/// cuestan más) y grande para que el contador atómico casi no se dispute.
const filas_por_banda: usize = 8;

/// Todo lo que el render necesita. Es de solo lectura mientras corren los hilos.
const Contexto = struct {
    objects: Escena,
    lights: []const Light,
    cielo: *const Skybox,
    camera: Camera,
};

fn contexto(target: *const Framebuffer, objects: Escena, lights: []const Light, cielo: *const Skybox, camera: Camera) Contexto {
    std.debug.assert(target.width == width and target.height == height);
    return .{ .objects = objects, .lights = lights, .cielo = cielo, .camera = camera };
}

/// Alternativa secuencial: una sola llamada que pinta todas las filas.
fn renderSecuencial(pixels: []rl.Color, ctx: Contexto) void {
    renderFilas(pixels, 0, ctx);
}

/// Render por bandas de filas repartidas entre varios hilos.
///
/// Cada tarea toma el siguiente número de banda de un contador atómico y
/// escribe solo en el sub-slice de `pixels` de esa banda. Las bandas no se
/// solapan y cada una la toma una sola tarea (fetchAdd da números únicos),
/// así que no hay dos escrituras a la misma memoria. `ctx` solo se lee.
/// `Group.await` espera a todas las tareas y sincroniza (acquire) sus
/// escrituras antes de que el hilo principal use el buffer.
fn renderConcurrente(io: std.Io, pixels: []rl.Color, ctx: Contexto, hilos: usize) void {
    var siguiente = std.atomic.Value(usize).init(0);
    var grupo: std.Io.Group = .init;
    // `async` ejecuta la tarea en un hilo del pool de Io.Threaded o, si no
    // hay hilo libre, en el hilo que llama; ambos casos son correctos.
    for (0..hilos) |_| grupo.async(io, trabajador, .{ pixels, ctx, &siguiente });
    grupo.await(io) catch {};
}

fn trabajador(pixels: []rl.Color, ctx: Contexto, siguiente: *std.atomic.Value(usize)) void {
    const bandas = (height + filas_por_banda - 1) / filas_por_banda;
    while (true) {
        const banda = siguiente.fetchAdd(1, .monotonic);
        if (banda >= bandas) return;
        const y0 = banda * filas_por_banda;
        const y1: usize = @min(y0 + filas_por_banda, @as(usize, height));
        renderFilas(pixels[y0 * @as(usize, width) .. y1 * @as(usize, width)], y0, ctx);
    }
}

/// Pinta en `destino` las filas que empiezan en la fila `y0` de la imagen.
/// Solo escribe dentro de `destino`; no llama a Raylib.
fn renderFilas(destino: []rl.Color, y0: usize, ctx: Contexto) void {
    const width_f32: f32 = width;
    const height_f32: f32 = height;

    const aspect_ratio = width_f32 / height_f32;
    const FOV = std.math.pi / 3.0;
    const perspective_scale = @tan(FOV * 0.5);
    const camera = ctx.camera;

    const n_filas = destino.len / width;
    for (0..n_filas) |fila| {
        const screen_y = y0 + fila;
        for (0..width) |screen_x| {
            const x_f32: f32 = @floatFromInt(screen_x);
            const y_f32: f32 = @floatFromInt(screen_y);

            const x_minus1_to_1 = (x_f32 * 2) / width_f32 - 1;
            const y_minus1_to_1 = 1 - (y_f32 * 2) / height_f32;

            const x_direction = x_minus1_to_1 * aspect_ratio * perspective_scale;
            const y_direction = y_minus1_to_1 * perspective_scale;

            const direction_from_camera = (Vec3{
                .x = x_direction,
                .y = y_direction,
                .z = 1,
            }).normalize();

            const direction = Vec3{
                .x = direction_from_camera.x * camera.Right.x + direction_from_camera.y * camera.Up.x + direction_from_camera.z * camera.Forward.x,
                .y = direction_from_camera.x * camera.Right.y + direction_from_camera.y * camera.Up.y + direction_from_camera.z * camera.Forward.y,
                .z = direction_from_camera.x * camera.Right.z + direction_from_camera.y * camera.Up.z + direction_from_camera.z * camera.Forward.z,
            };

            const col = cast_ray(camera.Postition, direction, ctx.objects, ctx.lights, ctx.cielo, profundidad_max);
            destino[fila * width + screen_x] = V3ToColor(col);
        }
    }
}

fn cast_ray(origin: Vec3, direction: Vec3, objects: Escena, lights: []const Light, cielo: *const Skybox, profundidad: u32) Vec3 {
    // Todo lo que sale de aquí (punto, normal) ya está en coordenadas del
    // mundo, así que la iluminación usa las luces sin transformarlas.
    // Si el rayo no golpea nada se ve el cielo en esa dirección. Esto también
    // aplica a los rayos reflejados y refractados, así que el skybox aparece
    // en espejos y a través del vidrio.
    const hit = objects.intersectar(origin, direction) orelse return cielo.muestrear(direction);
    const mat = hit.Material;

    // Color de la superficie en el punto: se muestrea la textura con las UV
    // de la intersección, o se usa el color base si no hay textura.
    // Solo lee memoria ya preparada; no carga ni asigna nada.
    const base_color = mat.colorEn(hit.UV, hit.Cara);

    // hit.Normal apunta hacia afuera del objeto. Si el rayo viene de adentro
    // (un rayo refractado dentro del vidrio) la normal de sombreado se
    // invierte para que mire hacia el lado del que llega el rayo.
    const entrando = direction.dotProduct(hit.Normal) < 0;
    const normal = if (entrando) hit.Normal else hit.Normal.scale(-1);

    // Desde el punto a la cámara
    const view_direction = direction.scale(-1);

    // Reparto de la energía: kr se refleja, kt se transmite y el resto se
    // sombrea localmente. Sin profundidad restante no se lanzan más rayos y
    // el material se trata como opaco.
    const kr: f32 = if (profundidad > 0) std.math.clamp(mat.Propiedades.Reflectividad, 0, 1) else 0;
    const kt: f32 = if (profundidad > 0) std.math.clamp(mat.Propiedades.Transparencia, 0, 1 - kr) else 0;
    const kd = 1 - kr - kt;

    // Luz ambiental (no depende de las luces ni de las sombras).
    var difuso = base_color.scale(luz_ambiental * mat.Propiedades.Albedo);
    var especular: Vec3 = .zero();

    for (lights) |light| {
        // Dirección desde el punto hacia la luz (se normaliza una sola vez:
        // la distancia y la dirección también las usa el rayo de sombra).
        const hacia_luz = light.Position.subtract(hit.Punto);
        const distancia_luz = hacia_luz.length();
        const light_dir = hacia_luz.scale(1 / distancia_luz);

        // Luz detrás de la superficie: ni difuso ni especular.
        const n_dot_l = normal.dotProduct(light_dir);
        if (n_dot_l <= 0) continue;

        // Cuánta luz llega (1 libre, 0 en sombra, color si pasa por vidrio).
        const paso = luz_visible(hit.Punto, normal, light_dir, distancia_luz, objects);
        if (paso.x <= 0 and paso.y <= 0 and paso.z <= 0) continue;

        // Color de la luz que llega al punto, ya filtrado por la sombra.
        const luz = light.Color.mul(paso).scale(light.Intensity);

        // Reflexión difusa (Lambert): depende del ángulo entre la normal y la luz
        difuso = difuso.add(base_color.mul(luz).scale(n_dot_l * mat.Propiedades.Albedo));

        // Reflexión especular (Phong): la luz reflejada R = 2(N·L)N - L,
        // que es reflejar(-L, N), comparada con la dirección a la cámara.
        const reflection_dir = reflejar(light_dir.scale(-1), normal);
        const specular_angle = @max(0, reflection_dir.dotProduct(view_direction));
        const specular_intensity = std.math.pow(f32, specular_angle, mat.Especular);
        especular = especular.add(luz.scale(specular_intensity * mat.Propiedades.Especular));
    }

    // Emisión propia (lámparas), la parte local y el brillo especular. El
    // brillo no se escala por kd: en el vidrio y el metal es justo lo que
    // se debe notar.
    var color = base_color.scale(mat.Emision);
    color = color.add(difuso.scale(kd));
    color = color.add(especular);

    // Refracción. Si no hay dirección refractada (reflexión interna total)
    // toda la energía transmitida se suma a la reflejada.
    var peso_reflejo = kr;
    if (kt > 0) {
        if (refractar(direction, hit.Normal, mat.Refractive_index)) |refract_direction| {
            const new_og = desplazar(hit.Punto, hit.Normal, refract_direction);
            var refract_color = cast_ray(new_og, refract_direction, objects, lights, cielo, profundidad - 1);
            // Al entrar, el vidrio tiñe ligeramente la luz que lo atraviesa.
            // Solo se aplica en la entrada para no teñir dos veces.
            if (entrando) {
                const filtro = Material.tinte(base_color);
                refract_color = refract_color.mul(filtro);
            }
            color = color.add(refract_color.scale(kt));
        } else {
            peso_reflejo += kt;
        }
    }

    // Reflexión especular perfecta (espejo).
    if (peso_reflejo > 0) {
        const reflect_direction = reflejar(direction, normal);
        const new_og = desplazar(hit.Punto, normal, reflect_direction);
        const reflect_color = cast_ray(new_og, reflect_direction, objects, lights, cielo, profundidad - 1);
        color = color.add(reflect_color.scale(peso_reflejo));
    }

    return color;
}

/// Fracción de la luz (por canal) que llega al punto desde la dirección
/// `dir_luz` (unitaria) y la distancia `distancia` ya calculadas.
fn luz_visible(punto: Vec3, normal: Vec3, dir_luz: Vec3, distancia: f32, objects: Escena) Vec3 {
    // El rayo de sombra sale un epsilon sobre la normal (del lado de la luz),
    // no desde el punto exacto: así no se detecta la misma superficie.
    const shadow_origin = punto.add(normal.scale(epsilon_rayo));

    // Solo cuentan los objetos entre el punto y la luz, no los que están
    // más allá de ella.
    return objects.transmision(shadow_origin, dir_luz, distancia);
}

test {
    // Incluye las pruebas de los demás archivos en `zig build test`.
    _ = @import("cube.zig");
    _ = @import("texture.zig");
    _ = @import("diorama.zig");
    _ = @import("escena.zig");
    _ = @import("sphere.zig");
    _ = @import("raytracer.zig");
    _ = @import("skybox.zig");
}
