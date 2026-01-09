//! Embedded client assets for single-binary distribution.
//!
//! This is a stub file for debug builds - no assets are embedded.
//! For distribution builds, run `make dist` which generates the real
//! embedded assets by running scripts/generate-embedded-assets.ts.
//!
//! DO NOT COMMIT GENERATED VERSIONS OF THIS FILE.

const std = @import("std");

pub const Asset = struct {
    content: []const u8,
    mime_type: []const u8,
    etag: []const u8,
};

/// In debug/stub builds, no assets are embedded
pub const embedded_files = std.StaticStringMap(Asset).initComptime(.{});

/// Get an embedded asset by path, returns null if not found
pub fn get(path: []const u8) ?Asset {
    return embedded_files.get(path);
}

/// Check if we have embedded assets (false in debug stub)
pub fn hasEmbeddedAssets() bool {
    return embedded_files.count() > 0;
}
