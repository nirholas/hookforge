#!/usr/bin/env node
/**
 * Serves `dist` the way Cloudflare Pages does: directory URLs resolve to `index.html`, unknown paths 404, and the
 * `_headers` content types are applied for the plain-text and JSON endpoints. Used for local review and by the
 * smoke test, so what is checked locally is what ships.
 */
import {createServer} from "node:http";
import {existsSync, readFileSync, statSync} from "node:fs";
import {extname, join, normalize} from "node:path";
import {dirname} from "node:path";
import {fileURLToPath} from "node:url";

const DIST = join(dirname(fileURLToPath(import.meta.url)), "dist");
const PORT = Number(process.env.PORT ?? 4173);

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
};

function resolve(urlPath) {
  const clean = normalize(decodeURIComponent(urlPath.split("?")[0])).replace(/^(\.\.[/\\])+/, "");
  const candidate = join(DIST, clean);
  if (existsSync(candidate) && statSync(candidate).isFile()) return candidate;
  const asDirectory = join(candidate, "index.html");
  if (existsSync(asDirectory)) return asDirectory;
  return null;
}

createServer((request, response) => {
  const file = resolve(request.url ?? "/");
  if (!file) {
    response.writeHead(404, {"Content-Type": "text/plain; charset=utf-8"});
    response.end("404");
    return;
  }
  response.writeHead(200, {"Content-Type": TYPES[extname(file)] ?? "application/octet-stream"});
  response.end(readFileSync(file));
}).listen(PORT, () => console.log(`serving dist on http://localhost:${PORT}`));
