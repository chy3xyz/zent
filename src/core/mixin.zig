const field = @import("field.zig");

/// A mixin that adds created_at and updated_at timestamp fields.
pub const TimeMixin = struct {
    pub const fields = &[_]field.Field{
        field.Time("created_at").Optional(),
        field.Time("updated_at").Optional(),
    };
};

/// Audit-user fields (created_by / updated_by) auto-filled from
/// PrivacyContext.user_id on Create/Update unless set explicitly.
pub const AuditMixin = struct {
    pub const fields = &[_]field.Field{
        field.Int("created_by").Optional(),
        field.Int("updated_by").Optional(),
    };
};

/// A mixin that adds a deleted_at timestamp field for soft-delete support.
pub const SoftDeleteMixin = struct {
    pub const fields = &[_]field.Field{
        field.Time("deleted_at").Optional(),
    };
};
