// Toast notification container component
// Displays toast notifications in the upper-right corner (macOS style)

import { h } from "preact";
import { useEffect } from "preact/hooks";
import { useStoreSubscription } from "../hooks/useStoreSubscription";
import { getStore, dismissToast, getVisibleToasts, type ToastNotification } from "../store";
import { TOAST } from "../constants";

interface ToastProps {
  toast: ToastNotification;
  onDismiss: () => void;
}

function Toast({ toast, onDismiss }: ToastProps) {
  // Auto-dismiss after timeout
  useEffect(() => {
    const timer = setTimeout(() => {
      onDismiss();
    }, TOAST.AUTO_DISMISS_MS);
    return () => clearTimeout(timer);
  }, [toast.id, onDismiss]);

  return (
    <div class={`toast toast--${toast.type}`}>
      <div class="toast-content">
        {toast.title && <div class="toast-title">{toast.title}</div>}
        <div class="toast-message">{toast.message}</div>
      </div>
      <button class="toast-close" onClick={onDismiss} aria-label="Dismiss">
        {"\u00d7"}
      </button>
    </div>
  );
}

export function ToastContainer() {
  useStoreSubscription();
  const visibleToasts = getVisibleToasts(TOAST.MAX_VISIBLE);

  if (visibleToasts.length === 0) {
    return null;
  }

  return (
    <div class="toast-container">
      {visibleToasts.map((toast) => (
        <Toast
          key={toast.id}
          toast={toast}
          onDismiss={() => dismissToast(toast.id)}
        />
      ))}
    </div>
  );
}
