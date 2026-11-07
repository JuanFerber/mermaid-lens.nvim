#!/usr/bin/env node
"use strict";

/**
 * @file lua/mermaid_lens/renderer/bridge.js
 * Zero-dependency persistent SVG-to-Bitmap bridge for mermaid-lens.nvim.
 * Reuses `puppeteer` and `mermaid` from the existing `@mermaid-js/mermaid-cli` (mmdc)
 * installation to keep a warm headless Chromium DOM and rasterize dynamic `viewBox` regions.
 */

const fs = require("fs");
const readline = require("readline");
const Module = require("module");

// Redirect all standard console output to stderr so stdout carries exclusively MLENS: JSONL frames
const writeStdout = process.stdout.write.bind(process.stdout);
console.log = (...args) => process.stderr.write(args.join(" ") + "\n");
console.info = console.log;
console.warn = console.log;

const IDLE_TIMEOUT_MS = 10 * 60 * 1000;
let idleTimer = null;

function resetIdleTimer() {
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => shutdownAndExit(0), IDLE_TIMEOUT_MS);
}

function sendResponse(payload) {
  writeStdout("MLENS:" + JSON.stringify(payload) + "\n");
}

function resolveMmdcEnvironment(mmdcBinPath) {
  if (!mmdcBinPath || !fs.existsSync(mmdcBinPath)) {
    throw new Error(`mmdc executable not found at: ${mmdcBinPath}`);
  }
  const realMmdcFile = fs.realpathSync(mmdcBinPath);
  const mmdcReq = Module.createRequire(realMmdcFile);
  const puppeteer = mmdcReq("puppeteer");

  let mermaidScriptPath;
  try {
    mermaidScriptPath = mmdcReq.resolve("mermaid/dist/mermaid.min.js");
  } catch (_) {
    mermaidScriptPath = mmdcReq.resolve("mermaid/dist/mermaid.js");
  }

  return { puppeteer, mermaidScriptPath };
}

let browser = null;
let page = null;
let env = null;
let currentRenderSeq = 0;

async function ensureBrowser(mmdcBinPath) {
  if (browser && page && !page.isClosed()) {
    return;
  }
  if (!env) {
    env = resolveMmdcEnvironment(mmdcBinPath);
  }

  browser = await env.puppeteer.launch({
    headless: true,
    args: [
      "--no-sandbox",
      "--disable-setuid-sandbox",
      "--disable-dev-shm-usage",
      "--disable-gpu",
      "--disable-extensions",
      "--no-first-run",
      "--no-zygote",
      "--hide-scrollbars",
    ],
  });

  page = await browser.newPage();

  const baseHtml = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    html, body, #container {
      width: 100vw;
      height: 100vh;
      overflow: hidden;
      background: transparent;
    }
    #container > svg {
      width: 100% !important;
      height: 100% !important;
      max-width: none !important;
      max-height: none !important;
      display: block;
    }
  </style>
</head>
<body>
  <div id="container"></div>
