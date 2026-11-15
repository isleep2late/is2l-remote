#[cfg(not(target_os = "linux"))]
mod imp {
    use base::message_proto::GamepadEvent;

    pub fn handle_event(_conn_id: i32, _evt: &GamepadEvent) {}

    pub fn on_connection_closed(_conn_id: i32) {}
}

#[cfg(target_os = "linux")]
mod imp {
    use crate::ipc::DataGamepad;
    use crate::server::uinput::client::UInputGamepad;
    use base::message_proto::GamepadEvent;
    use hbb_common::{config::Config, log};
    use std::{
        collections::{HashMap, VecDeque},
        sync::{mpsc, Mutex},
        time::{Duration, Instant},
    };

    pub const OPTION_ALLOW_GAMEPAD: &str = "allow-gamepad";
    pub const MAX_GAMEPADS_PER_CONNECTION: u32 = 4;
    pub const MAX_GAMEPADS: usize = 8;
    pub const MAX_CREATIONS_PER_MINUTE: usize = 8;
    const CREATION_WINDOW: Duration = Duration::from_secs(60);
    const RECONNECT_INTERVAL: Duration = Duration::from_secs(1);
    const ERROR_LOG_INTERVAL: Duration = Duration::from_secs(5);

    pub const EV_KEY: u16 = 0x01;
    pub const EV_ABS: u16 = 0x03;

    pub const BTN_SOUTH: u16 = 0x130;
    pub const BTN_EAST: u16 = 0x131;
    pub const BTN_NORTH: u16 = 0x133;
    pub const BTN_WEST: u16 = 0x134;
    pub const BTN_TL: u16 = 0x136;
    pub const BTN_TR: u16 = 0x137;
    pub const BTN_SELECT: u16 = 0x13a;
    pub const BTN_START: u16 = 0x13b;
    pub const BTN_MODE: u16 = 0x13c;
    pub const BTN_THUMBL: u16 = 0x13d;
    pub const BTN_THUMBR: u16 = 0x13e;

    pub const ABS_X: u16 = 0x00;
    pub const ABS_Y: u16 = 0x01;
    pub const ABS_Z: u16 = 0x02;
    pub const ABS_RX: u16 = 0x03;
    pub const ABS_RY: u16 = 0x04;
    pub const ABS_RZ: u16 = 0x05;
    pub const ABS_HAT0X: u16 = 0x10;
    pub const ABS_HAT0Y: u16 = 0x11;

    pub const STICK_MIN: i32 = -32768;
    pub const STICK_MAX: i32 = 32767;
    pub const STICK_FUZZ: i32 = 16;
    pub const STICK_FLAT: i32 = 128;
    pub const TRIGGER_MAX: i32 = 255;

    pub const BUTTON_CODES: [u16; 11] = [
        BTN_SOUTH, BTN_EAST, BTN_NORTH, BTN_WEST, BTN_TL, BTN_TR, BTN_SELECT, BTN_START, BTN_MODE,
        BTN_THUMBL, BTN_THUMBR,
    ];

    pub const DPAD_UP: u32 = 1 << 11;
    pub const DPAD_DOWN: u32 = 1 << 12;
    pub const DPAD_LEFT: u32 = 1 << 13;
    pub const DPAD_RIGHT: u32 = 1 << 14;
    pub const BUTTON_MASK: u32 = (1 << 15) - 1;

    pub const AXES: [(u16, i32, i32, i32, i32); 8] = [
        (ABS_X, STICK_MIN, STICK_MAX, STICK_FUZZ, STICK_FLAT),
        (ABS_Y, STICK_MIN, STICK_MAX, STICK_FUZZ, STICK_FLAT),
        (ABS_RX, STICK_MIN, STICK_MAX, STICK_FUZZ, STICK_FLAT),
        (ABS_RY, STICK_MIN, STICK_MAX, STICK_FUZZ, STICK_FLAT),
        (ABS_Z, 0, TRIGGER_MAX, 0, 0),
        (ABS_RZ, 0, TRIGGER_MAX, 0, 0),
        (ABS_HAT0X, -1, 1, 0, 0),
        (ABS_HAT0Y, -1, 1, 0, 0),
    ];

