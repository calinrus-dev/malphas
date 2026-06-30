# Malphas v2.7.0 — Data-Oriented Memory Router

**Malphas no es un motor de objetos. Es un router de memoria plana.**

Este proyecto es una declaración de guerra contra la orientación a objetos en el hot path del rendimiento. El núcleo está escrito en Rust, la interfaz en Flutter, y ambos se comunican a través de un puente C-ABI mínimo que no serializa, no copia y no permite que el Garbage Collector decida cuándo se ejecuta una línea de código crítica.

> **v2.7.0 — The Data-Oriented Router** elimina por completo la VM de bytecode, el modelo de entidades con métodos y la Arena compartida de escritura. Ahora el flujo es simple: datos planos en disco (`MSP`) → memoria mapeada (`mmap`) → sistemas nativos (`MXC`) → comandos de renderizado crudos → pantalla. Punto.

---

## 1. Filosofía DOD (Data-Oriented Design)

Malphas escupe sobre la herencia, los métodos virtuales y los árboles de objetos.

- **NO hay objetos en el hot path.** Una "entidad" no es una clase. Es un `u32`.
- **NO hay Garbage Collector en el frame crítico.** Rust posee la memoria; Dart solo lee punteros.
- **TODO está alineado a 64 bytes.** Cada header, descriptor y payload respeta el tamaño de una línea de caché L1. Si no cabe en una línea, no entra.
- **Zero-copy por diseño.** Un `MSP` en disco es idéntico a un `MSP` en memoria. Se carga con `mmap`; no se deserializa.
- **Stateless por contrato.** Los sistemas `.mxc` reciben una tabla de punteros de solo lectura (Silver Platter) y mantienen su propio estado plano en arrays contiguos (SoA). Nunca mutan el MSP.

Si todavía piensas en `objeto.update()`, estás en el motor equivocado.

---

## 2. Arquitectura: MSP y MXC

### 2.1 MSP — Malphas Source Pack

El `MSP` es la unidad de datos plana de Malphas. Es un archivo binario rígido, alineado a 64 bytes, compuesto por:

1. **`MspHeader`** (64 bytes): magia `MLPS`, versión, offsets, checksum.
2. **`MspEntityDescriptor[]`** (64 bytes cada uno): mapea `entity_id` → offset/size del payload.
3. **Sección de payloads**: blobs de memoria cruda, cada uno alineado a 64 bytes. Los últimos 64 KB están reservados para *Error Payloads*: un fallback seguro para IDs inválidos.

```rust
#[repr(C, align(64))]
pub struct MspHeader {
    pub magic: [u8; 4],              // 4 bytes
    pub version: u32,                // 4 bytes
    pub entity_table_offset: u32,    // 4 bytes
    pub entity_count: u32,           // 4 bytes
    pub payload_section_offset: u32, // 4 bytes
    pub payload_section_size: u32,   // 4 bytes
    pub checksum: u64,               // 8 bytes
    pub _padding: [u8; 32],          // 32 bytes
}                                   // = 64 bytes, 1 línea de caché

#[repr(C, align(64))]
pub struct MspEntityDescriptor {
    pub entity_id: u32,              // 4 bytes
    // 4 bytes de padding implícito para alinear tag_mask
    pub tag_mask: u64,               // 8 bytes
    pub payload_offset: u32,         // 4 bytes
    pub payload_size: u32,           // 4 bytes
    pub _padding: [u8; 40],          // 40 bytes
}                                   // = 64 bytes, 1 línea de caché
```

Al cargar, `malphas_core` construye la **Silver Platter**: un array plano de punteros `*const u8` indexado por `entity_id`. Los sistemas hacen `unsafe { *lookup_table.add(id) }` y ya tienen su payload. Sin hash maps. Sin métodos. Sin indirecciones.

### 2.2 MXC — Malphas eXecutable Core

Un `MXC` es una librería dinámica nativa (`dll`/`so`/`dylib`) que exporta exactamente dos símbolos:

```rust
#[no_mangle]
pub extern "C" fn malphas_init_system(
    lookup_table: *const *const u8,
    entity_count: u32,
) -> i32;

#[no_mangle]
pub extern "C" fn malphas_tick(
    lookup_table: *const *const u8,
    entity_count: u32,
    dt_micros: u64,
    render_buffer: *mut DartRenderCommand,
    render_capacity: u32,
    render_count: *mut u32,
);
```

- `init` se ejecuta una sola vez para reservar el estado SoA interno del sistema.
- `tick` se ejecuta cada frame: lee la Silver Platter, muta sus propios arrays planos y escribe comandos de renderizado directamente en el back buffer del puente FFI.
- El sistema **nunca** escribe en el MSP. El MSP es sagrado y de solo lectura.

---

## 3. Glosario Estricto

| Término | Definición | Lo que NO es |
|---|---|---|
| **Entidad** | Un `u32` relacional (`entity_id`). Un índice en una tabla. | Una clase. No tiene métodos, estado ni comportamiento. |
| **Payload** | Un bloque de bytes crudos, alineado a 64 bytes, apuntado por la Silver Platter. | Un objeto. No tiene interfaz. Es memoria plana interpretada por el sistema. |
| **Silver Platter** | Array plano de `*const u8` construido al cargar el MSP. `lookup_table[entity_id]` devuelve el payload. | Un mapa, diccionario o estructura de búsqueda. |
| **Sistema (.mxc)** | Librería dinámica nativa que consume payloads y escribe comandos. | Un script interpretado, una clase ni una máquina virtual. |
| **Entorno** | Un MSP mapeado en memoria más uno o varios sistemas cargados. | Una escena con GameObjects. |
| **Puente FFI** | `MalphasDoubleBufferBridge`: 64 bytes compartidos entre Rust y Dart. | Un bus de mensajes, JSON o canal de eventos. |

