//! Shell delta sync test
//!
//! Spawns a real shell, presses up arrow, and compares delta vs snapshot.
//! This tests the actual terminal rendering path end-to-end.
//!
//! Run with: zig build run-shell-delta-test

const std = @import("std");
const posix = std.posix;
const dullahan = @import("dullahan");
const Pane = dullahan.Pane;
const Pty = dullahan.Pty;
const snapshot = dullahan.snapshot;

const log = std.log.scoped(.shell_delta_test);

const UP_ARROW = "\x1b[A";
const DOWN_ARROW = "\x1b[B";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create pane with reasonable size
    var pane = try Pane.init(allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer pane.deinit();

    // Open PTY
    var pty = try Pty.open(.{
        .ws_row = 24,
        .ws_col = 80,
    });
    // Don't defer deinit here - pane will handle it

    // Spawn fish with interactive mode
    // Use fish to reproduce the user's issue with history navigation
    const fish_path: [:0]const u8 = "/etc/profiles/per-user/rko/bin/fish";

    // Set up environment for fish - null-terminated array of null-terminated strings
    const env: [5:null]?[*:0]const u8 = .{
        "TERM=xterm-256color",
        "HOME=/Users/rko",
        "SHELL=/etc/profiles/per-user/rko/bin/fish",
        "USER=rko",
        // Disable greeting for cleaner test output
        "fish_greeting=",
    };

    const pid = try pty.spawn(&.{ fish_path, "-i" }, &env);
    log.info("Spawned shell (pid={d})", .{pid});

    // Transfer ownership to pane
    pane.pty = pty;
    pane.child_pid = pid;

    // Wait for shell to initialize and show prompt
    log.info("Waiting for shell prompt...", .{});
    try waitForOutput(allocator, &pane, 2000);

    // Check if shell is still alive
    log.info("Shell alive: {any}", .{pane.isAlive()});

    // Take initial snapshot
    const initial_snapshot = try snapshot.generateBinarySnapshot(allocator, &pane);
    defer allocator.free(initial_snapshot);
    log.info("Initial snapshot: {d} bytes, gen={d}", .{ initial_snapshot.len, pane.generation });

    // Clear dirty rows for accurate delta tracking
    pane.clearDirtyRows();

    // Now test up arrow 10 times
    var mismatches: usize = 0;
    for (0..10) |i| {
        log.info("\n=== Iteration {d} ===", .{i + 1});

        // Check if shell is still alive
        if (!pane.isAlive()) {
            log.err("Shell died before iteration {d}!", .{i + 1});
            break;
        }

        // Send up arrow
        try pane.writeInput(UP_ARROW);
        log.info("Sent UP arrow", .{});

        // Wait for shell response
        try waitForOutput(allocator, &pane, 500);

        // Get the current state
        const gen_before = pane.generation;
        const dirty_count = pane.getDirtyRowCount();
        log.info("After up: gen={d}, dirty_rows={d}", .{ gen_before, dirty_count });

        // Generate both snapshot and delta
        const full_snapshot = try snapshot.generateBinarySnapshot(allocator, &pane);
        defer allocator.free(full_snapshot);

        const delta_data = try snapshot.generateDelta(allocator, &pane, false);
        defer allocator.free(delta_data);

        log.info("Full snapshot: {d} bytes", .{full_snapshot.len});
        log.info("Delta: {d} bytes", .{delta_data.len});

        // Decode and compare
        const mismatch = try compareSnapshotAndDelta(allocator, full_snapshot, delta_data, &pane);
        if (mismatch) {
            mismatches += 1;
            log.err("MISMATCH detected in iteration {d}!", .{i + 1});
        } else {
            log.info("OK - snapshot and delta match", .{});
        }

        // Clear dirty rows for next iteration
        pane.clearDirtyRows();

        // Small delay between iterations
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    log.info("\n=== Summary ===", .{});
    log.info("Total iterations: 10", .{});
    log.info("Mismatches: {d}", .{mismatches});

    if (mismatches > 0) {
        log.err("TEST FAILED: {d} mismatches detected", .{mismatches});
        std.process.exit(1);
    } else {
        log.info("TEST PASSED: All iterations matched", .{});
    }
}

/// Wait for PTY output and feed it to the pane
fn waitForOutput(allocator: std.mem.Allocator, pane: *Pane, timeout_ms: u32) !void {
    _ = allocator;
    var buf: [4096]u8 = undefined;
    var total_read: usize = 0;

    const pty_fd = pane.getPtyFd() orelse return error.NoPty;

    const start = std.time.milliTimestamp();
    const deadline = start + timeout_ms;

    // Poll for data
    var poll_fds = [_]posix.pollfd{
        .{ .fd = pty_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    while (std.time.milliTimestamp() < deadline) {
        const remaining = @as(i32, @intCast(@max(0, deadline - std.time.milliTimestamp())));
        const ready = posix.poll(&poll_fds, remaining) catch break;

        if (ready == 0) break; // Timeout

        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(pty_fd, &buf) catch break;
            if (n == 0) break;

            total_read += n;

            // Feed to pane
            try pane.feed(buf[0..n]);

            // Log what we received
            log.debug("Read {d} bytes from PTY", .{n});
        }
    }

    log.info("Total read: {d} bytes", .{total_read});
}

/// Compare snapshot cells with delta-reconstructed cells
fn compareSnapshotAndDelta(allocator: std.mem.Allocator, snapshot_data: []const u8, delta_data: []const u8, pane: *Pane) !bool {
    // Decode snapshot
    const decoded_snapshot = try decodeSnapshot(allocator, snapshot_data);
    defer allocator.free(decoded_snapshot.cells);

    // Decode delta
    const decoded_delta = try decodeDelta(allocator, delta_data);
    defer {
        for (decoded_delta.dirty_rows) |row| {
            allocator.free(row.cells);
        }
        allocator.free(decoded_delta.dirty_rows);
        allocator.free(decoded_delta.row_ids);
    }

    const cols = pane.cols;
    const rows = pane.rows;

    // Build expected cells from delta (apply to empty state)
    // First, create row cache from delta dirty rows
    var row_cache = std.AutoHashMap(u64, []const u8).init(allocator);
    defer row_cache.deinit();

    for (decoded_delta.dirty_rows) |row| {
        try row_cache.put(row.id, row.cells);
    }

    // Check each row
    var has_mismatch = false;
    for (0..rows) |y| {
        const snapshot_row_start = y * cols * 8;
        const snapshot_row_end = snapshot_row_start + cols * 8;
        const snapshot_row = decoded_snapshot.cells[snapshot_row_start..snapshot_row_end];

        // Get row ID for this position
        const row_id = if (y < decoded_delta.row_ids.len) decoded_delta.row_ids[y] else 0;

        // Check if this row is in delta
        if (row_cache.get(row_id)) |delta_row| {
            // Compare byte by byte
            if (!std.mem.eql(u8, snapshot_row, delta_row)) {
                log.err("Row {d} (id={d}) MISMATCH:", .{ y, row_id });
                log.err("  Snapshot row len: {d}", .{snapshot_row.len});
                log.err("  Delta row len: {d}", .{delta_row.len});

                // Find first difference
                var diff_pos: usize = 0;
                for (0..@min(snapshot_row.len, delta_row.len)) |i| {
                    if (snapshot_row[i] != delta_row[i]) {
                        diff_pos = i;
                        break;
                    }
                }
                log.err("  First diff at byte {d}", .{diff_pos});

                // Show cells around the difference
                const cell_idx = diff_pos / 8;
                log.err("  Cell index: {d}", .{cell_idx});

                // Decode the differing cells
                if (cell_idx * 8 + 8 <= snapshot_row.len) {
                    const snap_cell = snapshot_row[cell_idx * 8 .. cell_idx * 8 + 8];
                    const snap_cp = decodeCodepoint(snap_cell);
                    log.err("  Snapshot cell: codepoint={d} ('{c}')", .{ snap_cp, if (snap_cp >= 32 and snap_cp < 127) @as(u8, @intCast(snap_cp)) else '?' });
                }
                if (cell_idx * 8 + 8 <= delta_row.len) {
                    const delta_cell = delta_row[cell_idx * 8 .. cell_idx * 8 + 8];
                    const delta_cp = decodeCodepoint(delta_cell);
                    log.err("  Delta cell: codepoint={d} ('{c}')", .{ delta_cp, if (delta_cp >= 32 and delta_cp < 127) @as(u8, @intCast(delta_cp)) else '?' });
                }

                has_mismatch = true;
            }
        } else {
            // Row not in delta - this is fine if it's unchanged
            // But we should check if the row was supposed to be dirty
            log.debug("Row {d} (id={d}) not in delta", .{ y, row_id });
        }
    }

    return has_mismatch;
}

const DecodedSnapshot = struct {
    cells: []u8,
    cols: u16,
    rows: u16,
};

const DecodedDelta = struct {
    dirty_rows: []DirtyRow,
    row_ids: []u64,
};

const DirtyRow = struct {
    id: u64,
    cells: []u8,
};

fn decodeSnapshot(allocator: std.mem.Allocator, data: []const u8) !DecodedSnapshot {
    // Skip compression byte and decompress
    const is_compressed = data[0] == 1;
    const payload = data[1..];

    var decompressed: []u8 = undefined;
    if (is_compressed) {
        // Use snappy decompression
        decompressed = try decompressSnappy(allocator, payload);
    } else {
        decompressed = try allocator.dupe(u8, payload);
    }
    defer allocator.free(decompressed);

    // Decode msgpack
    // This is simplified - just extract cells bytes
    // In real implementation, would use proper msgpack decoder

    // Find "cells" field in msgpack map
    const cells = try extractBinaryField(allocator, decompressed, "cells");
    const cols: u16 = 80; // TODO: extract from msgpack
    const rows: u16 = 24;

    return .{
        .cells = cells,
        .cols = cols,
        .rows = rows,
    };
}

fn decodeDelta(allocator: std.mem.Allocator, data: []const u8) !DecodedDelta {
    // Skip compression byte and decompress
    const is_compressed = data[0] == 1;
    const payload = data[1..];

    var decompressed: []u8 = undefined;
    if (is_compressed) {
        decompressed = try decompressSnappy(allocator, payload);
    } else {
        decompressed = try allocator.dupe(u8, payload);
    }
    defer allocator.free(decompressed);

    // Extract dirtyRows array and rowIds
    var dirty_rows: std.ArrayListUnmanaged(DirtyRow) = .{};
    errdefer {
        for (dirty_rows.items) |row| allocator.free(row.cells);
        dirty_rows.deinit(allocator);
    }

    // Parse msgpack to find dirtyRows
    // This is a simplified parser - just looks for the array structure
    try extractDirtyRows(allocator, decompressed, &dirty_rows);

    // Extract rowIds
    const row_ids = try extractRowIds(allocator, decompressed);

    return .{
        .dirty_rows = try dirty_rows.toOwnedSlice(allocator),
        .row_ids = row_ids,
    };
}

fn decompressSnappy(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Snappy framing format:
    // - Varint uncompressed length
    // - Compressed data

    if (data.len < 1) return error.InvalidData;

    // Read varint length
    var length: u32 = 0;
    var shift: u5 = 0;
    var pos: usize = 0;
    while (pos < data.len) {
        const byte = data[pos];
        length |= @as(u32, @intCast(byte & 0x7F)) << shift;
        pos += 1;
        if (byte & 0x80 == 0) break;
        shift += 7;
    }

    const compressed = data[pos..];

    // Allocate output buffer
    var output = try allocator.alloc(u8, length);
    errdefer allocator.free(output);

    // Decompress
    var out_pos: usize = 0;
    var in_pos: usize = 0;

    while (in_pos < compressed.len and out_pos < length) {
        const tag = compressed[in_pos];
        in_pos += 1;

        const tag_type = tag & 0x03;

        if (tag_type == 0) {
            // Literal
            var lit_len: usize = @as(usize, tag >> 2) + 1;
            if (lit_len > 60) {
                const extra_bytes = lit_len - 60;
                lit_len = 1;
                for (0..extra_bytes) |i| {
                    lit_len += @as(usize, compressed[in_pos + i]) << @as(u5, @intCast(i * 8));
                }
                in_pos += extra_bytes;
            }
            @memcpy(output[out_pos .. out_pos + lit_len], compressed[in_pos .. in_pos + lit_len]);
            in_pos += lit_len;
            out_pos += lit_len;
        } else if (tag_type == 1) {
            // Copy with 1-byte offset
            const copy_len = @as(usize, (tag >> 2) & 0x07) + 4;
            const offset = @as(usize, (tag >> 5)) << 8 | @as(usize, compressed[in_pos]);
            in_pos += 1;
            for (0..copy_len) |i| {
                output[out_pos + i] = output[out_pos - offset + i];
            }
            out_pos += copy_len;
        } else if (tag_type == 2) {
            // Copy with 2-byte offset
            const copy_len = @as(usize, tag >> 2) + 1;
            const offset = @as(usize, compressed[in_pos]) | (@as(usize, compressed[in_pos + 1]) << 8);
            in_pos += 2;
            for (0..copy_len) |i| {
                output[out_pos + i] = output[out_pos - offset + i];
            }
            out_pos += copy_len;
        }
    }

    return output;
}

fn extractBinaryField(allocator: std.mem.Allocator, msgpack: []const u8, field: []const u8) ![]u8 {
    _ = field;
    // Simplified: scan for binary data (0xc4/0xc5/0xc6 prefix)
    // Look for the largest binary blob which should be cells
    var largest_start: usize = 0;
    var largest_len: usize = 0;

    var i: usize = 0;
    while (i < msgpack.len) {
        if (msgpack[i] == 0xc4 and i + 2 < msgpack.len) {
            // bin8
            const len = msgpack[i + 1];
            if (len > largest_len and i + 2 + len <= msgpack.len) {
                largest_start = i + 2;
                largest_len = len;
            }
            i += 2 + len;
        } else if (msgpack[i] == 0xc5 and i + 3 < msgpack.len) {
            // bin16
            const len = @as(usize, msgpack[i + 1]) << 8 | @as(usize, msgpack[i + 2]);
            if (len > largest_len and i + 3 + len <= msgpack.len) {
                largest_start = i + 3;
                largest_len = len;
            }
            i += 3 + len;
        } else if (msgpack[i] == 0xc6 and i + 5 < msgpack.len) {
            // bin32
            const len = @as(usize, msgpack[i + 1]) << 24 | @as(usize, msgpack[i + 2]) << 16 |
                @as(usize, msgpack[i + 3]) << 8 | @as(usize, msgpack[i + 4]);
            if (len > largest_len and i + 5 + len <= msgpack.len) {
                largest_start = i + 5;
                largest_len = len;
            }
            i += 5 + len;
        } else {
            i += 1;
        }
    }

    if (largest_len == 0) return error.FieldNotFound;

    return try allocator.dupe(u8, msgpack[largest_start .. largest_start + largest_len]);
}

fn extractDirtyRows(allocator: std.mem.Allocator, msgpack: []const u8, rows: *std.ArrayListUnmanaged(DirtyRow)) !void {
    // Look for "dirtyRows" key and parse the array
    // This is a simplified parser

    // Find array of maps (each with "id" and "cells")
    var i: usize = 0;
    while (i < msgpack.len) {
        // Look for fixarray or array16/32
        if (msgpack[i] >= 0x90 and msgpack[i] <= 0x9f) {
            // fixarray
            const arr_len = msgpack[i] & 0x0f;
            i += 1;

            // Try to parse as dirty rows
            for (0..arr_len) |_| {
                if (i >= msgpack.len) break;

                // Expect a map
                if (msgpack[i] >= 0x80 and msgpack[i] <= 0x8f) {
                    const map_len = msgpack[i] & 0x0f;
                    i += 1;

                    var row_id: u64 = 0;
                    var cells_data: ?[]const u8 = null;

                    for (0..map_len) |_| {
                        // Read key (should be fixstr)
                        if (i >= msgpack.len) break;
                        if (msgpack[i] >= 0xa0 and msgpack[i] <= 0xbf) {
                            const key_len = msgpack[i] & 0x1f;
                            i += 1;
                            if (i + key_len > msgpack.len) break;
                            const key = msgpack[i .. i + key_len];
                            i += key_len;

                            // Read value
                            if (std.mem.eql(u8, key, "id")) {
                                // Read uint
                                if (i < msgpack.len) {
                                    if (msgpack[i] <= 0x7f) {
                                        row_id = msgpack[i];
                                        i += 1;
                                    } else if (msgpack[i] == 0xcc) {
                                        row_id = msgpack[i + 1];
                                        i += 2;
                                    } else if (msgpack[i] == 0xcd) {
                                        row_id = @as(u64, msgpack[i + 1]) << 8 | msgpack[i + 2];
                                        i += 3;
                                    } else if (msgpack[i] == 0xce) {
                                        row_id = @as(u64, msgpack[i + 1]) << 24 | @as(u64, msgpack[i + 2]) << 16 |
                                            @as(u64, msgpack[i + 3]) << 8 | msgpack[i + 4];
                                        i += 5;
                                    } else if (msgpack[i] == 0xcf) {
                                        row_id = @as(u64, msgpack[i + 1]) << 56 | @as(u64, msgpack[i + 2]) << 48 |
                                            @as(u64, msgpack[i + 3]) << 40 | @as(u64, msgpack[i + 4]) << 32 |
                                            @as(u64, msgpack[i + 5]) << 24 | @as(u64, msgpack[i + 6]) << 16 |
                                            @as(u64, msgpack[i + 7]) << 8 | msgpack[i + 8];
                                        i += 9;
                                    }
                                }
                            } else if (std.mem.eql(u8, key, "cells")) {
                                // Read bin
                                if (i < msgpack.len) {
                                    if (msgpack[i] == 0xc4) {
                                        const len = msgpack[i + 1];
                                        cells_data = msgpack[i + 2 .. i + 2 + len];
                                        i += 2 + len;
                                    } else if (msgpack[i] == 0xc5) {
                                        const len = @as(usize, msgpack[i + 1]) << 8 | msgpack[i + 2];
                                        cells_data = msgpack[i + 3 .. i + 3 + len];
                                        i += 3 + len;
                                    } else if (msgpack[i] == 0xc6) {
                                        const len = @as(usize, msgpack[i + 1]) << 24 | @as(usize, msgpack[i + 2]) << 16 |
                                            @as(usize, msgpack[i + 3]) << 8 | msgpack[i + 4];
                                        cells_data = msgpack[i + 5 .. i + 5 + len];
                                        i += 5 + len;
                                    }
                                }
                            } else {
                                // Skip value
                                i = skipMsgpackValue(msgpack, i);
                            }
                        } else {
                            break;
                        }
                    }

                    if (cells_data) |cells| {
                        try rows.append(allocator, .{
                            .id = row_id,
                            .cells = try allocator.dupe(u8, cells),
                        });
                    }
                } else {
                    i = skipMsgpackValue(msgpack, i);
                }
            }
        } else {
            i += 1;
        }
    }
}

fn extractRowIds(allocator: std.mem.Allocator, msgpack: []const u8) ![]u64 {
    // Look for "rowIds" binary field (8 bytes per row ID, little-endian u64)
    // It should be 24 * 8 = 192 bytes for a 24-row terminal

    var i: usize = 0;
    while (i < msgpack.len) {
        // Look for fixstr "rowIds"
        if (i + 7 < msgpack.len and msgpack[i] == 0xa6) {
            if (std.mem.eql(u8, msgpack[i + 1 .. i + 7], "rowIds")) {
                i += 7;
                // Next should be bin
                if (i < msgpack.len) {
                    var bin_len: usize = 0;
                    var bin_start: usize = 0;
                    if (msgpack[i] == 0xc4) {
                        bin_len = msgpack[i + 1];
                        bin_start = i + 2;
                    } else if (msgpack[i] == 0xc5) {
                        bin_len = @as(usize, msgpack[i + 1]) << 8 | msgpack[i + 2];
                        bin_start = i + 3;
                    }

                    if (bin_len > 0 and bin_len % 8 == 0) {
                        const num_rows = bin_len / 8;
                        var row_ids = try allocator.alloc(u64, num_rows);
                        for (0..num_rows) |j| {
                            const offset = bin_start + j * 8;
                            row_ids[j] = @as(u64, msgpack[offset]) |
                                (@as(u64, msgpack[offset + 1]) << 8) |
                                (@as(u64, msgpack[offset + 2]) << 16) |
                                (@as(u64, msgpack[offset + 3]) << 24) |
                                (@as(u64, msgpack[offset + 4]) << 32) |
                                (@as(u64, msgpack[offset + 5]) << 40) |
                                (@as(u64, msgpack[offset + 6]) << 48) |
                                (@as(u64, msgpack[offset + 7]) << 56);
                        }
                        return row_ids;
                    }
                }
            }
        }
        i += 1;
    }

    return allocator.alloc(u64, 0);
}

fn skipMsgpackValue(data: []const u8, start: usize) usize {
    if (start >= data.len) return data.len;

    const byte = data[start];

    // Positive fixint
    if (byte <= 0x7f) return start + 1;
    // Fixmap
    if (byte >= 0x80 and byte <= 0x8f) {
        var pos = start + 1;
        const count = (byte & 0x0f) * 2;
        for (0..count) |_| {
            pos = skipMsgpackValue(data, pos);
        }
        return pos;
    }
    // Fixarray
    if (byte >= 0x90 and byte <= 0x9f) {
        var pos = start + 1;
        const count = byte & 0x0f;
        for (0..count) |_| {
            pos = skipMsgpackValue(data, pos);
        }
        return pos;
    }
    // Fixstr
    if (byte >= 0xa0 and byte <= 0xbf) {
        const len = byte & 0x1f;
        return start + 1 + len;
    }
    // nil, false, true
    if (byte >= 0xc0 and byte <= 0xc3) return start + 1;
    // bin8
    if (byte == 0xc4) return start + 2 + data[start + 1];
    // bin16
    if (byte == 0xc5) return start + 3 + (@as(usize, data[start + 1]) << 8 | data[start + 2]);
    // uint8
    if (byte == 0xcc) return start + 2;
    // uint16
    if (byte == 0xcd) return start + 3;
    // uint32
    if (byte == 0xce) return start + 5;
    // uint64
    if (byte == 0xcf) return start + 9;
    // str8
    if (byte == 0xd9) return start + 2 + data[start + 1];
    // Negative fixint
    if (byte >= 0xe0) return start + 1;

    return start + 1;
}

fn decodeCodepoint(cell_bytes: []const u8) u32 {
    if (cell_bytes.len < 4) return 0;
    const lo = @as(u32, cell_bytes[0]) |
        (@as(u32, cell_bytes[1]) << 8) |
        (@as(u32, cell_bytes[2]) << 16) |
        (@as(u32, cell_bytes[3]) << 24);
    // Content is in bits 2-25 (24 bits), tag in bits 0-1
    const content_bits = (lo >> 2) & 0xffffff;
    // For codepoint, it's the lower 21 bits
    return content_bits & 0x1fffff;
}