    #[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
    pub struct GamepadState {
        pub buttons: u32,
        pub lx: i32,
        pub ly: i32,
        pub rx: i32,
        pub ry: i32,
        pub lt: i32,
        pub rt: i32,
    }

    impl GamepadState {
        pub fn new(buttons: u32, lx: i32, ly: i32, rx: i32, ry: i32, lt: u32, rt: u32) -> Self {
            Self {
                buttons: buttons & BUTTON_MASK,
                lx: lx.clamp(STICK_MIN, STICK_MAX),
                ly: ly.clamp(STICK_MIN, STICK_MAX),
                rx: rx.clamp(STICK_MIN, STICK_MAX),
                ry: ry.clamp(STICK_MIN, STICK_MAX),
                lt: lt.min(TRIGGER_MAX as u32) as i32,
                rt: rt.min(TRIGGER_MAX as u32) as i32,
            }
        }

        pub fn hat(&self) -> (i32, i32) {
            let pressed = |bit: u32| (self.buttons & bit != 0) as i32;
            (
                pressed(DPAD_RIGHT) - pressed(DPAD_LEFT),
                pressed(DPAD_DOWN) - pressed(DPAD_UP),
            )
        }
    }

    pub fn diff_state(prev: &GamepadState, next: &GamepadState) -> Vec<(u16, u16, i32)> {
        let mut events = Vec::new();
        let changed = prev.buttons ^ next.buttons;
        for (bit, code) in BUTTON_CODES.iter().enumerate() {
            if changed & (1 << bit) != 0 {
                events.push((EV_KEY, *code, (next.buttons >> bit & 1) as i32));
            }
        }
        let (prev_hat_x, prev_hat_y) = prev.hat();
        let (next_hat_x, next_hat_y) = next.hat();
        for (code, prev_value, next_value) in [
            (ABS_X, prev.lx, next.lx),
            (ABS_Y, prev.ly, next.ly),
            (ABS_RX, prev.rx, next.rx),
            (ABS_RY, prev.ry, next.ry),
            (ABS_Z, prev.lt, next.lt),
            (ABS_RZ, prev.rt, next.rt),
            (ABS_HAT0X, prev_hat_x, next_hat_x),
            (ABS_HAT0Y, prev_hat_y, next_hat_y),
        ] {
            if prev_value != next_value {
                events.push((EV_ABS, code, next_value));
            }
        }
        events
    }

    pub fn allow_creation(history: &mut VecDeque<Instant>, now: Instant) -> bool {
        while let Some(first) = history.front() {
            if now.saturating_duration_since(*first) >= CREATION_WINDOW {
                history.pop_front();
            } else {
                break;
            }
        }
        if history.len() >= MAX_CREATIONS_PER_MINUTE {
            return false;
        }
        history.push_back(now);
        true
    }

    lazy_static::lazy_static! {
        static ref SENDER: Mutex<Option<mpsc::Sender<DataGamepad>>> = Default::default();
        static ref STATES: Mutex<HashMap<(i32, u32), GamepadState>> = Default::default();
    }

    pub fn is_enabled() -> bool {
        Config::get_option(OPTION_ALLOW_GAMEPAD) != "N"
    }

