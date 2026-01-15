// Hook to subscribe to store updates and trigger re-renders on changes
// Eliminates boilerplate from components that need reactive store updates

import { useState, useEffect } from "preact/hooks";
import { subscribe } from "../store";

/**
 * Subscribe to store updates and trigger component re-renders on changes.
 *
 * Usage:
 * ```typescript
 * function MyComponent() {
 *   useStoreSubscription();
 *   const store = getStore();
 *   // Component re-renders when store changes
 * }
 * ```
 */
export function useStoreSubscription(): void {
  const [, forceUpdate] = useState(0);

  useEffect(() => {
    return subscribe(() => forceUpdate((n) => n + 1));
  }, []);
}
