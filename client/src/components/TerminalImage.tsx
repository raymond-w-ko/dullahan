import { h } from "preact";
import { useEffect, useState } from "preact/hooks";
import { debug } from "../debug";
import type { TerminalImagePlacement } from "../../../protocol/schema/messages";
import {
  cacheTerminalImageUrl,
  getCachedTerminalImageUrl,
} from "../terminal/imageCache";
import {
  terminalImageCropStyle,
  terminalImagePlacementStyle,
} from "../terminal/imageStyles";

interface TerminalImageProps {
  image: TerminalImagePlacement;
  authToken?: string;
}

export function TerminalImage({ image, authToken }: TerminalImageProps) {
  const cachedSrc = getCachedTerminalImageUrl(image.imageKey);
  const [state, setState] = useState<"loading" | "loaded" | "error">(
    cachedSrc ? "loaded" : "loading"
  );
  const [src, setSrc] = useState<string | null>(cachedSrc);

  useEffect(() => {
    let cancelled = false;
    const cached = getCachedTerminalImageUrl(image.imageKey);
    if (cached) {
      setSrc(cached);
      setState("loaded");
      return () => {
        cancelled = true;
      };
    }

    setState("loading");

    const headers: Record<string, string> = {};
    if (authToken) {
      headers.Authorization = `Bearer ${authToken}`;
    }

    fetch(image.url, { headers })
      .then((response) => {
        if (!response.ok) {
          throw new Error(`image fetch ${response.status}`);
        }
        const contentType = response.headers.get("content-type") ?? "";
        if (contentType.startsWith("image/")) {
          return response.blob();
        }
        throw new Error(`unsupported image content type ${contentType || "unknown"}`);
      })
      .then((blob) => {
        if (cancelled) return;
        const objectUrl = URL.createObjectURL(blob);
        cacheTerminalImageUrl(image.imageKey, objectUrl);
        setSrc(getCachedTerminalImageUrl(image.imageKey));
      })
      .catch((err) => {
        if (!cancelled) {
          debug.category("snapshot").warn("Terminal image fetch failed:", err);
          setState("error");
        }
      });

    return () => {
      cancelled = true;
    };
  }, [image.imageKey, image.url, authToken]);

  return (
    <div class={`terminal-image terminal-image--${state}`} style={terminalImagePlacementStyle(image)}>
      {src && (
        <img
          src={src}
          alt=""
          draggable={false}
          style={terminalImageCropStyle(image)}
          onLoad={() => setState("loaded")}
          onError={() => setState("error")}
        />
      )}
      {state === "loading" && <span class="terminal-image-spinner" />}
    </div>
  );
}
