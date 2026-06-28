use std::ffi::c_void;
use std::os::raw::c_char;
use std::ffi::CStr;
use std::fs::File;
use std::io::Read;
use std::sync::atomic::{AtomicUsize, AtomicU8, Ordering};
use sha2::{Sha256, Digest};
use zip::ZipArchive;

// Global addresses of shared memory bridges and arenas
static ARENA_ADDRESS: AtomicUsize = AtomicUsize::new(0);
static ARENA_SIZE: AtomicUsize = AtomicUsize::new(0);
static BRIDGE_ADDRESS: AtomicUsize = AtomicUsize::new(0);
static MAX_COMMANDS_CAPACITY: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(2048);
static ENGINE_RUNNING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

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

#[repr(C)]
pub struct CoreCommandBuffer {
    pub command_count: u32,
    pub commands: *mut DartRenderCommand,
}

#[repr(C)]
pub struct MalphasDoubleBufferBridge {
    pub buffer_a: CoreCommandBuffer,
    pub buffer_b: CoreCommandBuffer,
    pub atomic_back_index: AtomicU8,
    pub commands_written: std::sync::atomic::AtomicU32,
}

#[repr(C, align(16))]
#[derive(Clone, Copy)]
pub struct MhpHeader {
    pub magic: [u8; 4],
    pub version: u32,
    pub total_size: u64,
    pub checksum: [u8; 32],
    pub pack_id: [u8; 16],
    pub canvas_width: u16,
    pub canvas_height: u16,
    pub font_metrics_offset: u32,
    pub font_atlas_offset: u32,
    pub objects_table_offset: u32,
    pub objects_table_count: u32,
    pub skins_offset: u32,
    pub skins_size: u32,
    pub has_embedded_msp: u32,
    pub embedded_msp_offset: u32,
    pub embedded_msp_size: u32,
    pub padding: [u8; 4],
}

#[repr(C, align(16))]
#[derive(Clone, Copy)]
pub struct MhpObjectDescriptor {
    pub object_id: u32,
    pub properties_offset: u32,
    pub properties_size: u32,
    pub skins_offset: u32,
    pub skins_size: u32,
    pub padding: [u8; 12],
}

#[repr(C, align(16))]
#[derive(Clone, Copy)]
pub struct MspHeader {
    pub magic: [u8; 4],
    pub version: u32,
    pub checksum: [u8; 32],
    pub bytecode_size: u32,
    pub entry_point: u32,
    pub padding: [u8; 16],
}

pub struct ResourcePackRuntime {
    pub arena_start_ptr: *mut u8,
    pub arena_size: usize,
    pub bytecode_buffer: Vec<u8>,
}

unsafe impl Send for ResourcePackRuntime {}
unsafe impl Sync for ResourcePackRuntime {}

static RUNTIME: std::sync::Mutex<Option<ResourcePackRuntime>> = std::sync::Mutex::new(None);
static BYTECODE_VM: std::sync::OnceLock<arc_swap::ArcSwap<Vec<u8>>> = std::sync::OnceLock::new();

fn get_bytecode_vm() -> &'static arc_swap::ArcSwap<Vec<u8>> {
    BYTECODE_VM.get_or_init(|| arc_swap::ArcSwap::from(std::sync::Arc::new(Vec::new())))
}

fn c_str_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr).to_str().ok() }
}

