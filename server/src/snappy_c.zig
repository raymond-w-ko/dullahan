//! Bindings for the two Snappy C API functions that Dullahan uses.
//!
//! The ChainSafe snappy.zig wrapper module uses `@cImport`, which Zig 0.17
//! removed. Dullahan still links that package's static `snappy` library, but
//! declares these functions itself. Signatures match upstream `snappy-c.h`.

pub const Error = error{
    InvalidInput,
    BufferTooSmall,
};

/// `snappy_status` from `snappy-c.h`.
const Status = enum(c_int) {
    ok = 0,
    invalid_input = 1,
    buffer_too_small = 2,
    _,
};

extern "c" fn snappy_compress(
    input: [*]const u8,
    input_length: usize,
    compressed: [*]u8,
    compressed_length: *usize,
) Status;

extern "c" fn snappy_max_compressed_length(source_length: usize) usize;

/// Upper bound on the compressed size of `source_length` input bytes.
pub fn maxCompressedLength(source_length: usize) usize {
    return snappy_max_compressed_length(source_length);
}

/// Compress `input` into `compressed`. Returns the compressed length.
/// `compressed.len` must be at least `maxCompressedLength(input.len)`.
pub fn compress(input: []const u8, compressed: []u8) Error!usize {
    var compressed_length = compressed.len;
    return switch (snappy_compress(input.ptr, input.len, compressed.ptr, &compressed_length)) {
        .ok => compressed_length,
        .invalid_input => Error.InvalidInput,
        .buffer_too_small => Error.BufferTooSmall,
        _ => unreachable,
    };
}

test "compress round-trip length bound" {
    const std = @import("std");
    const input = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var buf: [128]u8 = undefined;
    try std.testing.expect(maxCompressedLength(input.len) <= buf.len);
    const n = try compress(input, &buf);
    try std.testing.expect(n > 0 and n < input.len);
}
