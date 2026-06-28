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

const MAX_COMMANDS_CAPACITY: usize = 2048;

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
}

pub struct ResourcePackRuntime {
    pub arena_start_ptr: *mut u8,
    pub arena_size: usize,
    pub bytecode_buffer: Vec<u8>,
}

unsafe impl Send for ResourcePackRuntime {}
unsafe impl Sync for ResourcePackRuntime {}

static RUNTIME: std::sync::Mutex<Option<ResourcePackRuntime>> = std::sync::Mutex::new(None);

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
) -> i32 {
    if bridge_ptr.is_null() || arena_ptr.is_null() {
        return -1;
    }
    BRIDGE_ADDRESS.store(bridge_ptr as usize, Ordering::SeqCst);
    ARENA_ADDRESS.store(arena_ptr as usize, Ordering::SeqCst);
    ARENA_SIZE.store(arena_size as usize, Ordering::SeqCst);

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

    if buffer.len() < 32 {
        return -4;
    }

    if &buffer[0..4] != b"MLPH" {
        return -5;
    }

    // Extract offsets from header
    let _manifest_size = u32::from_le_bytes(buffer[4..8].try_into().unwrap()) as usize;
    let font_metrics_offset = u32::from_le_bytes(buffer[8..12].try_into().unwrap()) as usize;
    let font_atlas_offset = u32::from_le_bytes(buffer[12..16].try_into().unwrap()) as usize;
    let table_of_jumps_offset = u32::from_le_bytes(buffer[16..20].try_into().unwrap()) as usize;
    let bytecode_offset = u32::from_le_bytes(buffer[24..28].try_into().unwrap()) as usize;
    let bytecode_size = u32::from_le_bytes(buffer[28..32].try_into().unwrap()) as usize;

    let arena_addr = ARENA_ADDRESS.load(Ordering::SeqCst);
    let arena_size = ARENA_SIZE.load(Ordering::SeqCst);

    if arena_addr != 0 {
        let arena_start = arena_addr as *mut u8;
        unsafe {
            // Write package size to memory map
            *(arena_start.add(8) as *mut u32) = buffer.len() as u32;

            // Write font atlas offsets (relative to Arena start)
            *(arena_start.add(20) as *mut u32) = 1024 + font_metrics_offset as u32;
            *(arena_start.add(24) as *mut u32) = 1024 + font_atlas_offset as u32;
            *(arena_start.add(28) as *mut u32) = 1024 + table_of_jumps_offset as u32;

            // Copy pack binary data starting at offset 1024 in the Arena
            if arena_size >= buffer.len() + 1024 {
                std::ptr::copy_nonoverlapping(buffer.as_ptr(), arena_start.add(1024), buffer.len());
            }
        }
    }

    let bytecode = if bytecode_size > 0 && bytecode_offset + bytecode_size <= buffer.len() {
        buffer[bytecode_offset..(bytecode_offset + bytecode_size)].to_vec()
    } else {
        Vec::new()
    };

    let mut runtime = RUNTIME.lock().unwrap();
    *runtime = Some(ResourcePackRuntime {
        arena_start_ptr: arena_addr as *mut u8,
        arena_size,
        bytecode_buffer: bytecode,
    });

    0
}

#[no_mangle]
pub extern "C" fn process_engine_tick(dt_micros: u64) -> i32 {
    let _ = dt_micros;
    let bridge_addr = BRIDGE_ADDRESS.load(Ordering::SeqCst);
    if bridge_addr == 0 { return -1; }

    let bridge = unsafe { &mut *(bridge_addr as *mut MalphasDoubleBufferBridge) };
    let back_index = bridge.atomic_back_index.load(Ordering::SeqCst);

    let back_buffer = if back_index == 0 {
        &mut bridge.buffer_a
    } else {
        &mut bridge.buffer_b
    };

    let arena_addr = ARENA_ADDRESS.load(Ordering::SeqCst);
    let arena_size = ARENA_SIZE.load(Ordering::SeqCst);

    if arena_addr != 0 {
        let arena_start = arena_addr as *mut u8;

        // Read entity properties from the memory map
        let entities_offset = unsafe { *(arena_start.add(12) as *const u32) } as usize;
        let entities_count = unsafe { *(arena_start.add(16) as *const u32) } as usize;

        // 1. Run bytecode script inside the sandbox runtime
        {
            let mut runtime_opt = RUNTIME.lock().unwrap();
            if let Some(ref mut runtime) = *runtime_opt {
                runtime.arena_start_ptr = arena_start;
                runtime.arena_size = arena_size;

                for entity_id in 0..entities_count {
                    runtime.execute_logic_tick(entity_id as u16);
                }
            }
        }

        // 2. Generate render commands to back_buffer
        let commands_slice = unsafe {
            std::slice::from_raw_parts_mut(back_buffer.commands, MAX_COMMANDS_CAPACITY)
        };

        let mut write_idx = 0;
        for entity_id in 0..entities_count {
            let entity_ptr = unsafe { arena_start.add(entities_offset + entity_id * 64) };
            let cmd = unsafe { &*(entity_ptr as *const DartRenderCommand) };

            if cmd.command_type == 0 {
                continue;
            }

            if write_idx < MAX_COMMANDS_CAPACITY {
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
                    // The entity structure stores string offset in the Arena at offset 48
                    let str_offset = unsafe { *(entity_ptr.add(48) as *const u32) } as usize;
                    let text_ptr = unsafe { arena_start.add(str_offset) };

                    if write_idx + 1 < MAX_COMMANDS_CAPACITY {
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
    }

    // 3. Swap atomic back index
    let next_back = 1 - back_index;
    bridge.atomic_back_index.store(next_back, Ordering::SeqCst);

    0
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
    pub fn execute_logic_tick(&mut self, entity_id: u16) {
        if self.bytecode_buffer.is_empty() { return; }

        // Each entity in Arena has size of 64 bytes
        let entity_offset = 32 + (entity_id as usize * 64);
        let mut pc = 0;
        let mut regs = [0.0f32; 8];

        while pc + 4 <= self.bytecode_buffer.len() {
            let opcode = self.bytecode_buffer[pc];
            let arg1 = self.bytecode_buffer[pc + 1];
            let val_u16 = ((self.bytecode_buffer[pc + 2] as u16) << 8) | (self.bytecode_buffer[pc + 3] as u16);

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
}