</body>
</html>`;

  await page.setContent(baseHtml, { waitUntil: "domcontentloaded" });
  await page.addScriptTag({ path: env.mermaidScriptPath });
}

/**
 * Compiles Mermaid source into the active DOM <svg> and stores its canonical vector viewBox.
 * Does NOT write to disk by itself, so cache hydration never overwrites existing overview PNGs.
 */
async function mountSvgInDom(msg) {
  const renderResult = await page.evaluate(
    async ({ code, mermaidConfig, bgColor, cacheKey, seq }) => {
      document.body.style.backgroundColor = bgColor;
      const container = document.getElementById("container");
      container.style.backgroundColor = bgColor;

      try {
        window.mermaid.initialize(mermaidConfig);
        const { svg } = await window.mermaid.render("mlens_svg_" + seq, code);
        container.innerHTML = svg;

        const svgEl = container.querySelector("svg");
        if (!svgEl) {
          return {
            ok: false,
            error: "Mermaid did not produce an <svg> element.",
          };
        }

        let vbX = 0,
          vbY = 0,
          vbW = 0,
          vbH = 0;
        const rawVb = svgEl.getAttribute("viewBox");
        if (rawVb) {
          const parts = rawVb
            .trim()
            .split(/[\s,]+/)
            .map(Number);
          if (parts.length === 4 && parts.every((n) => Number.isFinite(n))) {
            [vbX, vbY, vbW, vbH] = parts;
          }
        }

        if (vbW <= 0 || vbH <= 0) {
          const bbox = svgEl.getBBox();
          vbX = bbox.x || 0;
          vbY = bbox.y || 0;
          vbW = Math.max(1, bbox.width || 800);
          vbH = Math.max(1, bbox.height || 600);
        }

        const pad = 8;
        vbX -= pad;
        vbY -= pad;
        vbW += pad * 2;
        vbH += pad * 2;

        window.__MLENS_BASE_VB__ = {
          key: cacheKey || "",
          x: vbX,
          y: vbY,
          w: vbW,
          h: vbH,
        };

        svgEl.setAttribute("viewBox", `${vbX} ${vbY} ${vbW} ${vbH}`);
        svgEl.setAttribute("preserveAspectRatio", "xMidYMid meet");
        svgEl.removeAttribute("width");
        svgEl.removeAttribute("height");
        svgEl.style.width = "100%";
        svgEl.style.height = "100%";
        svgEl.style.maxWidth = "none";
        svgEl.style.maxHeight = "none";

        return {
          ok: true,
          svg_w: Math.ceil(vbW),
          svg_h: Math.ceil(vbH),
        };
      } catch (err) {
        return {
          ok: false,
          error:
            (err && (err.str || err.message || String(err))) ||
            "Mermaid syntax error",
        };
      }
    },
    {
      code: msg.code,
      mermaidConfig: msg.mermaid_config,
      bgColor: msg.bg || "#f8fafc",
      cacheKey: msg.cache_key || "",
      seq: ++currentRenderSeq,
    },
  );

  return renderResult;
}

async function handleCompileSvg(msg, mmdcBinPath) {
  const t0 = Date.now();
  await ensureBrowser(mmdcBinPath);

  const targetW = Math.max(
    64,
    Math.min(4096, Math.round(msg.raster_w || 1400)),
  );
  const targetH = Math.max(64, Math.min(4096, Math.round(msg.raster_h || 850)));

  await page.setViewport({
    width: targetW,
    height: targetH,
    deviceScaleFactor: 1,
  });

  const renderResult = await mountSvgInDom(msg);
  if (!renderResult.ok) {
    return {
      id: msg.id,
      status: "error",
      error_type: "syntax",
      error: renderResult.error,
    };
  }

  const maxOverviewDim = Math.max(targetW, targetH, 3200);
  const scale = Math.min(
    maxOverviewDim / renderResult.svg_w,
    maxOverviewDim / renderResult.svg_h,
  );
  const overviewW = Math.max(
    64,
    Math.min(4096, Math.round(renderResult.svg_w * scale)),
  );
  const overviewH = Math.max(
    64,
    Math.min(4096, Math.round(renderResult.svg_h * scale)),
  );

  await page.setViewport({
    width: overviewW,
    height: overviewH,
    deviceScaleFactor: 1,
  });

  const finalOutPath = (msg.out_path_template || msg.out_path || "")
    .replace("{W}", String(renderResult.svg_w))
    .replace("{H}", String(renderResult.svg_h));

  await page.screenshot({
    path: finalOutPath,
    type: "png",
    omitBackground: false,
  });

  return {
    id: msg.id,
    status: "ok",
    png_path: finalOutPath,
    svg_w: renderResult.svg_w,
    svg_h: renderResult.svg_h,
    raster_w: overviewW,
    raster_h: overviewH,
    render_time_ms: Date.now() - t0,
  };
}

async function handleRasterViewBox(msg, mmdcBinPath) {
  const t0 = Date.now();
  await ensureBrowser(mmdcBinPath);

  const rasterW = Math.max(
    16,
    Math.min(4096, Math.round(msg.raster_w || 1200)),
  );
  const rasterH = Math.max(16, Math.min(4096, Math.round(msg.raster_h || 800)));
  const crop = msg.crop || { x: 0, y: 0, w: rasterW, h: rasterH };

  // Check if the requested diagram is already mounted in the DOM; if not, hydrate in-memory without writing an overview file
  const isMounted = await page.evaluate((expectedKey) => {
    const base = window.__MLENS_BASE_VB__;
    const svgEl = document.querySelector("#container > svg");
    return Boolean(svgEl && base && (!expectedKey || base.key === expectedKey));
  }, msg.cache_key || "");

  if (!isMounted) {
    if (!msg.code || !msg.mermaid_config) {
      return {
        id: msg.id,
        status: "error",
        error_type: "bridge_fatal",
        error:
          "SVG not mounted and no source provided for in-memory hydration.",
      };
    }
    const hydrated = await mountSvgInDom(msg);
    if (!hydrated.ok) {
      return {
        id: msg.id,
        status: "error",
        error_type: "syntax",
        error: hydrated.error,
      };
    }
  }

  await page.setViewport({
    width: rasterW,
    height: rasterH,
    deviceScaleFactor: 1,
  });

  await page.evaluate((c) => {
    const svgEl = document.querySelector("#container > svg");
    const base = window.__MLENS_BASE_VB__;
    const vx = base.x + c.x;
    const vy = base.y + c.y;
    const vw = Math.max(1, c.w);
    const vh = Math.max(1, c.h);
    svgEl.setAttribute("viewBox", `${vx} ${vy} ${vw} ${vh}`);
    svgEl.setAttribute("preserveAspectRatio", "xMidYMid meet");
  }, crop);

  await page.screenshot({
    path: msg.out_path,
    type: "png",
    omitBackground: false,
  });

  return {
    id: msg.id,
    status: "ok",
    png_path: msg.out_path,
    raster_w: rasterW,
    raster_h: rasterH,
    crop: crop,
    render_time_ms: Date.now() - t0,
  };
}

async function shutdownAndExit(code) {
  clearTimeout(idleTimer);
  try {
    if (browser) {
      await browser.close();
      browser = null;
    }
  } catch (_) {}
  process.exit(code);
}

async function main() {
  const mmdcBinPath = process.argv[2] || "";
  resetIdleTimer();

  let queue = Promise.resolve();
  const rl = readline.createInterface({
    input: process.stdin,
    terminal: false,
  });

  rl.on("line", (line) => {
    resetIdleTimer();
    const trimmed = line.trim();
    if (!trimmed) return;

    let msg;
    try {
      msg = JSON.parse(trimmed);
    } catch (_) {
      sendResponse({
        id: 0,
        status: "error",
        error_type: "bridge_fatal",
        error: "Invalid JSON request",
      });
      return;
    }

    if (msg.action === "shutdown") {
      shutdownAndExit(0);
      return;
    }

    if (msg.action === "ping") {
      sendResponse({ id: msg.id, status: "ok", pong: true });
      return;
    }

    queue = queue
      .then(async () => {
        if (msg.action === "compile_svg") {
          sendResponse(await handleCompileSvg(msg, mmdcBinPath));
        } else if (msg.action === "raster_viewbox") {
          sendResponse(await handleRasterViewBox(msg, mmdcBinPath));
        } else {
          sendResponse({
            id: msg.id,
            status: "error",
            error_type: "bridge_fatal",
            error: `Unknown action: ${msg.action}`,
          });
        }
      })
      .catch((err) => {
        sendResponse({
          id: msg.id,
          status: "error",
          error_type: "bridge_fatal",
          error: (err && err.message) || String(err),
        });
      });
  });

  rl.on("close", () => shutdownAndExit(0));
}

process.on("SIGTERM", () => shutdownAndExit(0));
process.on("SIGINT", () => shutdownAndExit(0));

main().catch((err) => {
  process.stderr.write(`Fatal bridge error: ${err.message}\n`);
  shutdownAndExit(1);
});