#[no_mangle]
pub extern "C" fn init_engine(
    bridge_ptr: *mut MalphasDoubleBufferBridge,
    arena_ptr: *mut c_void,
    arena_size: u32,
    max_commands: u32,
) -> i32 {
    if bridge_ptr.is_null() || arena_ptr.is_null() {
        return -1;
    }
    
    // Stop any existing dynamic simulation thread
    ENGINE_RUNNING.store(false, Ordering::SeqCst);
    std::thread::sleep(std::time::Duration::from_millis(15));

    BRIDGE_ADDRESS.store(bridge_ptr as usize, Ordering::SeqCst);
    ARENA_ADDRESS.store(arena_ptr as usize, Ordering::SeqCst);
    ARENA_SIZE.store(arena_size as usize, Ordering::SeqCst);
    MAX_COMMANDS_CAPACITY.store(max_commands, Ordering::SeqCst);

    // Initialise Memory Map in first 32 bytes of the Arena
    unsafe {
        let arena_start = arena_ptr as *mut u8;
        // Bytes 0-3: 'M', 'A', 'M', 'P'
        *arena_start.add(0) = b'M';
        *arena_start.add(1) = b'A';
        *arena_start.add(2) = b'M';
        *arena_start.add(3) = b'P';

        // Bytes 4-7: static_resources_offset = 1024
        *(arena_start.add(4) as *mut u32) = 1024;
        // Bytes 8-11: static_resources_size = 0 (none loaded yet)
        *(arena_start.add(8) as *mut u32) = 0;
        // Bytes 12-15: entities_offset = 32
        *(arena_start.add(12) as *mut u32) = 32;
        // Bytes 16-19: entities_count = 0
        *(arena_start.add(16) as *mut u32) = 0;
    }

    ENGINE_RUNNING.store(true, Ordering::SeqCst);
    std::thread::spawn(|| {
        let sleep_dur = std::time::Duration::from_micros(8333); // ~120Hz
        while ENGINE_RUNNING.load(Ordering::SeqCst) {
            let start = std::time::Instant::now();
            
            process_engine_tick_internal();
            
            let elapsed = start.elapsed();
            if elapsed < sleep_dur {
                std::thread::sleep(sleep_dur - elapsed);
            }
        }
    });

    0
}

#[no_mangle]
pub extern "C" fn process_input_event(event_type: i32, x: f32, y: f32) -> i32 {
    if x.is_nan() || y.is_nan() { return -1; }
    let _ = event_type;

    let arena_addr = ARENA_ADDRESS.load(std::sync::atomic::Ordering::SeqCst);
    if arena_addr == 0 { return -2; }
    
    let arena_start = arena_addr as *mut u8;
    let entities_offset = unsafe { *(arena_start.add(12) as *const u32) } as usize;
    let entities_count = unsafe { *(arena_start.add(16) as *const u32) } as usize;

    let mut hit_count = 0;

    for entity_id in 0..entities_count {
        let entity_ptr = unsafe { arena_start.add(entities_offset + entity_id * 64) };
        let cmd = unsafe { &mut *(entity_ptr as *mut DartRenderCommand) };

        if cmd.command_type == 0 {
            continue;
        }

        // Perform AABB hit test
        if x >= cmd.x && x <= cmd.x + cmd.width && y >= cmd.y && y <= cmd.y + cmd.height {
            hit_count += 1;
            
            // Invert speed_x and speed_y
            // speed_x is float at offset 24 from entity_ptr
            // speed_y is float at offset 28 from entity_ptr
            unsafe {
                let speed_x_ptr = entity_ptr.add(24) as *mut f32;
                let speed_y_ptr = entity_ptr.add(28) as *mut f32;
                *speed_x_ptr = -(*speed_x_ptr);
                *speed_y_ptr = -(*speed_y_ptr);

                // Toggle colors for visual feedback
                if cmd.color_rgba == 0xFF00FFCC {
                    cmd.color_rgba = 0xFFFF00CC; // Cyan to Magenta
                } else if cmd.color_rgba == 0xFFFF00CC {
                    cmd.color_rgba = 0xFF00FFCC; // Magenta to Cyan
                } else if cmd.color_rgba == 0xFFE0DCD3 {
                    cmd.color_rgba = 0xFFFFFF00; // Ivory to Yellow
                } else if cmd.color_rgba == 0xFFFFFF00 {
                    cmd.color_rgba = 0xFFE0DCD3; // Yellow to Ivory
                }
            }
        }
    }

    hit_count
}

#[no_mangle]
pub extern "C" fn verify_binary_integrity(filepath: *const c_char, expected_sha: *const c_char) -> i32 {
    let filepath_str = match c_str_to_str(filepath) {
        Some(s) => s,
        None => return -1,
    };
    let expected_sha_str = match c_str_to_str(expected_sha) {
        Some(s) => s,
        None => return -2,
    };

    let clean_expected = expected_sha_str.trim_start_matches("0x").to_lowercase();

    let mut file = match File::open(filepath_str) {
        Ok(f) => f,
        Err(_) => return -3,
    };

    let mut hasher = Sha256::new();
    let mut buffer = [0; 8192];
    loop {
        match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => hasher.update(&buffer[..n]),
            Err(_) => return -4,
        }
    }
    let calculated_sha = format!("{:x}", hasher.finalize());

    if calculated_sha == clean_expected {
        0
    } else {
        1
    }
}

