#!/usr/bin/env bun
/**
 * Simple dev server for the client.
 * Serves static files from current directory.
 */

const port = Number(process.env.PORT) || 3000;

const server = Bun.serve({
  port,
  async fetch(req) {
    const url = new URL(req.url);
    let path = url.pathname;
    
    // Default to index.html
    if (path === "/") path = "/index.html";
    
    // Try to serve the file
    const file = Bun.file(`.${path}`);
    if (await file.exists()) {
      return new Response(file);
    }
    
    // SPA fallback: serve index.html for non-file routes
    if (!path.includes(".")) {
      return new Response(Bun.file("./index.html"));
    }
    
    return new Response("Not Found", { status: 404 });
  },
});

console.log(`Server running at http://localhost:${server.port}`);
