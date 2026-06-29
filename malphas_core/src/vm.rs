// Bytecode sandbox VM implementation for ResourcePackRuntime.
use crate::pipeline::ResourcePackRuntime;

type OpcodeFn = unsafe fn(
    rt: &mut ResourcePackRuntime,
    entity_offset: usize,
    arg1: u8,
    val_u16: u16,
    regs: &mut [f32; 8],
    pc: &mut usize,
    bytecode: &[u8],
);

static JUMP_TABLE: [OpcodeFn; 16] = [
    vm_halt,            // 0x00
    vm_load_reg_const,  // 0x01
    vm_add_reg,         // 0x02
    vm_sub_reg,         // 0x03
    vm_write_arena_f32, // 0x04
    vm_read_arena_f32,  // 0x05
    vm_write_arena_u8,  // 0x06
    vm_read_arena_u8,   // 0x07
    vm_jmp_lt,          // 0x08
    vm_jmp,             // 0x09
    vm_write_arena_u32, // 0x0A
    vm_mul_reg,         // 0x0B
    vm_div_reg,         // 0x0C
    vm_halt,            // 0x0D
    vm_halt,            // 0x0E
    vm_halt,            // 0x0F
];

unsafe fn vm_halt(
    _rt: &mut ResourcePackRuntime,
    _entity_offset: usize,
    _arg1: u8,
    _val_u16: u16,
    _regs: &mut [f32; 8],
    pc: &mut usize,
    _bytecode: &[u8],
) {
    *pc = usize::MAX - 4;
}

unsafe fn vm_load_reg_const(
    _rt: &mut ResourcePackRuntime,
    _entity_offset: usize,
    arg1: u8,
    val_u16: u16,
    regs: &mut [f32; 8],
    pc: &mut usize,
    _bytecode: &[u8],
) {
    if arg1 < 8 {
        regs[arg1 as usize] = val_u16 as f32;
    }
    *pc += 4;
}

unsafe fn vm_add_reg(
    _rt: &mut ResourcePackRuntime,
    _entity_offset: usize,
    arg1: u8,
    val_u16: u16,
    regs: &mut [f32; 8],
    pc: &mut usize,
    _bytecode: &[u8],
) {
    if arg1 < 8 && (val_u16 as usize) < 8 {
        regs[arg1 as usize] += regs[val_u16 as usize];
    }
    *pc += 4;
}

unsafe fn vm_sub_reg(
    _rt: &mut ResourcePackRuntime,
    _entity_offset: usize,
    arg1: u8,
    val_u16: u16,
    regs: &mut [f32; 8],
    pc: &mut usize,
    _bytecode: &[u8],
) {
    if arg1 < 8 && (val_u16 as usize) < 8 {
        regs[arg1 as usize] -= regs[val_u16 as usize];
    }
    *pc += 4;
}

unsafe fn vm_write_arena_f32(
    rt: &mut ResourcePackRuntime,
    entity_offset: usize,
    arg1: u8,
    val_u16: u16,
    regs: &mut [f32; 8],
    pc: &mut usize,
    _bytecode: &[u8],
) {
    if arg1 < 8 {
        let mask = rt.arena_size - 1;
        let offset = (entity_offset + val_u16 as usize) & mask;
        if (rt.arena_start_ptr as usize + offset) & 3 == 0 {
            let target_ptr = rt.arena_start_ptr.add(offset) as *mut f32;
            *target_ptr = regs[arg1 as usize];
        }
    }
    *pc += 4;
}

unsafe fn vm_read_arena_f32(
    rt: &mut ResourcePackRuntime,
    entity_offset: usize,
    arg1: u8,
    val_u16: u16,
    regs: &mut [f32; 8],
    pc: &mut usize,
    _bytecode: &[u8],
) {
    if arg1 < 8 {
        let mask = rt.arena_size - 1;
        let offset = (entity_offset + val_u16 as usize) & mask;
        if (rt.arena_start_ptr as usize + offset) & 3 == 0 {
            let src_ptr = rt.arena_start_ptr.add(offset) as *const f32;
            regs[arg1 as usize] = *src_ptr;
        }
    }
    *pc += 4;
}

