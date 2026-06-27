# MALPHAS v1.0 - The Agnostic Virtual Console

Contenedor modular multiplataforma disenado para la ejecucion de motores logicos dinamicos y paquetes de recursos estaticos mediante comunicacion bidireccional por FFI nativo (Zero-Copy).

---

## 1. System Architecture: Vertical Slice

This project completely rejects layered architectures. It is strictly organized by Vertical Slices and UI Primitives. Every feature contains its own user interface, state management, and FFI bindings in a single folder.
* **MALPHAS (The Hardware):** The actual console. It handles the screen, the buttons, the battery, and saving your game to the disk. It doesn�t know what game you are playing.
* **PACKS (The Assets):** The art style, textures, and text. Pure, inert data. A pack can be "Pok�mon Sprites" or "Japanese Kanjis".
* **MOTORS (The Logic):** The code that makes things move. It reads the data, tracks your score, and decides what happens when you press a button.
* **MECATRON (The Screen):** The specific glass display running Malphas's current interface, optimized for high-performance Japanese immersion.

---

## ??? System Architecture: Vertical Slice

This project completely rejects layered architectures (Clean Architecture, DDD, etc.). It is strictly organized by **Vertical Slices** and **UI Primitives**. Every feature contains its own user interface, state management, and FFI bindings in a single, un-contaminated folder.

