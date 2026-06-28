# MALPHAS - Ecosistema de Consola Virtual y Servidor de Despliegue Pasivo

Malphas es una infraestructura de consola virtual agnóstica de alto rendimiento. Separa de forma radical el motor lógico del proyector gráfico a través de una autopista de memoria compartida de copia cero (Zero-Copy), donde el chasis en Flutter actúa como un rasterizador síncrono coordinado a 120Hz que lee primitivas geométricas directo del *heap* de la memoria RAM mediante punteros y alineación de bytes compatible con C-ABI (`#[repr(C)]`).

---

## 1. Arquitectura de Doble Búfer de Copia Cero

Para evitar el desgarro de pantalla (*screen tearing*) y desvincular el hilo de la interfaz visual (Flutter UI) de la ejecución lógica pesada del motor nativo, la comunicación FFI opera mediante un Doble Búfer de comandos en la memoria RAM compartida física.

### Estructuras FFI en C-ABI (`#[repr(C)]`)

```rust
#[repr(C)]
pub struct DartRenderCommand {
    pub command_type: u8,
    pub layer: u8,
    pub pad: u16, // Padding de 2 bytes para alinear f32 a fronteras de 4 bytes
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub color_rgba: u32,
}

#[repr(C)]
pub struct CoreCommandBuffer {
    pub command_count: u32,
    pub commands: *mut DartRenderCommand,
}

#[repr(C)]
pub struct MalphasDoubleBufferBridge {
    pub buffer_a: CoreCommandBuffer,
    pub buffer_b: CoreCommandBuffer,
    pub atomic_back_index: std::sync::atomic::AtomicU8,
}
```

### Mecánica de Sincronización y Swapping
1. **Asignación:** El chasis de Flutter reserva la memoria física para la estructura `MalphasDoubleBufferBridge` y dos arrays masivos de comandos (`buffer_a` y `buffer_b` de capacidad 2048 comandos cada uno), inicializando `atomic_back_index` en `0`.
2. **Escritura Nativa:** El motor nativo escribe en el buffer apuntado por `atomic_back_index` (el *Back Buffer*).
3. **Commit Atómico:** Una vez que el frame lógico se ha completado, el motor escribe un intercambio atómico (`Compare-And-Swap` o `store` con `Ordering::SeqCst`) incrementando/modificando el índice (`1 - back_index`).
4. **Lectura en Flutter (120Hz):** El ticker de hardware de Flutter lee la variable atómica. El buffer que **no** está siendo escrito por el motor nativo (el *Front Buffer*) se considera inmutable y cerrado. Flutter lee sus comandos directamente mediante punteros y los dibuja en el lienzo.

---

## 2. Especificación del Paquete de Recursos Binario (`.malphas`)

Para dar control total de layout al programador, el chasis y el motor nativo leen los metadatos e índices del paquete binario compilado.

### Estructura de Archivo Fija

| Compensación (Offset) | Tipo | Campo | Descripción |
|---|---|---|---|
| `0` | `[u8; 4]` | `magic` | Cabecera ASCII de identificación obligatoria: `'M', 'L', 'P', 'H'` |
| `4` | `u32` | `manifest_size` | Tamaño en bytes del segmento JSON del Manifiesto |
| `8` | `u32` | `font_metrics_offset` | Dirección de inicio de la Tabla de Métricas de Fuentes |
| `12` | `u32` | `font_atlas_offset` | Dirección de inicio de los píxeles del atlas A8 de Fuentes |
| `16` | `u32` | `table_of_jumps_offset` | Dirección de inicio del Directorio de Saltos de Objetos |
| `20` | `u32` | `table_of_jumps_size` | Tamaño total de la Tabla de Saltos de Objetos |
| `24` | `u32` | `bytecode_offset` | Dirección de inicio del vector de bytecode de comportamiento |
| `28` | `u32` | `bytecode_size` | Tamaño del binario de bytecode de comportamiento |
| `32` | `[u8]` | `manifest_data` | Cadena JSON contigua de configuración serializada en UTF-8 |

### Tabla de Métricas de Glifos
La tabla contiene exactamente 256 bloques fijos contiguos de 16 bytes (uno por cada valor de byte ASCII/extendido). Estructura de cada bloque de métricas:
- `2 bytes` (uint16): Código de carácter.
- `2 bytes` (uint16): Coordenada X en el Atlas de fuentes.
- `2 bytes` (uint16): Coordenada Y en el Atlas de fuentes.
- `2 bytes` (uint16): Ancho del glifo en píxeles.
- `2 bytes` (uint16): Alto del glifo en píxeles.
- `2 bytes` (int16): Desplazamiento horizontal de dibujado (X-offset).
- `2 bytes` (uint16): Avance horizontal acumulado.

---

## 3. Ingesta del Font Atlas y Renderizado por Glifos

### Compilador de Fuentes (Dart)
El compilador rasteriza caracteres tipográficos (fuentes `.ttf` o `.otf`) utilizando un `TextPainter` de Flutter para renderizar dinámicamente glifos ASCII (0-255) en un lienzo de 512x512 píxeles. Posteriormente, se extrae el canal de intensidad de píxeles para generar un Font Atlas en formato plano A8 (8 bits por píxel) de 256 KB.