unsafe fn vm_write_arena_u8(
    rt: &mut ResourcePackRuntime,
    entity_offset: usize,
    arg1: u8,
    val_u16: u16,
    regs: &mut [f32; 8],
    pc: &mut usize,
    _bytecode: &[u8],
) {
    if arg1 < 8 {
        let mask = rt.arena_size - 1;
        let offset = (entity_offset + val_u16 as usize) & mask;
        *rt.arena_start_ptr.add(offset) = regs[arg1 as usize] as u8;
    }
    *pc += 4;
}

unsafe fn vm_read_arena_u8(
    rt: &mut ResourcePackRuntime,
    entity_offset: usize,
    arg1: u8,
    val_u16: u16,
    regs: &mut [f32; 8],
    pc: &mut usize,
    _bytecode: &[u8],
) {
    if arg1 < 8 {
        let mask = rt.arena_size - 1;
        let offset = (entity_offset + val_u16 as usize) & mask;
        regs[arg1 as usize] = *rt.arena_start_ptr.add(offset) as f32;
    }
    *pc += 4;
}

unsafe fn vm_jmp_lt(
    _rt: &mut ResourcePackRuntime,
    _entity_offset: usize,
    arg1: u8,
    val_u16: u16,
    regs: &mut [f32; 8],
    pc: &mut usize,
    bytecode: &[u8],
) {
    let reg2 = (val_u16 >> 8) as usize;
    let target_pc = (val_u16 & 0xFF) as usize * 4;
    if arg1 < 8 && reg2 < 8 && regs[arg1 as usize] < regs[reg2] {
        if target_pc + 4 > bytecode.len() {
            *pc = usize::MAX - 4;
        } else {
            *pc = target_pc;
        }
    } else {
        *pc += 4;
    }
}

unsafe fn vm_jmp(
    _rt: &mut ResourcePackRuntime,
    _entity_offset: usize,
    arg1: u8,
    _val_u16: u16,
    _regs: &mut [f32; 8],
    pc: &mut usize,
    bytecode: &[u8],
) {
    let target_pc = arg1 as usize * 4;
    if target_pc + 4 > bytecode.len() {
        *pc = usize::MAX - 4;
    } else {
        *pc = target_pc;
    }
}

unsafe fn vm_write_arena_u32(
    rt: &mut ResourcePackRuntime,
    entity_offset: usize,
    arg1: u8,
    val_u16: u16,
    regs: &mut [f32; 8],
    pc: &mut usize,
    _bytecode: &[u8],
) {
    if arg1 < 8 {
        let mask = rt.arena_size - 1;
        let offset = (entity_offset + val_u16 as usize) & mask;
        if (rt.arena_start_ptr as usize + offset) & 3 == 0 {
            let target_ptr = rt.arena_start_ptr.add(offset) as *mut u32;
            *target_ptr = regs[arg1 as usize] as u32;
        }
    }
    *pc += 4;
}

unsafe fn vm_mul_reg(
    _rt: &mut ResourcePackRuntime,
    _entity_offset: usize,
    arg1: u8,
    val_u16: u16,
    regs: &mut [f32; 8],
    pc: &mut usize,
    _bytecode: &[u8],
) {
    if arg1 < 8 && (val_u16 as usize) < 8 {
        regs[arg1 as usize] *= regs[val_u16 as usize];
    }
    *pc += 4;
}

unsafe fn vm_div_reg(
    _rt: &mut ResourcePackRuntime,
    _entity_offset: usize,
    arg1: u8,
    val_u16: u16,
    regs: &mut [f32; 8],
    pc: &mut usize,
    _bytecode: &[u8],
) {
    if arg1 < 8 && (val_u16 as usize) < 8 {
        let div = regs[val_u16 as usize];
        if div != 0.0 {
            regs[arg1 as usize] /= div;
        }
    }
    *pc += 4;
}

