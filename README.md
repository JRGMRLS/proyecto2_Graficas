# Proyecto 2: Diorama con Raytracing

Este proyecto consiste en un raytracer desarrollado en Zig que renderiza un diorama construido con cubos. La escena representa una isla flotante con una cabaña, un árbol, un sendero, ventanas de vidrio, una figura metálica y un farol.

El raytracer calcula la imagen píxel por píxel mediante rayos lanzados desde la cámara. La escena incluye iluminación, sombras, reflexión, refracción, materiales texturizados y un skybox procedural.

## Funcionalidades implementadas

- Rotación del diorama.
- Cámara con acercamiento y alejamiento.
- Cubos con texturas procedurales.
- Diez materiales diferentes.
- Reflexión en el material metálico.
- Refracción y color en el vidrio.
- Sombras.
- Skybox procedural de seis caras.
- Renderizado concurrente.
- Material emisivo para el farol.
- Modo secuencial para comparar el resultado con la concurrencia.

## Controles

| Control | Acción |
|---|---|
| `W`, `A`, `S`, `D` | Mover la cámara |
| `Q`, `E` | Rotar el diorama |
| Rueda del ratón | Acercar o alejar la cámara |
| `+`, `-` | Acercar o alejar la cámara |
| `R` | Activar o desactivar la rotación automática |
| `T` | Cambiar entre renderizado concurrente y secuencial |
| `Esc` | Cerrar el programa |

## Ejecución

```powershell
zig build run -Doptimize=ReleaseFast
```

## Video explicativo
https://youtu.be/Z-ZiBSiqygw