### Salto de Puntero Asimétrico (*Lookahead Loop*)
Para procesar texto dinámico sin segfaults, el bucle del rasterizador realiza saltos variables según la instrucción:
- **Case 1 (Rectángulo):** Ocupa 1 slot en el búfer de comandos. Se procesa de forma indexada.
- **Case 2 (Texto):** Ocupa 2 slots.
  - El primer slot (`i`) almacena las coordenadas virtuales (`x`, `y`), tamaño/escala (`width`) y color (`color_rgba`).
  - El segundo slot (`i + 1`) almacena un puntero físico directo de 64 bits (`*const u8`) a la dirección de memoria física en la Arena donde reside la cadena UTF-8 terminada en nulo (`\0`).
  - El consumidor de Flutter realiza un salto crítico de paso incrementando el índice por dos (`i += 2`).

---

## 4. Entorno de Ejecución Bytecode Aislado (*Sandbox VM*)

Para esquivar las políticas restrictivas de memoria que prohíben la ejecución de código dinámico compilado localmente en dispositivos móviles (bloqueo W^X), la lógica de comportamiento del paquete se compila en un Bytecode Binario ejecutado por un micro-intérprete lineal en la capa nativa de Rust.

### Estructura de la Arena de Memoria Compartida

| Offset de Arena | Tamaño | Campo | Descripción |
|---|---|---|---|
| `0` | `4 bytes` | `magic` | `'M', 'A', 'M', 'P'` |
| `4` | `4 bytes` | `static_resources_offset` | Offset de carga del binario `.malphas` (típicamente `1024`) |
| `8` | `4 bytes` | `static_resources_size` | Tamaño en bytes cargado del recurso binario |
| `12` | `4 bytes` | `entities_offset` | Dirección de inicio del pool de entidades (típicamente `32`) |
| `16` | `4 bytes` | `entities_count` | Cantidad total de entidades lógicas registradas en la ejecución actual |
| `20` | `4 bytes` | `font_metrics_offset` | Offset absoluto de métricas de fuentes |
| `24` | `4 bytes` | `font_atlas_offset` | Offset absoluto de píxeles del atlas de fuentes |
| `28` | `4 bytes` | `table_of_jumps_offset` | Offset absoluto de tabla de saltos |

### Tabla de Opcodes Soportados por la VM

Cada instrucción en el bytecode ocupa exactamente 4 bytes continuos:
- **Byte 0:** Opcode binario.
- **Byte 1:** Registro destino (r0-r7).
- **Bytes 2 y 3:** Constante entera sin signo de 16 bits (`val_u16`).

| Opcode | Mnemónico | Operación |
|---|---|---|
| `0x00` | HALT | Detiene la ejecución del hilo lógico actual de la VM |
| `0x01` | LOAD_REG_CONST | Carga un valor constante de 16 bits en el registro destino |
| `0x02` | ADD_REG | Suma el valor de un registro origen al registro destino |
| `0x03` | SUB_REG | Resta el valor de un registro origen al registro destino |
| `0x04` | WRITE_ARENA_F32 | Escribe el valor float de un registro a una posición relativa de la entidad en la Arena |
| `0x05` | READ_ARENA_F32 | Lee un float de la Arena (relativo a la entidad) al registro destino |
| `0x06` | WRITE_ARENA_U8 | Escribe el byte de un registro a la Arena |
| `0x07` | READ_ARENA_U8 | Lee un byte de la Arena al registro destino |
| `0x08` | JMP_LT | Salta a la instrucción destino si `reg1 < reg2` |
| `0x09` | JMP | Salta incondicionalmente a la instrucción destino |
| `0x0A` | WRITE_ARENA_U32 | Escribe un valor de 32 bits a la Arena |
| `0x0B` | MUL_REG | Multiplica el valor del registro destino por el registro origen |
| `0x0C` | DIV_REG | Divide el valor del registro destino por el registro origen |

---

## 5. Compilación del Núcleo y Ejecución

### Dependencias
- Git
- Rust/Cargo (edición 2021)
- Flutter SDK (versión estable compatible con Dart 3.0+)

### Construcción del Motor Nativo
Ejecuta el script PowerShell de construcción automatizada:
```powershell
powershell -ExecutionPolicy Bypass -File .\build_core.ps1
```
Este script compilará la biblioteca dinámica en modo release (`malphas_core.dll`) y la copiará automáticamente a los directorios del chasis gráfico y ejecutables de Flutter.

### Ejecución de Pruebas Unitarias
```powershell
cargo test --manifest-path malphas_core/Cargo.toml
```

### Ejecución de la Consola Virtual
```powershell
cd flutter_app
flutter run -d windows
```

Una vez iniciada la consola, accede a la sección **"PACKS"**, haz clic en el icono de engranaje superior para abrir la **CONFIGURACIÓN DE PAQUETE** y pulsa **"COMPILAR Y CARGAR EN CALIENTE (ZERO-COPY)"**. Esto compilará el atlas, inyectará el bytecode en la Arena de memoria y comenzará a rasterizar los objetos móviles animados en tiempo real a 120Hz.
