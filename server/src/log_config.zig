//! Toggleable logging configuration for debug console output.
//!
//! These constants control which categories of server events are logged
//! to the debug pane and log files. Set to `true` to enable logging.

/// Log DSR (Device Status Report) queries and responses
pub const log_dsr: bool = true;

/// Log window creation events
pub const log_window_creation: bool = true;

/// Log pane creation events
pub const log_pane_creation: bool = true;

/// Log pane ID assignment to window ID
pub const log_pane_assignment: bool = true;

/// Log pane resize events
pub const log_pane_resize: bool = true;

/// Log client join and client ID events
pub const log_client_join: bool = true;
