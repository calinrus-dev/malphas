//! Bouncing demo system for Malphas v2.7.0.
//!
//! This `.mxc` (Malphas eXecutable Core) is a hot-swappable dynamic library
//! that receives the Silver Platter lookup table every frame.  It keeps its own
//! flat, contiguous SoA state allocated during `malphas_init_system` and writes
//! rectangle render commands directly into the back buffer provided by the core.

#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::sync::Mutex;

/// C-ABI mirror of the core `DartRenderCommand` (24 bytes, 4-byte aligned).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct DartRenderCommand {
    pub command_type: u8,
    pub layer: u8,
    pub pad: u16,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub color_rgba: u32,
}

/// 64-byte aligned payload read from the mapped MSP.
#[repr(C, align(64))]
#[derive(Clone, Copy)]
pub struct EntityPayload {
    pub tag_mask: u64,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub speed_x: f32,
    pub speed_y: f32,
    pub color_rgba: u32,
    pub flags: u32,
    pub min_x: f32,
    pub max_x: f32,
    pub min_y: f32,
    pub max_y: f32,
}

/// Flat, contiguous dynamic state (SoA).
struct State {
    count: usize,
    x: Vec<f32>,
    y: Vec<f32>,
    width: Vec<f32>,
    height: Vec<f32>,
    speed_x: Vec<f32>,
    speed_y: Vec<f32>,
    color_rgba: Vec<u32>,
    layer: Vec<u8>,
    min_x: Vec<f32>,
    max_x: Vec<f32>,
    min_y: Vec<f32>,
    max_y: Vec<f32>,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

/// Allocate internal SoA state from the read-only static payloads.
#[no_mangle]
pub extern "C" fn malphas_init_system(lookup_table: *const *const u8, entity_count: u32) -> i32 {
    if lookup_table.is_null() || entity_count == 0 {
        return -1;
    }
    let count = entity_count as usize;
    let mut state = State {
        count,
        x: Vec::with_capacity(count),
        y: Vec::with_capacity(count),
        width: Vec::with_capacity(count),
        height: Vec::with_capacity(count),
        speed_x: Vec::with_capacity(count),
        speed_y: Vec::with_capacity(count),
        color_rgba: Vec::with_capacity(count),
        layer: Vec::with_capacity(count),
        min_x: Vec::with_capacity(count),
        max_x: Vec::with_capacity(count),
        min_y: Vec::with_capacity(count),
        max_y: Vec::with_capacity(count),
    };
    for id in 0..count {
        let payload_ptr = unsafe { *lookup_table.add(id) } as *const EntityPayload;
        let payload = unsafe { &*payload_ptr };
        state.x.push(payload.x);
        state.y.push(payload.y);
        state.width.push(payload.width);
        state.height.push(payload.height);
        state.speed_x.push(payload.speed_x);
        state.speed_y.push(payload.speed_y);
        state.color_rgba.push(payload.color_rgba);
        state.layer.push((payload.flags & 0xFF) as u8);
        state.min_x.push(payload.min_x);
        state.max_x.push(payload.max_x);
        state.min_y.push(payload.min_y);
        state.max_y.push(payload.max_y);
    }
    *STATE.lock().unwrap() = Some(state);
    0
}

/// Advance simulation and write render commands.
///
/// The lookup table is read-only and freshly injected every frame; the system
/// never caches it globally.  Dynamic mutation happens only in the internal
/// SoA arrays allocated during init.
#[no_mangle]
pub extern "C" fn malphas_tick(
    lookup_table: *const *const u8,
    entity_count: u32,
    _dt_micros: u64,
    render_buffer: *mut DartRenderCommand,
    render_capacity: u32,
    render_count: *mut u32,
) {
    if lookup_table.is_null()
        || render_buffer.is_null()
        || render_count.is_null()
        || entity_count == 0
    {
        return;
    }
    let mut guard = STATE.lock().unwrap();
    let state = match guard.as_mut() {
        Some(s) => s,
        None => return,
    };
    let count = (entity_count as usize).min(state.count);
    let capacity = render_capacity as usize;
    let mut written = 0u32;
    for id in 0..count {
        if written as usize >= capacity {
            break;
        }

        // Read static payload fresh every frame (read-only lookup table).
        let payload_ptr = unsafe { *lookup_table.add(id) } as *const EntityPayload;
        let payload = unsafe { &*payload_ptr };

        // Update dynamic state.
        state.x[id] += state.speed_x[id];
        state.y[id] += state.speed_y[id];

        // Bounce on bounds.
        if state.x[id] < state.min_x[id] {
            state.x[id] = state.min_x[id];
            state.speed_x[id] = -state.speed_x[id];
        } else if state.x[id] + state.width[id] > state.max_x[id] {
            state.x[id] = state.max_x[id] - state.width[id];
            state.speed_x[id] = -state.speed_x[id];
        }
        if state.y[id] < state.min_y[id] {
            state.y[id] = state.min_y[id];
            state.speed_y[id] = -state.speed_y[id];
        } else if state.y[id] + state.height[id] > state.max_y[id] {
            state.y[id] = state.max_y[id] - state.height[id];
            state.speed_y[id] = -state.speed_y[id];
        }

        // Write render command.
        let cmd = unsafe { &mut *render_buffer.add(written as usize) };
        cmd.command_type = 1; // rectangle
        cmd.layer = state.layer[id];
        cmd.pad = id as u16;
        cmd.x = state.x[id];
        cmd.y = state.y[id];
        cmd.width = state.width[id];
        cmd.height = state.height[id];
        cmd.color_rgba = state.color_rgba[id];
        written += 1;

        // `tag_mask` is part of the ABI contract even if this demo ignores it.
        let _ = payload.tag_mask;
    }
    unsafe {
        *render_count = written;
    }
}
