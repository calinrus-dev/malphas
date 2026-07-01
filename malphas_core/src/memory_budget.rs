//! Per-process memory budget for mapped MSPs and runtime buffers.
//!
//! The budget is intentionally coarse: it tracks bytes that Rust allocates or
//! maps on behalf of the engine so that a single oversized artifact cannot
//! exhaust the host.  It does not attempt to account for every allocation made
//! by loaded systems.

use std::sync::atomic::{AtomicUsize, Ordering};

const DEFAULT_BUDGET_BYTES: usize = 512 * 1024 * 1024;

static BUDGET_LIMIT: AtomicUsize = AtomicUsize::new(DEFAULT_BUDGET_BYTES);
static BUDGET_USED: AtomicUsize = AtomicUsize::new(0);

/// Error returned when an allocation would exceed the configured budget.
pub const ERR_MEMORY_BUDGET_EXCEEDED: i32 = -130;

/// Sets the process-wide memory budget in bytes.
pub fn set_budget_bytes(bytes: usize) {
    BUDGET_LIMIT.store(bytes.max(1), Ordering::SeqCst);
}

/// Returns the current budget limit in bytes.
pub fn budget_limit_bytes() -> usize {
    BUDGET_LIMIT.load(Ordering::SeqCst)
}

/// Returns the number of bytes currently charged against the budget.
pub fn budget_used_bytes() -> usize {
    BUDGET_USED.load(Ordering::SeqCst)
}

/// Attempts to reserve [bytes] against the budget.
///
/// Returns [ERR_MEMORY_BUDGET_EXCEEDED] if the reservation would exceed the
/// limit.  Successful reservations must be paired with [release].
pub fn try_reserve(bytes: usize) -> Result<(), i32> {
    if bytes == 0 {
        return Ok(());
    }
    let limit = BUDGET_LIMIT.load(Ordering::SeqCst);
    let mut current = BUDGET_USED.load(Ordering::SeqCst);
    loop {
        if current.saturating_add(bytes) > limit {
            return Err(ERR_MEMORY_BUDGET_EXCEEDED);
        }
        match BUDGET_USED.compare_exchange_weak(
            current,
            current + bytes,
            Ordering::SeqCst,
            Ordering::SeqCst,
        ) {
            Ok(_) => return Ok(()),
            Err(c) => current = c,
        }
    }
}

/// Releases a previous reservation.
pub fn release(bytes: usize) {
    if bytes == 0 {
        return;
    }
    BUDGET_USED.fetch_sub(bytes, Ordering::SeqCst);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn budget_reserves_and_releases() {
        let original_limit = budget_limit_bytes();
        set_budget_bytes(100);
        release(budget_used_bytes()); // reset
        assert_eq!(budget_used_bytes(), 0);

        try_reserve(40).unwrap();
        assert_eq!(budget_used_bytes(), 40);

        try_reserve(60).unwrap();
        assert_eq!(budget_used_bytes(), 100);

        assert_eq!(try_reserve(1), Err(ERR_MEMORY_BUDGET_EXCEEDED));

        release(40);
        assert_eq!(budget_used_bytes(), 60);

        release(60);
        assert_eq!(budget_used_bytes(), 0);

        set_budget_bytes(original_limit);
    }
}