### ??? Directory Blueprint
* lib/core/ffi/ -- Dynamic library loading (DynamicLibrary.open) and C-ABI function signatures.
* lib/core/theme/ -- Radical Dark Mode (#000000 / Matte Anthracite). Serif for hierarchy, Sans-Serif for data.
* lib/core/ui_primitives/ -- Atomic, dumb graphical components (PrimitiveCanvas, inputs) invoked by the engine.
* lib/features/workspace/ -- Full-screen workspace shell, ultra-rounded bottom dock, and contextual sidebar.
* lib/features/package_manager/ -- No-code asset pack importer (.zip / .json parser).
* lib/features/engine_manager/ -- Native binary depot and hot-reloading controller.

---

## 2. The Rendering Pipeline: Command Buffer

The user interface is entirely Data-Driven. External engines (written in Zig, Rust, or C++) do not generate Flutter widgets. They write an array of geometric instructions into the shared RAM.

[ Native Engine (Zig/C++) ] --(Writes Bytes)--> [ Shared RAM Pool ]
                                                        |
                                                 (FFI Zero-Copy)
                                                        v
[ GPU (120Hz Refresh Rate) ] <-- (Impeller) --- [ CustomPainter (Flutter) ]

1. Passive Screen: Flutter runs a continuous 120Hz rendering loop via a CustomPainter powered by Impeller.
2. Virtual Coordinates: The engine maps visual elements inside a fixed, normalized matrix of 1000x1000 logical units.
3. Viewport Matrix Transformation: Flutter scales coordinates to match physical resolution and applies automatic Letterboxing to preserve aspect ratio.

---

## 3. Memory Layout: C-ABI Standard

Data exchange between Dart and the native binary is executed over a fixed, strictly aligned struct of exactly 40 bytes (#[repr(C)]).

| Offset (Bytes) | Type  | Field Name          | Architectural Purpose |
|:--------------:|:-----:|:--------------------|:----------------------|
| 0              | u16   | id                  | Unique identifier of the data object. |
| 2              | u8    | workspace_id        | Bound environment owner. |
| 3              | u8    | capabilities_mask   | Feature bitmask flag. |
| 4              | u32   | _pad                | Manual Padding to align 8-byte boundaries. |
| 8              | f32   | difficulty          | Floating-point difficulty coefficient. |
| 12             | f32   | stability           | Memory retention stability metric. |
| 16             | u64   | last_review_ts      | UNIX timestamp of previous interaction. |
| 24             | u64   | next_review_ts      | UNIX timestamp of scheduled re-test. |
| 32             | u32   | total_errors        | Total historical failure counter. |
| 36             | u32   | streak_count        | Current consecutive correct streak. |





C:\Users\calin\Desktop\malphas\README.md = "C:\Users\calin\Desktop\malphas\README.md"

 = @"
# MALPHAS v1.0 - The Agnostic Virtual Console

Malphas is NOT an app, NOT a chatbot, and definitely NOT some bloated corporate software. It is a low-level Virtual Console and a passive Display Server designed to run dynamic logic engines and static resource packs via a zero-copy, bi-directional native FFI bridge.

---

## The Core Philosophy (The Explain it Like I'm 5 Edition)

If you are a beginner, think of Malphas as a physical Game Boy Advance:
* MALPHAS (The Hardware): The actual console. It handles the screen, the buttons, the battery, and saving your game to the disk. It doesn't know what game you are playing.
* PACKS (The Assets): The art style, textures, and text. Pure, inert data. A pack can be 'Pokemon Sprites' or 'Japanese Kanjis'.
* MOTORS (The Logic): The code that makes things move. It reads the data, tracks your score, and decides what happens when you press a button.
* MECATRON (The Screen): The specific glass display running Malphas's current interface, optimized for high-performance Japanese immersion.

---

## System Architecture: Vertical Slice

This project completely rejects layered architectures (Clean Architecture, DDD, etc.). It is strictly organized by Vertical Slices and UI Primitives. Every feature contains its own user interface, state management, and FFI bindings in a single, un-contaminated folder.

### Directory Blueprint
* lib/core/ffi/ -- Dynamic library loading (DynamicLibrary.open) and C-ABI function signatures.
* lib/core/theme/ -- Radical Dark Mode (#000000 / Matte Anthracite). Serif for hierarchy, Sans-Serif for data.
* lib/core/ui_primitives/ -- Atomic, dumb graphical components (PrimitiveCanvas, inputs) invoked by the engine.
* lib/features/workspace/ -- Full-screen workspace shell, ultra-rounded bottom dock, and contextual sidebar.
* lib/features/package_manager/ -- No-code asset pack importer (.zip / .json parser).
* lib/features/engine_manager/ -- Native binary depot and hot-reloading controller.

---

## The Rendering Pipeline: Command Buffer

The user interface is entirely Data-Driven. External engines (written in Zig, Rust, or C++) do not generate Flutter widgets. They do not understand layouts. They simply write an array of geometric instructions into the shared RAM.

[ Native Engine (Zig/C++) ] --(Writes Bytes)--> [ Shared RAM Pool ]
                                                        |
                                                 (FFI Zero-Copy)
                                                        v
[ GPU (120Hz Refresh Rate) ] <-- (Impeller) --- [ CustomPainter (Flutter) ]

1. Passive Screen: Flutter runs a continuous 120Hz rendering loop via a CustomPainter powered by the Impeller graphics engine (Vulkan/Metal).
2. Virtual Coordinates: The engine maps all visual elements inside a fixed, normalized virtual matrix of 1000x1000 logical units, completely independent of the device's physical screen size.
3. Viewport Matrix Transformation: Flutter reads the drawing instructions directly from the memory pointer, scales the coordinates to match the device's actual resolution, and applies automatic Letterboxing to preserve the aspect ratio (16:9, 9:16, 1:1, 1:2).

### Primary Graphic Command Set
* PintarRectangulo(x, y, width, height, color_rgba)
* PintarTexto(string_ptr, x, y, size, color_rgba)
* PintarSprite(asset_id, x, y, scale, rotation)
* RenderModel3D(model_id, matrix_4x4, animation_id)

---

## Memory Layout: C-ABI Standard (The Architect's Sanctuary)

Data exchange between Dart (VM) and the native binary (Rust/Zig) is executed over a fixed, strictly aligned struct of exactly 40 bytes (#[repr(C)]). This prevents memory misalignment and guarantees bare-metal speed.

| Offset (Bytes) | Type  | Field Name          | Architectural Purpose |
|:--------------:|:-----:|:--------------------|:----------------------|
| 0              | u16   | id                  | Unique identifier of the data object. |
| 2              | u8    | workspace_id        | Bound environment owner. |
| 3              | u8    | capabilities_mask   | Feature bitmask flag. |
| 4              | u32   | _pad                | Manual Padding. Aligns fields to 8-byte boundaries. |
| 8              | f32   | difficulty          | Floating-point difficulty coefficient. |
| 12             | f32   | stability           | Memory retention stability metric. |
| 16             | u64   | last_review_ts      | UNIX timestamp of previous interaction. |
| 24             | u64   | next_review_ts      | UNIX timestamp of scheduled re-test. |
| 32             | u32   | total_errors        | Total historical failure counter. |
| 36             | u32   | streak_count        | Current consecutive correct streak. |

CRITICAL GUARDRAIL: Modifying a single field without updating the MALPHAS_SCHEMA_HASH (0xDEADBEEF) will result in silent memory corruption and immediate segmentation faults.

---

## Input Capturing & Event Loop (IMGUI Model)

Interactive elements (buttons, gesture zones, collision boxes) are evaluated instantaneously using the Immediate Mode GUI paradigm.

1. Passive Interception: The Flutter framework captures raw screen coordinate streams and packages them into lightweight EventoTactil structs.
2. FFI Injection: Flutter pushes these touch payloads (TouchDown, TouchMove, TouchUp) straight down the FFI pipe directly into the engine's execution loop.
3. AABB Collision Processing: The engine runs a standard Axis-Aligned Bounding Box calculation to determine if the pointer coordinates intersect with any visual elements.

Collision = (X_touch >= X_box) AND (X_touch <= X_box + W) AND (Y_touch >= Y_box) AND (Y_touch <= Y_box + H)

If a collision occurs, the engine alters the data state inside the RAM immediately, modifying the graphics instructions for the very next frame.
