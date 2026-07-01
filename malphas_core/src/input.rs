// Dart-to-engine input event queue with spatial coalescence.
#[cfg(test)]
use std::cell::RefCell;
use std::collections::VecDeque;

const INPUT_QUEUE_CAPACITY: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum InputEventType {
    Touch = 0,
    Move = 1,
    Up = 2,
}

impl TryFrom<i32> for InputEventType {
    type Error = ();

    fn try_from(value: i32) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(InputEventType::Touch),
            1 => Ok(InputEventType::Move),
            2 => Ok(InputEventType::Up),
            _ => Err(()),
        }
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct InputEvent {
    pub event_type: InputEventType,
    pub x: f32,
    pub y: f32,
}

#[cfg(not(test))]
static INPUT_QUEUE: std::sync::Mutex<VecDeque<InputEvent>> = std::sync::Mutex::new(VecDeque::new());

#[cfg(test)]
thread_local! {
    static TEST_INPUT_QUEUE: RefCell<VecDeque<InputEvent>> = RefCell::new(VecDeque::with_capacity(INPUT_QUEUE_CAPACITY));
}

#[cfg(not(test))]
fn with_input_queue<F, R>(f: F) -> R
where
    F: FnOnce(&mut VecDeque<InputEvent>) -> R,
{
    let mut guard = INPUT_QUEUE.lock().unwrap();
    f(&mut guard)
}

#[cfg(test)]
fn with_input_queue<F, R>(f: F) -> R
where
    F: FnOnce(&mut VecDeque<InputEvent>) -> R,
{
    TEST_INPUT_QUEUE.with(|q| f(&mut q.borrow_mut()))
}

/// Reset the input queue to an empty state.  Only available in tests so each
/// test starts from a known baseline.
#[cfg(test)]
pub fn reset_input_queue_for_tests() {
    with_input_queue(|queue| queue.clear());
}

/// Drain every pending input event from the queue.  Called once per engine
/// tick so events never accumulate unbounded.
pub fn drain_input_events() -> Vec<InputEvent> {
    with_input_queue(|queue| queue.drain(..).collect())
}

pub fn process_input_event(event_type: i32, x: f32, y: f32) -> i32 {
    let event_type = match InputEventType::try_from(event_type) {
        Ok(t) => t,
        Err(_) => return -1,
    };

    // Reject NaN and +/- Infinity.
    if !x.is_finite() || !y.is_finite() {
        return -1;
    }

    let event = InputEvent { event_type, x, y };

    with_input_queue(|queue| {
        // Coalesce consecutive events with identical type and coordinates by
        // inspecting the back without removing it.
        if let Some(back) = queue.back() {
            if back.event_type == event_type
                && back.x.to_bits() == x.to_bits()
                && back.y.to_bits() == y.to_bits()
            {
                return 0;
            }
        }

        // Keep the queue bounded; drop the oldest event on overflow.
        if queue.len() >= INPUT_QUEUE_CAPACITY {
            queue.pop_front();
        }
        queue.push_back(event);
        0
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_input_coalescence_and_capacity_drop() {
        reset_input_queue_for_tests();

        // First event is accepted.
        assert_eq!(process_input_event(0, 1.0, 2.0), 0);
        // Identical coordinates are coalesced; queue length stays 1.
        assert_eq!(process_input_event(0, 1.0, 2.0), 0);
        // Distinct event is appended.
        assert_eq!(process_input_event(1, 3.0, 4.0), 0);

        let queue = drain_input_events();
        assert_eq!(queue.len(), 2);
        assert_eq!(queue[0].event_type, InputEventType::Touch);
        assert_eq!(queue[0].x.to_bits(), 1.0f32.to_bits());
        assert_eq!(queue[0].y.to_bits(), 2.0f32.to_bits());
        assert_eq!(queue[1].event_type, InputEventType::Move);
        assert_eq!(queue[1].x.to_bits(), 3.0f32.to_bits());
        assert_eq!(queue[1].y.to_bits(), 4.0f32.to_bits());
    }

    #[test]
    fn input_queue_coalescence_preserves_order() {
        reset_input_queue_for_tests();

        // Identical events coalesce.
        assert_eq!(process_input_event(0, 1.0, 2.0), 0);
        assert_eq!(process_input_event(0, 1.0, 2.0), 0);
        // Distinct events keep order even when coordinates partially match.
        assert_eq!(process_input_event(0, 3.0, 4.0), 0);
        assert_eq!(process_input_event(1, 3.0, 4.0), 0);
        assert_eq!(process_input_event(0, 1.0, 2.0), 0);

        let queue = drain_input_events();
        assert_eq!(queue.len(), 4);
        assert_eq!(queue[0].event_type, InputEventType::Touch);
        assert_eq!(queue[0].x.to_bits(), 1.0f32.to_bits());
        assert_eq!(queue[1].event_type, InputEventType::Touch);
        assert_eq!(queue[1].x.to_bits(), 3.0f32.to_bits());
        assert_eq!(queue[2].event_type, InputEventType::Move);
        assert_eq!(queue[2].x.to_bits(), 3.0f32.to_bits());
        assert_eq!(queue[3].event_type, InputEventType::Touch);
        assert_eq!(queue[3].x.to_bits(), 1.0f32.to_bits());
    }

    #[test]
    fn test_invalid_event_type_is_rejected() {
        reset_input_queue_for_tests();
        assert_eq!(process_input_event(-1, 0.0, 0.0), -1);
        assert_eq!(process_input_event(3, 0.0, 0.0), -1);
        assert_eq!(process_input_event(0, 0.0, 0.0), 0);
    }

    #[test]
    fn test_non_finite_coordinates_are_rejected() {
        reset_input_queue_for_tests();
        assert_eq!(process_input_event(0, f32::NAN, 0.0), -1);
        assert_eq!(process_input_event(0, 0.0, f32::NAN), -1);
        assert_eq!(process_input_event(0, f32::INFINITY, 0.0), -1);
        assert_eq!(process_input_event(0, 0.0, f32::NEG_INFINITY), -1);
    }

    #[test]
    fn test_capacity_drops_oldest_event() {
        reset_input_queue_for_tests();
        // Fill the queue.
        for i in 0..INPUT_QUEUE_CAPACITY {
            assert_eq!(process_input_event(0, i as f32, 0.0), 0);
        }
        // Push one more; the oldest event should be dropped.
        assert_eq!(process_input_event(0, 999.0, 0.0), 0);

        let queue = drain_input_events();
        assert_eq!(queue.len(), INPUT_QUEUE_CAPACITY);
        // The very first event (0.0) should have been evicted.
        assert_ne!(queue[0].x.to_bits(), 0.0f32.to_bits());
        // The newest event must be present at the back.
        assert_eq!(queue.last().unwrap().x.to_bits(), 999.0f32.to_bits());
    }
}
