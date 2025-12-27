import * as esbuild from "esbuild";

const watch = process.argv.includes("--watch");

const config: esbuild.BuildOptions = {
  entryPoints: ["src/main.ts"],
  bundle: true,
  outdir: "dist",
  format: "esm",
  platform: "browser",
  target: "es2022",
  sourcemap: true,
  minify: !watch,
  jsxFactory: "h",
  jsxFragment: "Fragment",
  jsxImportSource: "preact",
  jsx: "automatic",
};

if (watch) {
  const ctx = await esbuild.context(config);
  await ctx.watch();
  console.log("Watching for changes...");
} else {
  await esbuild.build(config);
  console.log("Build complete");
}
