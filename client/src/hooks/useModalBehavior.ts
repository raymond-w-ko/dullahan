// Shared modal behavior hook for escape key handling and body scroll prevention
// Eliminates duplication across modal components

import { useEffect, useRef, useCallback } from "preact/hooks";

export interface UseModalBehaviorOptions {
  /** Whether the modal is currently open */
  isOpen: boolean;
  /** Callback to close the modal */
  onClose: () => void;
  /** Close modal when Escape key is pressed (default: true) */
  closeOnEscape?: boolean;
  /** Close modal when clicking outside (default: false) */
  closeOnOutsideClick?: boolean;
  /** Prevent body scroll when modal is open (default: true) */
  preventScroll?: boolean;
}

/**
 * Hook for common modal behaviors.
 *
 * Provides:
 * - Escape key to close modal
 * - Body scroll prevention when open
 * - Optional click-outside-to-close with returned ref
 *
 * Usage:
 *   const { modalRef } = useModalBehavior({ isOpen, onClose });
 *   // If using closeOnOutsideClick, attach modalRef to the modal content div
 *   <div ref={modalRef} class="modal">...</div>
 */
export function useModalBehavior(options: UseModalBehaviorOptions) {
  const {
    isOpen,
    onClose,
    closeOnEscape = true,
    closeOnOutsideClick = false,
    preventScroll = true,
  } = options;

  const modalRef = useRef<HTMLDivElement>(null);

  // Memoize onClose to avoid recreating handlers
  const handleClose = useCallback(() => {
    onClose();
  }, [onClose]);

  // Escape key handler
  useEffect(() => {
    if (!closeOnEscape || !isOpen) return;

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        handleClose();
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [isOpen, handleClose, closeOnEscape]);

  // Body scroll prevention
  useEffect(() => {
    if (!preventScroll || !isOpen) return;

    const originalOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";

    return () => {
      document.body.style.overflow = originalOverflow;
    };
  }, [isOpen, preventScroll]);

  // Outside click handler
  useEffect(() => {
    if (!closeOnOutsideClick || !isOpen) return;

    const handleClick = (e: MouseEvent) => {
      if (modalRef.current && !modalRef.current.contains(e.target as Node)) {
        handleClose();
      }
    };

    // Use mousedown for immediate response
    document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, [isOpen, handleClose, closeOnOutsideClick]);

  return { modalRef };
}
