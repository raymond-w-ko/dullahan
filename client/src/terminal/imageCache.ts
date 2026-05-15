const MAX_TERMINAL_IMAGE_CACHE_ENTRIES = 256;

const objectUrlCache = new Map<string, string>();

export function getCachedTerminalImageUrl(imageKey: string): string | null {
  return objectUrlCache.get(imageKey) ?? null;
}

export function cacheTerminalImageUrl(imageKey: string, objectUrl: string): void {
  const existing = objectUrlCache.get(imageKey);
  if (existing) {
    URL.revokeObjectURL(objectUrl);
    return;
  }

  objectUrlCache.set(imageKey, objectUrl);
  while (objectUrlCache.size > MAX_TERMINAL_IMAGE_CACHE_ENTRIES) {
    const oldest = objectUrlCache.keys().next().value;
    if (oldest === undefined) return;
    const url = objectUrlCache.get(oldest);
    objectUrlCache.delete(oldest);
    if (url) URL.revokeObjectURL(url);
  }
}

export function clearTerminalImageCache(): void {
  for (const url of objectUrlCache.values()) {
    URL.revokeObjectURL(url);
  }
  objectUrlCache.clear();
}
