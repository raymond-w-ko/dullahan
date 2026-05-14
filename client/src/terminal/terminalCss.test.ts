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
});
