# IME Support (CJK Input)

Implementation notes for Input Method Editor support (implemented in du-aud).

## Problem

Can't just capture `keydown` events and forward keycodes - IME intercepts keystrokes and builds up "composition" text before committing.

## Solution: Hidden Textarea

```tsx
<textarea
  ref={inputRef}
  class="terminal-input"
  onInput={handleInput}
  onCompositionStart={handleCompositionStart}
  onCompositionUpdate={handleCompositionUpdate}
  onCompositionEnd={handleCompositionEnd}
  onKeyDown={handleKeyDown}
/>
```

```css
.terminal-input {
  position: absolute;
  opacity: 0;
  width: 1px;
  height: 1px;
  /* NOT display:none - IME won't attach */
}
```

## Key Events

| Event | When | Action |
|-------|------|--------|
| `compositionstart` | IME begins | Stop forwarding keydown |
| `compositionupdate` | Candidate text changing | Optional: render inline at cursor |
| `compositionend` | User commits final text | Send to PTY |
| `input` | Text committed | Also fires with final text |

## Notes

- **textarea over input**: handles multiline paste better, some IMEs behave better
- **Must be "visible"**: `opacity: 0` works, `display: none` doesn't
- **Positioning**: some IMEs show popup relative to element, may need to move near terminal cursor
- **Mobile**: virtual keyboards also need this pattern
- **Clear after processing**: avoid stale content in textarea

## Reference

xterm.js uses this exact pattern - it's the standard approach.