**Regla de oro:** si dices "objeto", "método" o "clase" dentro del núcleo, has perdido el juego.

---

## 4. El Puente Flutter FFI — El Pintor Ciego

Flutter no es un motor. Es una terminal de renderizado.

Dart no conoce entidades, payloads ni lógica de juego. Solo conoce un puntero a `MalphasDoubleBufferBridge` y la regla de oro del double-buffer:

```rust
#[repr(C, align(64))]
pub struct MalphasDoubleBufferBridge {
    pub buffer_a_command_count: AtomicU32, // 4
    pub _padding0: u32,                    // 4
    pub buffer_a_commands: *mut DartRenderCommand, // 8
    pub buffer_b_command_count: AtomicU32, // 4
    pub _padding1: u32,                    // 4
    pub buffer_b_commands: *mut DartRenderCommand, // 8
    pub atomic_back_index: AtomicU8,       // 1
    pub _padding2: u8,                     // 1
    pub _padding3: u8,                     // 1
    pub _padding4: u8,                     // 1
    pub commands_written: AtomicU32,       // 4
    pub _padding5: u32,                    // 4
    pub _padding6: u32,                    // 4
    pub _padding7: u64,                    // 8
    pub _padding8: u64,                    // 8
}                                          // = 64 bytes
```

Cada frame Flutter hace:

1. `trigger_engine_pulse()` → despierta el hilo de Rust.
2. Rust ejecuta `tick` de los sistemas cargados en el **back buffer**.
3. Rust flipea `atomic_back_index` con ordenamiento Release/Acquire.
4. Dart lee el **front buffer** opuesto usando `get_back_index()`.
5. `PrimitiveCanvas` itera los comandos crudos directamente desde el puntero nativo y los pinta.

```rust
#[repr(C)]
pub struct DartRenderCommand {
    pub command_type: u8,   // 1 = rect, 2 = text marker
    pub layer: u8,          // orden de pintado
    pub pad: u16,           // alineación
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub color_rgba: u32,    // 0xAARRGGBB
}                           // = 24 bytes
```

No hay `List<DartRenderCommand>`. No hay `fromJson`. No hay `copyWith`. Hay un puntero, un conteo atómico y un `Canvas.drawRect`.

---

## 5. Flujo de Datos en una Frame

```
Disco
 ├── bouncing_demo.msp   (MSP) ──mmap──► RAM: Silver Platter
 └── bouncing_demo.mxc   (MXC) ──dlopen► Rust: sistema cargado

Flutter VSync
 └── trigger_engine_pulse()
      └── Rust tick_systems(lookup_table, back_buffer)
           └── MXC malphas_tick() escribe DartRenderCommand[]
      └── flip atomic_back_index

Flutter Paint
 └── PrimitiveCanvas
      └── front_commands = buffer opuesto a back_index
      └── for i in 0..front_count: Canvas.drawRect(commands[i])
```

---

## 6. Compilación y Ejecución

### Rust

```bash
# Motor, CLI y sistema de ejemplo
cargo build --release --package malphas_core
cargo build --release --package malphas_cli
cargo build --release --package bouncing_demo

# Verificación estricta
cargo fmt -- --check
cargo clippy --release -- -D warnings
cargo test --release
```

### MSP de ejemplo

```bash
# Compila el MSP desde el manifest v2.7.0
cargo run --release -p malphas_cli -- compile examples/bouncing_demo/manifest.json
```

Esto genera `examples/bouncing_demo/bouncing_demo.msp` y `examples/bouncing_demo/bindings.rs`.

### Flutter

```bash
cd flutter_app
flutter pub get
flutter analyze --no-fatal-infos
flutter test
dart format .
```

---

## 7. Comandos de Verificación Arquitectónica

```bash
# Nada de alineaciones rotas
git grep "align(16)" || echo "OK: no align(16) encontrado"

# Nada de OOP en el núcleo
git grep -i "class.*Object" malphas_core/ || echo "OK: no clases objeto en Rust"

# Las estructuras críticas miden 64 bytes
grep -n "size_of::<MspHeader>()" malphas_core/src/msp_loader.rs
grep -n "size_of::<MspEntityDescriptor>()" malphas_core/src/msp_loader.rs
grep -n "size_of::<MalphasDoubleBufferBridge>()" malphas_core/src/pipeline.rs
```

---

## 8. Contrato de Contribución

Si envías un PR:

1. Toda estructura compartida debe ser `#[repr(C)]` o `#[repr(C, align(64))]` y su tamaño debe ser múltiplo de 64.
2. Ningún sistema `.mxc` puede mutar el MSP ni hacer FFI de vuelta al core durante `tick`.
3. Dart solo lee punteros; nunca construye objetos por frame.
4. `cargo fmt`, `cargo clippy --release -- -D warnings`, `cargo test --release`, `flutter analyze` y `flutter test` deben pasar.

Lee `CONTRIBUTING.md` para el proceso completo.

---

## 9. Licencia

MIT — ver `LICENSE`.
