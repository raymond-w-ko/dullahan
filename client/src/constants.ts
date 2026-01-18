// Global constants for the dullahan client
//
// Centralizes magic numbers for easier maintenance.
// All values are compile-time constants.

/** Scroll behavior constants */
export const SCROLL = {
  /** Number of rows to scroll per mouse wheel tick */
  ROWS_PER_TICK: 3,
} as const;

/** Audio/bell constants */
export const AUDIO = {
  /** Bell tone frequency in Hz (A5 note) */
  BELL_FREQUENCY: 880,
  /** Attack time for bell envelope in seconds */
  ATTACK_TIME: 0.01,
  /** Time to reach full volume after attack */
  DECAY_TIME: 0.15,
  /** Peak gain level (0-1) */
  PEAK_GAIN: 0.3,
  /** Minimum gain before stopping oscillator */
  MIN_GAIN: 0.001,
} as const;

/** Toast notification constants */
export const TOAST = {
  /** Maximum number of visible toasts */
  MAX_VISIBLE: 5,
  /** Auto-dismiss delay in milliseconds */
  AUTO_DISMISS_MS: 5000,
} as const;
