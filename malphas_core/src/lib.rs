use std::ffi::c_void;

#[repr(C)]
pub struct ConceptState {
    pub id: u16,
    pub workspace_id: u8,
    pub capabilities_mask: u8,
    pub _pad: u32,
    pub difficulty: f32,
    pub stability: f32,
    pub last_review_ts: u64,
    pub next_review_ts: u64,
    pub total_errors: u32,
    pub streak_count: u32,
}

#[repr(C)]
pub struct RenderCommand {
    pub command_type: u8,
    pub layer: u8,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    // Color empaquetado en ARGB: 0xAARRGGBB
    pub color_rgba: u32,
}

#[no_mangle]
pub extern "C" fn init_engine(arena_ptr: *mut c_void) -> i32 {
    if arena_ptr.is_null() {
        return -1;
    }
    0
}

#[no_mangle]
pub extern "C" fn process_input_event(event_type: i32, x: f32, y: f32) -> i32 {
    // Validación básica de entradas
    if x.is_nan() || y.is_nan() {
        return -1;
    }
    let _ = (event_type, x, y);
    0
}

#[no_mangle]
pub extern "C" fn render_tick(buffer_ptr: *mut RenderCommand, max_commands: i32) -> i32 {
    // Protección anti-overflow y punteros nulos
    if buffer_ptr.is_null() || max_commands <= 0 {
        return 0;
    }

    // Limitamos el número de comandos a un máximo seguro y razonable
    let capacity = max_commands as usize;
    if capacity > 4096 {
        // Rechazamos solicitudes absurdas para evitar abuso de memoria
        return 0;
    }

    // Transformación segura a slice mutable controlada por capacity
    let commands = unsafe { std::slice::from_raw_parts_mut(buffer_ptr, capacity) };

    // Escribimos varios comandos de ejemplo dentro de límites
    let mut written = 0usize;

    // Comando 0: rectángulo rojo puro en ARGB (opaco)
    if capacity > written {
        commands[written] = RenderCommand {
            command_type: 1,
            layer: 0,
            x: 150.0,
            y: 150.0,
            width: 300.0,
            height: 200.0,
            color_rgba: 0xFFFF0000, // ARGB: A=0xFF, R=0xFF, G=0x00, B=0x00
        };
        written += 1;
    }

    // Comando 1: rectángulo verde translúcido
    if capacity > written {
        commands[written] = RenderCommand {
            command_type: 1,
            layer: 1,
            x: 480.0,
            y: 120.0,
            width: 200.0,
            height: 150.0,
            color_rgba: 0x88FF00FF, // ejemplo (A=0x88)
        };
        written += 1;
    }

    // Si se pidieron más comandos, los dejamos sin inicializar para el caller,
    // pero retornamos el número exacto de comandos escritos.
    written as i32
}
