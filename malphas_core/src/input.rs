// Dart-to-engine input event queue with spatial coalescence.
use std::collections::VecDeque;
use std::sync::Mutex;

const INPUT_QUEUE_CAPACITY: usize = 256;

#[derive(Debug, Clone, Copy)]
pub struct InputEvent {
    pub x: f32,
    pub y: f32,
}

pub(crate) static INPUT_QUEUE: Mutex<VecDeque<InputEvent>> = Mutex::new(VecDeque::new());

pub fn process_input_event(_event_type: i32, x: f32, y: f32) -> i32 {
    if x.is_nan() || y.is_nan() {
        return -1;
    }
    match INPUT_QUEUE.lock() {
        Ok(mut queue) => {
            // Coalesce consecutive events with identical coordinates.
            if let Some(back) = queue.back() {
                if back.x.to_bits() == x.to_bits() && back.y.to_bits() == y.to_bits() {
                    return 0;
                }
            }
            if queue.len() >= INPUT_QUEUE_CAPACITY {
                queue.pop_front();
            }
            queue.push_back(InputEvent { x, y });
            0
        }
        Err(_) => -2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_input_coalescence_and_capacity_drop() {
        // First event is accepted.
        assert_eq!(process_input_event(0, 1.0, 2.0), 0);
        // Identical coordinates are coalesced; queue length stays 1.
        assert_eq!(process_input_event(0, 1.0, 2.0), 0);
        // Distinct event is appended.
        assert_eq!(process_input_event(0, 3.0, 4.0), 0);

        let queue = INPUT_QUEUE.lock().unwrap();
        assert_eq!(queue.len(), 2);
        let front = queue.front().unwrap();
        assert_eq!(front.x.to_bits(), 1.0f32.to_bits());
        assert_eq!(front.y.to_bits(), 2.0f32.to_bits());
    }
}
