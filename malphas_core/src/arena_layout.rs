// Shared Arena memory layout constants.
//
// The first 32 bytes of the Arena form a fixed header that is written by
// `init_engine` and read by both Rust and Dart.  These offsets must stay
// in sync with the Dart constants in `flutter_app/lib/core/ffi/arena_layout.dart`.

/// Magic bytes written at the start of the Arena (`b"MALP"`).
pub const ARENA_MAGIC: &[u8; 4] = b"MALP";

/// Offset to the 4-byte static-resources offset field.
pub const STATIC_RESOURCES_OFFSET: usize = 4;

/// Offset to the 4-byte static-resources size field.
pub const STATIC_RESOURCES_SIZE: usize = 8;

/// Offset to the 4-byte entities-offset field.
pub const ENTITIES_OFFSET: usize = 12;

/// Offset to the 4-byte entities-count field.
pub const ENTITIES_COUNT: usize = 16;

/// Offset to the 4-byte font-metrics offset field.
pub const FONT_METRICS_OFFSET: usize = 20;

/// Offset to the 4-byte font-atlas offset field.
pub const FONT_ATLAS_OFFSET: usize = 24;

/// Offset to the 4-byte objects-table offset field.
pub const OBJECTS_TABLE_OFFSET: usize = 28;

/// Total size of the Arena header in bytes.
pub const ARENA_HEADER_SIZE: usize = 32;

/// Default offset where static resources are copied after the header.
pub const DEFAULT_STATIC_RESOURCES_OFFSET: u32 = 1024;

/// Default offset where the entity table starts.
pub const DEFAULT_ENTITIES_OFFSET: u32 = 32;

/// Size of one entity slot in bytes.
pub const ENTITY_SLOT_SIZE: usize = 64;

/// Offset within an entity slot where the string offset is stored.
pub const ENTITY_STR_OFFSET: usize = 48;

/// Size of the `TextPayload` header in bytes.
pub const TEXT_PAYLOAD_SIZE: usize = std::mem::size_of::<crate::pipeline::TextPayload>();

/// Size of a `DartRenderCommand` in bytes.
pub const RENDER_COMMAND_SIZE: usize = std::mem::size_of::<crate::pipeline::DartRenderCommand>();

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pipeline::{
        CoreCommandBuffer, DartRenderCommand, MalphasDoubleBufferBridge, MhpHeader,
        MhpObjectDescriptor, MspHeader, TextPayload,
    };

    #[test]
    fn arena_header_offsets_are_consistent() {
        // Header fields must fit inside the declared header size.
        assert!(STATIC_RESOURCES_OFFSET + 4 <= ARENA_HEADER_SIZE);
        assert!(STATIC_RESOURCES_SIZE + 4 <= ARENA_HEADER_SIZE);
        assert!(ENTITIES_OFFSET + 4 <= ARENA_HEADER_SIZE);
        assert!(ENTITIES_COUNT + 4 <= ARENA_HEADER_SIZE);
        assert!(FONT_METRICS_OFFSET + 4 <= ARENA_HEADER_SIZE);
        assert!(FONT_ATLAS_OFFSET + 4 <= ARENA_HEADER_SIZE);
        assert!(OBJECTS_TABLE_OFFSET + 4 <= ARENA_HEADER_SIZE);
    }

    #[test]
    fn struct_sizes_match_layout_constants() {
        assert_eq!(TEXT_PAYLOAD_SIZE, std::mem::size_of::<TextPayload>());
        assert_eq!(
            RENDER_COMMAND_SIZE,
            std::mem::size_of::<DartRenderCommand>()
        );
        assert_eq!(
            ENTITY_SLOT_SIZE,
            std::mem::size_of::<DartRenderCommand>() + 40
        );
    }

    #[test]
    fn text_payload_fits_inside_entity_slot() {
        assert!(
            ENTITY_STR_OFFSET + 4 <= ENTITY_SLOT_SIZE,
            "string-offset field must fit inside entity slot"
        );
        assert!(
            TEXT_PAYLOAD_SIZE <= ENTITY_SLOT_SIZE,
            "a TextPayload must fit inside one entity slot"
        );
    }

    #[test]
    fn c_abi_struct_layouts_match_dart_expectations() {
        assert_eq!(std::mem::size_of::<DartRenderCommand>(), 24);
        assert_eq!(std::mem::align_of::<DartRenderCommand>(), 4);
        assert_eq!(std::mem::size_of::<CoreCommandBuffer>(), 16);
        assert_eq!(std::mem::align_of::<CoreCommandBuffer>(), 16);
        assert_eq!(std::mem::size_of::<MalphasDoubleBufferBridge>(), 48);
        assert_eq!(std::mem::align_of::<MalphasDoubleBufferBridge>(), 16);
        assert_eq!(std::mem::size_of::<MhpHeader>(), 112);
        assert_eq!(std::mem::align_of::<MhpHeader>(), 16);
        assert_eq!(std::mem::size_of::<MhpObjectDescriptor>(), 32);
        assert_eq!(std::mem::align_of::<MhpObjectDescriptor>(), 16);
        assert_eq!(std::mem::size_of::<MspHeader>(), 64);
        assert_eq!(std::mem::align_of::<MspHeader>(), 16);
    }
}