#[no_mangle]
pub extern "C" fn extract_zip_package(zip_path: *const c_char, output_dir: *const c_char) -> i32 {
    let zip_path_str = match c_str_to_str(zip_path) {
        Some(s) => s,
        None => return -1,
    };
    let output_dir_str = match c_str_to_str(output_dir) {
        Some(s) => s,
        None => return -2,
    };

    let file = match File::open(zip_path_str) {
        Ok(f) => f,
        Err(_) => return -3,
    };

    let mut archive = match ZipArchive::new(file) {
        Ok(a) => a,
        Err(_) => return -4,
    };

    let dest_path = std::path::Path::new(output_dir_str);
    if !dest_path.exists() {
        if std::fs::create_dir_all(dest_path).is_err() {
            return -5;
        }
    }

    for i in 0..archive.len() {
        let mut file = match archive.by_index(i) {
            Ok(f) => f,
            Err(_) => return -6,
        };
        
        let outpath = match file.enclosed_name() {
            Some(path) => dest_path.join(path),
            None => continue,
        };

        if file.name().ends_with('/') {
            if std::fs::create_dir_all(&outpath).is_err() {
                return -7;
            }
        } else {
            if let Some(p) = outpath.parent() {
                if !p.exists() {
                    if std::fs::create_dir_all(p).is_err() {
                        return -8;
                    }
                }
            }
            let mut outfile = match File::create(&outpath) {
                Ok(f) => f,
                Err(_) => return -9,
            };
            if std::io::copy(&mut file, &mut outfile).is_err() {
                return -10;
            }
        }
    }

    0
}

#[no_mangle]
pub extern "C" fn malphas_alloc(size: usize) -> *mut u8 {
    let layout = std::alloc::Layout::from_size_align(size, 16).unwrap();
    unsafe { std::alloc::alloc(layout) }
}

#[no_mangle]
pub extern "C" fn malphas_free(ptr: *mut u8, size: usize) {
    if !ptr.is_null() {
        let layout = std::alloc::Layout::from_size_align(size, 16).unwrap();
        unsafe { std::alloc::dealloc(ptr, layout) }
    }
}

#[no_mangle]
pub extern "C" fn load_resource_pack_raw(ptr: *const u8, size: u32) -> i32 {
    if ptr.is_null() || size < 4 {
        return -1;
    }
    
    let buffer = unsafe { std::slice::from_raw_parts(ptr, size as usize) };
    let magic = &buffer[0..4];

    if magic == b"MLPH" {
        // --- MHP (Malphas Hot Package) Loader ---
        let header_size = std::mem::size_of::<MhpHeader>();
        if buffer.len() < header_size {
            return -5;
        }

        let header = unsafe { &*(buffer.as_ptr() as *const MhpHeader) };

        // Validate total size
        if header.total_size as usize != buffer.len() {
            return -6;
        }

        // Validate SHA-256 Checksum over payload
        let mut hasher = Sha256::new();
        hasher.update(&buffer[header_size..]);
        let calculated = hasher.finalize();
        if calculated.as_slice() != header.checksum {
            return -7;
        }

        // Bounds checking for sub-tables
        if header.font_metrics_offset as usize + 4096 > buffer.len() {
            return -8;
        }
        if header.font_atlas_offset as usize + (512 * 512) > buffer.len() {
            return -9;
        }
        let objects_table_end = header.objects_table_offset as usize + (header.objects_table_count as usize * 32);
        if objects_table_end > buffer.len() {
            return -10;
        }
        if header.skins_offset as usize + header.skins_size as usize > buffer.len() {
            return -11;
        }

        let arena_addr = ARENA_ADDRESS.load(Ordering::SeqCst);
        let arena_size = ARENA_SIZE.load(Ordering::SeqCst);

        if arena_addr != 0 {
            let arena_start = arena_addr as *mut u8;
            unsafe {
                // Write package size to memory map
                *(arena_start.add(8) as *mut u32) = buffer.len() as u32;

                // Write absolute offsets in the Arena
                *(arena_start.add(20) as *mut u32) = 1024 + header.font_metrics_offset;
                *(arena_start.add(24) as *mut u32) = 1024 + header.font_atlas_offset;
                *(arena_start.add(28) as *mut u32) = 1024 + header.objects_table_offset;

                // Copy aligned MHP binary starting at offset 1024 in the Arena
                if arena_size >= buffer.len() + 1024 {
                    std::ptr::copy_nonoverlapping(buffer.as_ptr(), arena_start.add(1024), buffer.len());
                }
            }
        }

        // Extract embedded bytecode if present
        let mut bytecode = Vec::new();
        if header.has_embedded_msp == 1 {
            let start = header.embedded_msp_offset as usize;
            let end = start + header.embedded_msp_size as usize;
            if end <= buffer.len() {
                bytecode = buffer[start..end].to_vec();
            } else {
                return -12;
            }
        }

        let nuevo_bytecode = std::sync::Arc::new(bytecode);
        get_bytecode_vm().store(nuevo_bytecode);

        let mut runtime = RUNTIME.lock().unwrap();
        *runtime = Some(ResourcePackRuntime {
            arena_start_ptr: arena_addr as *mut u8,
            arena_size,
            bytecode_buffer: Vec::new(),
        });

        0
    } else if magic == b"MLPS" {
        // --- MSP (Malphas Script Package) Hot-Swap Loader ---
        let header_size = std::mem::size_of::<MspHeader>();
        if buffer.len() < header_size {
            return -20;
        }

        let header = unsafe { &*(buffer.as_ptr() as *const MspHeader) };

        // Validate payload boundaries
        let payload_start = header_size;
        let payload_end = payload_start + header.bytecode_size as usize;
        if payload_end > buffer.len() {
            return -21;
        }

        // Validate SHA-256 Checksum over bytecode
        let mut hasher = Sha256::new();
        hasher.update(&buffer[payload_start..payload_end]);
        let calculated = hasher.finalize();
        if calculated.as_slice() != header.checksum {
            return -22;
        }

        let bytecode = buffer[payload_start..payload_end].to_vec();
        let nuevo_bytecode = std::sync::Arc::new(bytecode);
        get_bytecode_vm().store(nuevo_bytecode);

        0
    } else {
        // Invalid Magic Header
        -30
    }
}

