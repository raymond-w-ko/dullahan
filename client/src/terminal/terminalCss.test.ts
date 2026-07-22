import { describe, expect, it } from "bun:test";

function cssRuleBody(css: string, selector: string): string {
  const start = css.indexOf(`${selector} {`);
  if (start === -1) return "";
  const bodyStart = css.indexOf("{", start);
  const bodyEnd = css.indexOf("}", bodyStart);
  return css.slice(bodyStart + 1, bodyEnd);
}

describe("terminal CSS", () => {
  it("keeps the shared terminal-line class out of layout positioning", async () => {
    const css = await Bun.file(new URL("../dullahan.css", import.meta.url)).text();
    const sharedLineRule = cssRuleBody(css, ".terminal-line");
    const rowLineRule = cssRuleBody(css, ".terminal > .terminal-line");

    expect(sharedLineRule).not.toContain("position:");
    expect(sharedLineRule).not.toContain("z-index:");
    expect(rowLineRule).toContain("position: relative");
    expect(rowLineRule).toContain("z-index: 2");
  });

  it("places image layers around terminal text", async () => {
    const css = await Bun.file(new URL("../dullahan.css", import.meta.url)).text();
    const backgroundRule = cssRuleBody(css, ".terminal-image-layer--background");
    const foregroundRule = cssRuleBody(css, ".terminal-image-layer--foreground");

    expect(backgroundRule).toContain("z-index: 1");
    expect(foregroundRule).toContain("z-index: 3");
  });

  it("constrains fixed glyphs without overriding their fallback font", async () => {
    const css = await Bun.file(new URL("../dullahan.css", import.meta.url)).text();
    const fixedRule = cssRuleBody(css, ".fixed-cell");
    const wideRule = cssRuleBody(css, ".fixed-cell-wide");

    expect(fixedRule).toContain("display: inline-block");
    expect(fixedRule).toContain("vertical-align: top");
    expect(fixedRule).toContain("overflow: hidden");
    expect(fixedRule).toContain("width: var(--cell-width, 1ch)");
    expect(fixedRule).not.toContain("font-family");
    expect(wideRule).toContain("calc(2 * var(--cell-width, 1ch))");
    expect(css).not.toContain("--term-symbol-font");
  });
});
