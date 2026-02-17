// Hook to subscribe to store updates and trigger re-renders on changes
// Eliminates boilerplate from components that need reactive store updates

import { useState, useEffect, useRef, useCallback } from "preact/hooks";
import {
  subscribe,
  subscribePane,
  subscribeWindow,
  getStore,
  type Store,
} from "../store";

type EqualityFn<T> = (a: T, b: T) => boolean;
type SubscribeFn = (listener: () => void) => () => void;

function defaultEquality<T>(a: T, b: T): boolean {
  return Object.is(a, b);
}

/**
 * Shallow object equality helper for selector outputs.
 * Compares own enumerable keys with Object.is on values.
 */
export function shallowEqual<T extends Record<string, unknown>>(a: T, b: T): boolean {
  if (Object.is(a, b)) return true;
  const aKeys = Object.keys(a);
  const bKeys = Object.keys(b);
  if (aKeys.length !== bKeys.length) return false;
  for (const key of aKeys) {
    if (!Object.prototype.hasOwnProperty.call(b, key)) {
      return false;
    }
    if (!Object.is(a[key], b[key])) {
      return false;
    }
  }
  return true;
}

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

/**
 * Subscribe to selected store state and re-render only when selection changes.
 */
export function useStoreSelector<T>(
  selector: (store: Readonly<Store>) => T,
  isEqual: EqualityFn<T> = defaultEquality
): T {
  return useScopedStoreSelector(selector, isEqual, subscribe);
}

function useScopedStoreSelector<T>(
  selector: (store: Readonly<Store>) => T,
  isEqual: EqualityFn<T>,
  subscribeFn: SubscribeFn
): T {
  const [, forceUpdate] = useState(0);
  const selectorRef = useRef(selector);
  const equalityRef = useRef(isEqual);
  selectorRef.current = selector;
  equalityRef.current = isEqual;

  const selectedRef = useRef<T>(selector(getStore()));
  const selectedNow = selector(getStore());
  if (!equalityRef.current(selectedRef.current, selectedNow)) {
    selectedRef.current = selectedNow;
  }

  useEffect(() => {
    return subscribeFn(() => {
      const next = selectorRef.current(getStore());
      if (equalityRef.current(selectedRef.current, next)) {
        return;
      }
      selectedRef.current = next;
      forceUpdate((n) => n + 1);
    });
  }, [subscribeFn]);

  return selectedRef.current;
}

/**
 * Subscribe to selected store state scoped to a specific pane.
 * The selector still sees the full store, but update notifications are filtered.
 */
export function usePaneStoreSelector<T>(
  paneId: number,
  selector: (store: Readonly<Store>) => T,
  isEqual: EqualityFn<T> = defaultEquality
): T {
  const subscribeFn = useCallback(
    (listener: () => void) => subscribePane(paneId, listener),
    [paneId]
  );
  return useScopedStoreSelector(selector, isEqual, subscribeFn);
}

/**
 * Subscribe to selected store state scoped to a specific window.
 * The selector still sees the full store, but update notifications are filtered.
 */
export function useWindowStoreSelector<T>(
  windowId: number,
  selector: (store: Readonly<Store>) => T,
  isEqual: EqualityFn<T> = defaultEquality
): T {
  const subscribeFn = useCallback(
    (listener: () => void) => subscribeWindow(windowId, listener),
    [windowId]
  );
  return useScopedStoreSelector(selector, isEqual, subscribeFn);
}
