//! Global constants for the dullahan server.
//!
//! Centralizes magic numbers and buffer sizes for easier maintenance
//! and configuration. All constants are compile-time known.

/// Buffer sizes for various I/O operations.
/// These are sized to handle typical terminal data without excessive allocation.
pub const buffer = struct {
    /// General-purpose buffer for PTY reads, IPC, msgpack encoding, etc.
    /// 4KB is a good balance between memory usage and avoiding fragmentation.
    pub const general: usize = 4096;

    /// Smaller buffer for paths, error messages, and other short strings.
    /// 256 bytes is enough for most Unix paths (PATH_MAX is typically 4096,
    /// but practical paths are much shorter).
    pub const path: usize = 256;

    /// Shell path buffer (null-terminated for execve).
    pub const shell_path: usize = 256;
};

/// Terminal dimension limits.
/// These prevent resource exhaustion from malicious resize requests.
pub const limits = struct {
    /// Maximum terminal columns. 500 columns handles ultra-wide monitors
    /// while preventing excessive memory allocation.
    pub const max_cols: u16 = 500;

    /// Maximum terminal rows. 500 rows handles tall monitors.
    pub const max_rows: u16 = 500;

    /// Minimum terminal dimensions.
    pub const min_cols: u16 = 1;
    pub const min_rows: u16 = 1;
};

/// Snapshot and delta sync constants.
pub const snapshot = struct {
    /// Minimum payload size (bytes) before applying Snappy compression.
    /// Below this threshold, compression overhead isn't worth it.
    /// Typical terminal snapshots are 10-50KB, deltas are 100B-5KB.
    pub const compression_threshold: usize = 256;

    /// Row ID page size for stable row identification across scrollback.
    /// row_id = (page_serial * PAGE_SIZE) + row_index
    /// 1000 allows up to 1000 rows per page while keeping IDs readable.
    pub const page_size: u64 = 1000;

    /// Maximum snapshot buffer size for large terminals (500x500).
    /// 4MB should be sufficient for the largest supported terminal.
    pub const max_buffer_size: usize = 4 * 1024 * 1024;
};

/// Default pixel dimensions per cell when no renderer metrics are available.
/// These are used to populate terminal width_px/height_px for size reports.
pub const terminal = struct {
    pub const default_cell_width_px: u16 = 8;
    pub const default_cell_height_px: u16 = 16;
};

/// Timeout values in milliseconds.
pub const timeout = struct {
    /// Default timeout for CLI commands.
    pub const cli_default_ms: u32 = 5000;

    /// HTTP connection read timeout.
    pub const http_read_ms: u32 = 500;

    /// Grace period for process termination before SIGKILL.
    pub const sigterm_grace_ms: u32 = 500;

    /// Maximum wait time after SIGKILL.
    pub const sigkill_wait_ms: u32 = 1000;

    /// Test shell output wait time.
    pub const test_shell_wait_ms: u32 = 500;
};

/// Process management constants.
pub const process = struct {
    /// Poll interval when waiting for process exit.
    pub const poll_interval_ms: u32 = 50;

    /// Poll interval after SIGKILL.
    pub const sigkill_poll_interval_ms: u32 = 100;
};

/// Default terminal colors for OSC 10/11 queries.
/// Values match dullahan.css base theme (One Dark style).
pub const colors = struct {
    /// Foreground: #abb2bf
    pub const fg_r: u8 = 0xab;
    pub const fg_g: u8 = 0xb2;
    pub const fg_b: u8 = 0xbf;

    /// Background: #282c34
    pub const bg_r: u8 = 0x28;
    pub const bg_g: u8 = 0x2c;
    pub const bg_b: u8 = 0x34;
};
