const field = @import("field.zig");

/// A mixin that adds created_at and updated_at timestamp fields.
pub const TimeMixin = struct {
    pub const fields = &[_]field.Field{
        field.Time("created_at").Optional(),
        field.Time("updated_at").Optional(),
    };
};