    pub fn handle_event(conn_id: i32, evt: &GamepadEvent) {
        if !is_enabled() {
            on_connection_closed(conn_id);
            return;
        }
        if evt.index >= MAX_GAMEPADS_PER_CONNECTION {
            return;
        }
        let key = (conn_id, evt.index);
        let state = GamepadState::new(
            evt.buttons,
            evt.lx,
            evt.ly,
            evt.rx,
            evt.ry,
            evt.lt,
            evt.rt,
        );
        {
            let mut states = STATES.lock().unwrap();
            if evt.connected {
                if states.get(&key) == Some(&state) {
                    return;
                }
                states.insert(key, state);
            } else if states.remove(&key).is_none() {
                return;
            }
        }
        send(DataGamepad::State {
            conn_id,
            index: evt.index,
            connected: evt.connected,
            buttons: state.buttons,
            lx: state.lx,
            ly: state.ly,
            rx: state.rx,
            ry: state.ry,
            lt: state.lt as u32,
            rt: state.rt as u32,
        });
    }

    pub fn on_connection_closed(conn_id: i32) {
        let removed = {
            let mut states = STATES.lock().unwrap();
            let count = states.len();
            states.retain(|key, _| key.0 != conn_id);
            count != states.len()
        };
        if removed {
            send(DataGamepad::Close(conn_id));
        }
    }