#[no_mangle]
pub extern "C" fn load_resource_pack(filepath: *const c_char) -> i32 {
    let path = match c_str_to_str(filepath) {
        Some(s) => s,
        None => return -1,
    };

    let mut file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return -2,
    };

    let mut buffer = Vec::new();
    if file.read_to_end(&mut buffer).is_err() {
        return -3;
    }

    let size = buffer.len();
    let ptr = malphas_alloc(size);
    if ptr.is_null() {
        return -4;
    }

    unsafe {
        std::ptr::copy_nonoverlapping(buffer.as_ptr(), ptr, size);
    }

    let res = load_resource_pack_raw(ptr, size as u32);
    malphas_free(ptr, size);
    res
}

#[no_mangle]
pub extern "C" fn process_engine_tick(dt_micros: u64) -> i32 {
    let _ = dt_micros;
    // Synchronous execution is now fully decoupled; this is a cheap no-op
    0
}

fn process_engine_tick_internal() {
    let bridge_addr = BRIDGE_ADDRESS.load(Ordering::SeqCst);
    if bridge_addr == 0 { return; }

    let bridge = unsafe { &mut *(bridge_addr as *mut MalphasDoubleBufferBridge) };
    let back_index = bridge.atomic_back_index.load(Ordering::SeqCst);

    let back_buffer = if back_index == 0 {
        &mut bridge.buffer_a
    } else {
        &mut bridge.buffer_b
    };

    let arena_addr = ARENA_ADDRESS.load(Ordering::SeqCst);
    let arena_size = ARENA_SIZE.load(Ordering::SeqCst);
    let max_capacity = MAX_COMMANDS_CAPACITY.load(Ordering::SeqCst) as usize;

    if arena_addr != 0 {
        let arena_start = arena_addr as *mut u8;

        // Read entity properties from the memory map
        let entities_offset = unsafe { *(arena_start.add(12) as *const u32) } as usize;
        let entities_count = unsafe { *(arena_start.add(16) as *const u32) } as usize;

        // Load bytecode atomically and lock-free
        let bytecode_guard = get_bytecode_vm().load();
        let bytecode = &*bytecode_guard;

        // 1. Run bytecode script inside the sandbox runtime
        {
            let mut runtime_opt = RUNTIME.lock().unwrap();
            if let Some(ref mut runtime) = *runtime_opt {
                runtime.arena_start_ptr = arena_start;
                runtime.arena_size = arena_size;

                for entity_id in 0..entities_count {
                    runtime.execute_logic_tick(entity_id as u16, bytecode);
                }
            }
        }

        // 2. Generate render commands to back_buffer
        let commands_slice = unsafe {
            std::slice::from_raw_parts_mut(back_buffer.commands, max_capacity)
        };

        let mut write_idx = 0;
        for entity_id in 0..entities_count {
            let entity_ptr = unsafe { arena_start.add(entities_offset + entity_id * 64) };
            let cmd = unsafe { &*(entity_ptr as *const DartRenderCommand) };

            if cmd.command_type == 0 {
                continue;
            }

            if write_idx < max_capacity {
                commands_slice[write_idx] = DartRenderCommand {
                    command_type: cmd.command_type,
                    layer: cmd.layer,
                    pad: cmd.pad,
                    x: cmd.x,
                    y: cmd.y,
                    width: cmd.width,
                    height: cmd.height,
                    color_rgba: cmd.color_rgba,
                };

                if cmd.command_type == 2 {
                    // String pointer passing for Case 2 (text)
                    let str_offset = unsafe { *(entity_ptr.add(48) as *const u32) } as usize;
                    let text_ptr = unsafe { arena_start.add(str_offset) };

                    if write_idx + 1 < max_capacity {
                        let slot_ptr = unsafe {
                            back_buffer.commands.add(write_idx + 1) as *mut *const u8
                        };
                        unsafe {
                            *slot_ptr = text_ptr;
                        }
                        write_idx += 2;
                    } else {
                        write_idx += 1;
                    }
                } else {
                    write_idx += 1;
                }
            }
        }
        back_buffer.command_count = write_idx as u32;
        // Update atomic handshake written count
        bridge.commands_written.store(write_idx as u32, Ordering::SeqCst);
    }

    // 3. Swap atomic back index
    let next_back = 1 - back_index;
    bridge.atomic_back_index.store(next_back, Ordering::SeqCst);
}