impl ResourcePackRuntime {
    pub fn execute_logic_tick(&mut self, entity_id: u16, bytecode_buffer: &[u8]) {
        if bytecode_buffer.is_empty() {
            return;
        }

        const MAX_INSTRUCTIONS: usize = 4096;

        let entity_offset = 32 + (entity_id as usize * 64);
        let mut pc = 0usize;
        let mut regs = [0.0f32; 8];
        let mut instructions = 0usize;

        while pc + 4 <= bytecode_buffer.len() {
            if instructions >= MAX_INSTRUCTIONS {
                break;
            }
            instructions += 1;

            let opcode = bytecode_buffer[pc];
            let arg1 = bytecode_buffer[pc + 1];
            let val_u16 =
                ((bytecode_buffer[pc + 2] as u16) << 8) | (bytecode_buffer[pc + 3] as u16);

            if (opcode as usize) < JUMP_TABLE.len() {
                unsafe {
                    JUMP_TABLE[opcode as usize](
                        self,
                        entity_offset,
                        arg1,
                        val_u16,
                        &mut regs,
                        &mut pc,
                        bytecode_buffer,
                    );
                }
            } else {
                break;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Fuzz tests for the bytecode sandbox VM.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    /// Tiny deterministic PRNG so fuzzing is reproducible without adding a
    /// dependency on `rand`.
    struct Xorshift64(u64);

    impl Xorshift64 {
        fn next_u64(&mut self) -> u64 {
            let mut x = self.0;
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            self.0 = x;
            x
        }

        fn next_u8(&mut self) -> u8 {
            self.next_u64() as u8
        }

        fn next_usize(&mut self, max: usize) -> usize {
            if max == 0 {
                return 0;
            }
            (self.next_u64() as usize) % max
        }
    }

    fn fresh_runtime(arena_size: usize) -> (ResourcePackRuntime, Vec<u8>) {
        let mut arena = vec![0u8; arena_size];
        let runtime = ResourcePackRuntime {
            arena_start_ptr: arena.as_mut_ptr(),
            arena_size,
        };
        (runtime, arena)
    }

    #[test]
    fn fuzz_random_bytecodes_100k() {
        let mut rng = Xorshift64(0x1234_5678_9ABC_DEF0);
        let (mut runtime, _arena) = fresh_runtime(4096);

        for _ in 0..100_000 {
            let len = 4 + rng.next_usize(252); // 4..255 bytes
            let mut bytecode = Vec::with_capacity(len);
            for _ in 0..len {
                bytecode.push(rng.next_u8());
            }

            // Vary the entity id across the small, valid range for a 4 KB Arena.
            let entity_id = rng.next_usize(8) as u16;
            runtime.execute_logic_tick(entity_id, &bytecode);
        }
    }

    #[test]
    fn fuzz_truncated_bytecodes() {
        let mut rng = Xorshift64(0xFEDC_BA98_7654_3210);
        let (mut runtime, _arena) = fresh_runtime(4096);

        for _ in 0..10_000 {
            let len = rng.next_usize(16); // 0..15 bytes, often not a multiple of 4
            let mut bytecode = Vec::with_capacity(len);
            for _ in 0..len {
                bytecode.push(rng.next_u8());
            }
            runtime.execute_logic_tick(0, &bytecode);
        }
    }

    #[test]
    fn fuzz_out_of_bounds_jump_targets() {
        let (mut runtime, _arena) = fresh_runtime(4096);

        // JMP to instruction 255 on a tiny buffer -> entity-local HALT.
        runtime.execute_logic_tick(0, &[0x09, 0xFF, 0x00, 0x00]);

        // JMP_LT to instruction 255 -> entity-local HALT when the branch is taken.
        runtime.execute_logic_tick(0, &[0x08, 0x00, 0x00, 0xFF]);

        // Mix jumps with random noise.
        let mut rng = Xorshift64(0xAABB_CCDD_EEFF_0011);
        for _ in 0..1_000 {
            let mut bytecode = Vec::with_capacity(64);
            for _ in 0..16 {
                bytecode.push(rng.next_u8());
            }
            // Force an unconditional jump to a target well beyond the buffer.
            bytecode[0] = 0x09;
            bytecode[1] = 0xFF;
            runtime.execute_logic_tick(0, &bytecode);
        }
    }
}