    fn send(data: DataGamepad) {
        let mut sender = SENDER.lock().unwrap();
        let data = match sender.as_ref() {
            Some(tx) => match tx.send(data) {
                Ok(()) => return,
                Err(err) => err.0,
            },
            None => data,
        };
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || run(rx));
        tx.send(data).ok();
        *sender = Some(tx);
    }

    fn run(rx: mpsc::Receiver<DataGamepad>) {
        let mut client: Option<UInputGamepad> = None;
        let mut last_failure: Option<Instant> = None;
        for data in rx {
            if client.is_none() {
                if last_failure.is_some_and(|at| at.elapsed() < RECONNECT_INTERVAL) {
                    STATES.lock().unwrap().clear();
                    continue;
                }
                match UInputGamepad::new() {
                    Ok(connected) => {
                        log::info!("Connected to the uinput gamepad service");
                        client = Some(connected);
                    }
                    Err(err) => {
                        hbb_common::throttled_log!(
                            ERROR_LOG_INTERVAL,
                            warn,
                            "Failed to connect to the uinput gamepad service: {}",
                            err
                        );
                        last_failure = Some(Instant::now());
                        STATES.lock().unwrap().clear();
                        continue;
                    }
                }
            }
            let result = match client.as_mut() {
                Some(connected) => connected.send(data),
                None => continue,
            };
            if let Err(err) = result {
                log::warn!("Uinput gamepad ipc connection closed: {}", err);
                client = None;
                last_failure = Some(Instant::now());
                STATES.lock().unwrap().clear();
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn state(buttons: u32) -> GamepadState {
            GamepadState::new(buttons, 0, 0, 0, 0, 0, 0)
        }

        #[test]
        fn button_bits_follow_the_contract_order() {
            let expected = [
                (0, BTN_SOUTH),
                (1, BTN_EAST),
                (4, BTN_TL),
                (5, BTN_TR),
                (6, BTN_SELECT),
                (7, BTN_START),
                (8, BTN_MODE),
                (9, BTN_THUMBL),
                (10, BTN_THUMBR),
            ];
            for (bit, code) in expected {
                assert_eq!(
                    diff_state(&state(0), &state(1 << bit)),
                    vec![(EV_KEY, code, 1)]
                );
                assert_eq!(
                    diff_state(&state(1 << bit), &state(0)),
                    vec![(EV_KEY, code, 0)]
                );
            }
        }

        #[test]
        fn x_and_y_use_the_codes_the_xbox_360_driver_reports() {
            assert_eq!(BTN_NORTH, 0x133);
            assert_eq!(BTN_WEST, 0x134);
            assert_eq!(
                diff_state(&state(0), &state(1 << 2)),
                vec![(EV_KEY, 0x133, 1)]
            );
            assert_eq!(
                diff_state(&state(0), &state(1 << 3)),
                vec![(EV_KEY, 0x134, 1)]
            );
        }

        #[test]
        fn dpad_bits_become_hat_axes() {
            assert_eq!(state(DPAD_UP).hat(), (0, -1));
            assert_eq!(state(DPAD_DOWN).hat(), (0, 1));
            assert_eq!(state(DPAD_LEFT).hat(), (-1, 0));
            assert_eq!(state(DPAD_RIGHT).hat(), (1, 0));
            assert_eq!(state(DPAD_LEFT | DPAD_RIGHT).hat(), (0, 0));
            assert_eq!(
                diff_state(&state(0), &state(DPAD_UP | DPAD_RIGHT)),
                vec![(EV_ABS, ABS_HAT0X, 1), (EV_ABS, ABS_HAT0Y, -1)]
            );
            assert_eq!(
                diff_state(&state(DPAD_UP), &state(DPAD_DOWN)),
                vec![(EV_ABS, ABS_HAT0Y, 1)]
            );
        }

        #[test]
        fn unchanged_state_emits_nothing() {
            let current = GamepadState::new(0x7fff, 1, -2, 3, -4, 5, 6);
            assert!(diff_state(&current, &current).is_empty());
        }

        #[test]
        fn only_changed_axes_are_emitted() {
            let prev = GamepadState::new(1, 100, 200, 300, 400, 10, 20);
            let next = GamepadState::new(1, 100, -200, 300, 401, 10, 255);
            assert_eq!(
                diff_state(&prev, &next),
                vec![
                    (EV_ABS, ABS_Y, -200),
                    (EV_ABS, ABS_RY, 401),
                    (EV_ABS, ABS_RZ, 255)
                ]
            );
        }

        #[test]
        fn release_all_returns_every_control_to_rest() {
            let held = GamepadState::new(1 | 1 << 7 | DPAD_LEFT, -32768, 0, 0, 32767, 255, 0);
            assert_eq!(
                diff_state(&held, &GamepadState::default()),
                vec![
                    (EV_KEY, BTN_SOUTH, 0),
                    (EV_KEY, BTN_START, 0),
                    (EV_ABS, ABS_X, 0),
                    (EV_ABS, ABS_RY, 0),
                    (EV_ABS, ABS_Z, 0),
                    (EV_ABS, ABS_HAT0X, 0)
                ]
            );
        }

        #[test]
        fn out_of_range_values_are_clamped() {
            let clamped = GamepadState::new(u32::MAX, -40000, 40000, i32::MIN, i32::MAX, 256, 9999);
            assert_eq!(clamped.buttons, BUTTON_MASK);
            assert_eq!(
                (clamped.lx, clamped.ly, clamped.rx, clamped.ry),
                (STICK_MIN, STICK_MAX, STICK_MIN, STICK_MAX)
            );
            assert_eq!((clamped.lt, clamped.rt), (TRIGGER_MAX, TRIGGER_MAX));
        }

        #[test]
        fn every_reported_code_is_declared_on_the_device() {
            let all = GamepadState::new(BUTTON_MASK, 1, 1, 1, 1, 1, 1);
            for (kind, code, _) in diff_state(&GamepadState::default(), &all) {
                if kind == EV_KEY {
                    assert!(BUTTON_CODES.contains(&code));
                } else {
                    assert!(AXES.iter().any(|axis| axis.0 == code));
                }
            }
        }

        #[test]
        fn creation_is_rate_limited_per_minute() {
            let start = Instant::now();
            let mut history = VecDeque::new();
            for i in 0..MAX_CREATIONS_PER_MINUTE {
                assert!(allow_creation(
                    &mut history,
                    start + Duration::from_secs(i as u64)
                ));
            }
            assert!(!allow_creation(
                &mut history,
                start + Duration::from_secs(59)
            ));
            assert!(allow_creation(
                &mut history,
                start + Duration::from_secs(60)
            ));
            assert!(!allow_creation(
                &mut history,
                start + Duration::from_secs(60)
            ));
        }
    }
}

pub use imp::*;