#[no_mangle]
pub extern "C" fn render_tick(buffer_ptr: *mut DartRenderCommand, max_commands: i32) -> i32 {
    // Keep as a fallback for non-double buffered operations
    if buffer_ptr.is_null() || max_commands <= 0 { return 0; }
    let commands = unsafe { std::slice::from_raw_parts_mut(buffer_ptr, max_commands as usize) };
    
    if max_commands >= 1 {
        commands[0] = DartRenderCommand {
            command_type: 1,
            layer: 0,
            pad: 0,
            x: 200.0,
            y: 200.0,
            width: 600.0,
            height: 400.0,
            color_rgba: 0xFFE0DCD3,
        };
        return 1;
    }
    0
}

impl ResourcePackRuntime {
    pub fn execute_logic_tick(&mut self, entity_id: u16, bytecode_buffer: &[u8]) {
        if bytecode_buffer.is_empty() { return; }

        // Each entity in Arena has size of 64 bytes
        let entity_offset = 32 + (entity_id as usize * 64);
        let mut pc = 0;
        let mut regs = [0.0f32; 8];

        while pc + 4 <= bytecode_buffer.len() {
            let opcode = bytecode_buffer[pc];
            let arg1 = bytecode_buffer[pc + 1];
            let val_u16 = ((bytecode_buffer[pc + 2] as u16) << 8) | (bytecode_buffer[pc + 3] as u16);

            match opcode {
                0x00 => { // HALT
                    break;
                }
                0x01 => { // LOAD_REG_CONST (reg, val_u16)
                    if arg1 < 8 {
                        regs[arg1 as usize] = val_u16 as f32;
                    }
                    pc += 4;
                }
                0x02 => { // ADD_REG (dest, src)
                    if arg1 < 8 && (val_u16 as usize) < 8 {
                        regs[arg1 as usize] += regs[val_u16 as usize];
                    }
                    pc += 4;
                }
                0x03 => { // SUB_REG (dest, src)
                    if arg1 < 8 && (val_u16 as usize) < 8 {
                        regs[arg1 as usize] -= regs[val_u16 as usize];
                    }
                    pc += 4;
                }
                0x04 => { // WRITE_ARENA_F32 (arena_offset, reg_src)
                    if arg1 < 8 {
                        let offset = entity_offset + val_u16 as usize;
                        if offset + 4 <= self.arena_size {
                            unsafe {
                                let target_ptr = self.arena_start_ptr.add(offset) as *mut f32;
                                *target_ptr = regs[arg1 as usize];
                            }
                        }
                    }
                    pc += 4;
                }
                0x05 => { // READ_ARENA_F32 (reg_dest, arena_offset)
                    if arg1 < 8 {
                        let offset = entity_offset + val_u16 as usize;
                        if offset + 4 <= self.arena_size {
                            unsafe {
                                let src_ptr = self.arena_start_ptr.add(offset) as *const f32;
                                regs[arg1 as usize] = *src_ptr;
                            }
                        }
                    }
                    pc += 4;
                }
                0x06 => { // WRITE_ARENA_U8 (arena_offset, reg_src)
                    if arg1 < 8 {
                        let offset = entity_offset + val_u16 as usize;
                        if offset < self.arena_size {
                            unsafe {
                                *self.arena_start_ptr.add(offset) = regs[arg1 as usize] as u8;
                            }
                        }
                    }
                    pc += 4;
                }
                0x07 => { // READ_ARENA_U8 (reg_dest, arena_offset)
                    if arg1 < 8 {
                        let offset = entity_offset + val_u16 as usize;
                        if offset < self.arena_size {
                            unsafe {
                                regs[arg1 as usize] = *self.arena_start_ptr.add(offset) as f32;
                            }
                        }
                    }
                    pc += 4;
                }
                0x08 => { // JMP_LT (reg1, reg2, target_instr_index_u8)
                    let reg2 = (val_u16 >> 8) as usize;
                    let target_pc = (val_u16 & 0xFF) as usize * 4;
                    if arg1 < 8 && reg2 < 8 {
                        if regs[arg1 as usize] < regs[reg2] {
                            pc = target_pc;
                            continue;
                        }
                    }
                    pc += 4;
                }
                0x09 => { // JMP (target_instr_index_u8)
                    pc = arg1 as usize * 4;
                }
                0x0A => { // WRITE_ARENA_U32 (arena_offset, reg_src)
                    if arg1 < 8 {
                        let offset = entity_offset + val_u16 as usize;
                        if offset + 4 <= self.arena_size {
                            unsafe {
                                let target_ptr = self.arena_start_ptr.add(offset) as *mut u32;
                                *target_ptr = regs[arg1 as usize] as u32;
                            }
                        }
                    }
                    pc += 4;
                }
                0x0B => { // MUL_REG (dest, src)
                    if arg1 < 8 && (val_u16 as usize) < 8 {
                        regs[arg1 as usize] *= regs[val_u16 as usize];
                    }
                    pc += 4;
                }
                0x0C => { // DIV_REG (dest, src)
                    if arg1 < 8 && (val_u16 as usize) < 8 {
                        let div = regs[val_u16 as usize];
                        if div != 0.0 {
                            regs[arg1 as usize] /= div;
                        }
                    }
                    pc += 4;
                }
                _ => {
                    break;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn test_verify_binary_integrity() {
        let temp_path = std::path::Path::new("temp_test_file.txt");
        let mut file = File::create(&temp_path).unwrap();
        file.write_all(b"Malphas Engine Core Verification Data").unwrap();
        drop(file);

        let mut hasher = Sha256::new();
        hasher.update(b"Malphas Engine Core Verification Data");
        let calculated_sha = format!("{:x}", hasher.finalize());

        let filepath_c = std::ffi::CString::new(temp_path.to_str().unwrap()).unwrap();
        let hash_c = std::ffi::CString::new(calculated_sha.as_str()).unwrap();

        let res = verify_binary_integrity(filepath_c.as_ptr(), hash_c.as_ptr());
        std::fs::remove_file(temp_path).unwrap();

        assert_eq!(res, 0);
    }

    #[test]
    fn test_struct_alignments() {
        // Assert sizes
        assert_eq!(std::mem::size_of::<MhpHeader>(), 112);
        assert_eq!(std::mem::size_of::<MhpObjectDescriptor>(), 32);
        assert_eq!(std::mem::size_of::<MspHeader>(), 64);

        // Assert alignments
        assert_eq!(std::mem::align_of::<MhpHeader>(), 16);
        assert_eq!(std::mem::align_of::<MhpObjectDescriptor>(), 16);
        assert_eq!(std::mem::align_of::<MspHeader>(), 16);
    }

    #[test]
    fn test_lockless_bytecode_latency() {
        let iterations = 100_000;
        let start = std::time::Instant::now();
        for _ in 0..iterations {
            let guard = get_bytecode_vm().load();
            let _ = &**guard;
        }
        let duration = start.elapsed();
        let ns_per_iter = (duration.as_nanos() as f64) / (iterations as f64);
        println!("ArcSwap read latency: {:.4} ns/iter", ns_per_iter);
        assert!(ns_per_iter < 120.0, "Latency too high: {} ns/iter", ns_per_iter);
    }
}


