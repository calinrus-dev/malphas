// Payload schema registry for Malphas v3.0.0.
//
// The registry maps a `payload_type_id` to the binary layout a system must use
// to interpret the payload bytes.  The core uses it to validate MSPs at load
// time; systems use it to agree on memory layout without runtime reflection.

/// Opaque identifier for a payload type.  `0` is reserved for unknown/legacy
/// payloads; values `1..=6` are built-in types.
pub type PayloadTypeId = u32;

pub const PAYLOAD_TYPE_UNKNOWN: PayloadTypeId = 0;
pub const PAYLOAD_TYPE_RECTANGLE: PayloadTypeId = 1;
pub const PAYLOAD_TYPE_SPRITE: PayloadTypeId = 2;
pub const PAYLOAD_TYPE_SOUND: PayloadTypeId = 3;
pub const PAYLOAD_TYPE_TEXT: PayloadTypeId = 4;
pub const PAYLOAD_TYPE_PHYSICS_BODY: PayloadTypeId = 5;
pub const PAYLOAD_TYPE_TRANSFORM: PayloadTypeId = 6;

/// Static description of a payload layout.
#[derive(Clone, Copy, Debug)]
pub struct PayloadSchema {
    /// Size of the payload in bytes.
    pub size: usize,
    /// Required alignment of the payload in bytes.
    pub alignment: usize,
}

/// Registry of known payload schemas indexed by `PayloadTypeId`.
///
/// The table is small and fixed-size so lookup is a single indexed access with
/// no branches on the hot path.
pub struct PayloadSchemaRegistry {
    schemas: [Option<PayloadSchema>; 8],
}

impl PayloadSchemaRegistry {
    /// Register a schema for the given type id.  Panics if `id` is outside the
    /// fixed table range.
    pub fn register(&mut self, id: PayloadTypeId, schema: PayloadSchema) {
        let index = id as usize;
        assert!(
            index < self.schemas.len(),
            "payload type id {} exceeds registry capacity",
            id
        );
        self.schemas[index] = Some(schema);
    }

    /// Look up the schema for a type id.  Returns `None` for unknown or
    /// unregistered ids.
    #[inline]
    pub fn get(&self, id: PayloadTypeId) -> Option<&PayloadSchema> {
        self.schemas.get(id as usize).and_then(|slot| slot.as_ref())
    }
}

impl Default for PayloadSchemaRegistry {
    /// Create the registry with the built-in v3.0.0 schemas.
    fn default() -> Self {
        let mut registry = Self { schemas: [None; 8] };
        registry.register(
            PAYLOAD_TYPE_RECTANGLE,
            PayloadSchema {
                size: 64,
                alignment: 64,
            },
        );
        registry.register(
            PAYLOAD_TYPE_SPRITE,
            PayloadSchema {
                size: 64,
                alignment: 64,
            },
        );
        registry.register(
            PAYLOAD_TYPE_SOUND,
            PayloadSchema {
                size: 64,
                alignment: 64,
            },
        );
        registry.register(
            PAYLOAD_TYPE_TEXT,
            PayloadSchema {
                size: 64,
                alignment: 64,
            },
        );
        registry.register(
            PAYLOAD_TYPE_PHYSICS_BODY,
            PayloadSchema {
                size: 64,
                alignment: 64,
            },
        );
        registry.register(
            PAYLOAD_TYPE_TRANSFORM,
            PayloadSchema {
                size: 64,
                alignment: 64,
            },
        );
        registry
    }
}
