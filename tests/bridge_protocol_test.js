#!/usr/bin/env node
"use strict";

/**
 * Hermetic JSONL protocol test for `lua/mermaid_lens/renderer/bridge.js`.
 * Exercises ping, malformed JSON resilience, unknown actions, raster_viewbox
 * queue coalescing, and clean shutdown without launching Chromium.
 */

const assert = require("assert");
const path = require("path");
const { spawn } = require("child_process");

const bridgeScript = path.resolve(
  __dirname,
  "..",
  "lua",
  "mermaid_lens",
  "renderer",
  "bridge.js",
);

async function run() {
  // Pass a nonexistent mmdc path so browser launch fails fast if ever invoked
  const child = spawn(
    process.execPath,
    [bridgeScript, "/nonexistent/mermaid-lens-test-mmdc"],
    { stdio: ["pipe", "pipe", "pipe"] },
  );

  const frames = [];
  const waiters = [];
  let buf = "";

  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    buf += chunk;
    while (true) {
      const nl = buf.indexOf("\n");
      if (nl === -1) break;
      const line = buf.slice(0, nl).replace(/\r$/, "");
      buf = buf.slice(nl + 1);
      if (line.startsWith("MLENS:")) {
        const parsed = JSON.parse(line.slice("MLENS:".length));
        frames.push(parsed);
        for (let i = waiters.length - 1; i >= 0; i--) {
          if (waiters[i].predicate(parsed)) {
            const w = waiters.splice(i, 1)[0];
            clearTimeout(w.timer);
            w.resolve(parsed);
          }
        }
      }
    }
  });

  function waitForFrame(predicate, label, timeoutMs = 3000) {
    const existing = frames.find(predicate);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error(`Timed out waiting for bridge frame: ${label}`));
      }, timeoutMs);
      waiters.push({ predicate, resolve, timer });
    });
  }

  const exitPromise = new Promise((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });

  try {
    // 1. Ping/pong health handshake
    child.stdin.write(JSON.stringify({ id: 1, action: "ping" }) + "\n");
    const pong = await waitForFrame((f) => f.id === 1, "ping");
    assert.strictEqual(pong.status, "ok");
    assert.strictEqual(pong.pong, true);

    // 2. Invalid JSON returns structured bridge_fatal without crashing worker
    child.stdin.write("{broken-json\n");
    const invalid = await waitForFrame((f) => f.id === 0, "invalid JSON");
    assert.strictEqual(invalid.status, "error");
    assert.strictEqual(invalid.error_type, "bridge_fatal");
    assert.strictEqual(invalid.error, "Invalid JSON request");

    // Verify worker remains alive after invalid JSON
    child.stdin.write(JSON.stringify({ id: 2, action: "ping" }) + "\n");
    const pong2 = await waitForFrame((f) => f.id === 2, "post-error ping");
    assert.strictEqual(pong2.status, "ok");

    // 3. Unknown action returns structured error
    child.stdin.write(JSON.stringify({ id: 3, action: "unknown_op" }) + "\n");
    const unknown = await waitForFrame((f) => f.id === 3, "unknown action");
    assert.strictEqual(unknown.status, "error");
    assert.strictEqual(unknown.error_type, "bridge_fatal");
    assert.ok(unknown.error.includes("Unknown action: unknown_op"));

    // 4. Coalescing: 3 rapid raster_viewbox requests in one chunk cancel the superseded middle frame (id: 11)
    child.stdin.write(
      [
        JSON.stringify({ id: 10, action: "raster_viewbox" }),
        JSON.stringify({ id: 11, action: "raster_viewbox" }),
        JSON.stringify({ id: 12, action: "raster_viewbox" }),
      ].join("\n") + "\n",
    );
    const cancelled = await waitForFrame((f) => f.id === 11, "coalesced cancel");
    assert.strictEqual(cancelled.status, "cancelled");
    const r10 = await waitForFrame((f) => f.id === 10, "raster 10");
    const r12 = await waitForFrame((f) => f.id === 12, "raster 12");
    assert.strictEqual(r10.status, "error");
    assert.strictEqual(r12.status, "error");

    // 5. Clean shutdown exits 0 promptly
    child.stdin.write(JSON.stringify({ id: 99, action: "shutdown" }) + "\n");
    const exitInfo = await Promise.race([
      exitPromise,
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error("Timed out waiting for bridge shutdown")), 3000),
      ),
    ]);
    assert.strictEqual(exitInfo.code, 0, `Expected exit code 0, got ${JSON.stringify(exitInfo)}`);

    console.log("Bridge protocol tests: 5 passed, 0 failed");
  } finally {
    if (child.exitCode === null && !child.killed) {
      child.kill("SIGKILL");
    }
  }
}

run().catch((err) => {
  console.error("Bridge protocol test failed:", err);
  process.exit(1);
});
