// Payload schema identifiers shared between the CLI compiler and the runtime.
//
// Keep this file in sync with `malphas_core/src/payload_schema.rs`.

pub type PayloadTypeId = u32;

pub const PAYLOAD_TYPE_UNKNOWN: PayloadTypeId = 0;
pub const PAYLOAD_TYPE_RECTANGLE: PayloadTypeId = 1;
pub const PAYLOAD_TYPE_SPRITE: PayloadTypeId = 2;
pub const PAYLOAD_TYPE_SOUND: PayloadTypeId = 3;
pub const PAYLOAD_TYPE_TEXT: PayloadTypeId = 4;
pub const PAYLOAD_TYPE_PHYSICS_BODY: PayloadTypeId = 5;
pub const PAYLOAD_TYPE_TRANSFORM: PayloadTypeId = 6;

/// Map a payload type name to its id.  Unknown names are mapped to
/// `PAYLOAD_TYPE_UNKNOWN` so the runtime can treat them as opaque blobs.
pub fn payload_type_id_from_name(name: &str) -> PayloadTypeId {
    match name.to_ascii_lowercase().as_str() {
        "rectangle" => PAYLOAD_TYPE_RECTANGLE,
        "sprite" => PAYLOAD_TYPE_SPRITE,
        "sound" => PAYLOAD_TYPE_SOUND,
        "text" => PAYLOAD_TYPE_TEXT,
        "physics_body" | "physics-body" | "physicsbody" => PAYLOAD_TYPE_PHYSICS_BODY,
        "transform" => PAYLOAD_TYPE_TRANSFORM,
        _ => PAYLOAD_TYPE_UNKNOWN,
    }
}
