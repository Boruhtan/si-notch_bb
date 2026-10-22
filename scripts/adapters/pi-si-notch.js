// Pi extension. Load explicitly with: pi --extension /absolute/path/pi-si-notch.js
// Local task/result snippets only; never returns a decision or sends tool arguments/output.
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";

const MAX_QUEUE = 16;
const TIMEOUT_MS = 1200;
const RETRY_AFTER_MS = 5000;
const bundledHelper = join(dirname(dirname(dirname(fileURLToPath(import.meta.url)))), "Helpers/si-notchctl");
const defaultHelper = existsSync(bundledHelper)
  ? bundledHelper : join(homedir(), "Applications/si-notch.app/Contents/Helpers/si-notchctl");

export function displaySummary(value, limit = 600) {
  if (typeof value !== "string") return undefined;
  const text = value.slice(0, 16384)
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*/g, "[redacted]")
    .replace(/\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|AKIA[A-Z0-9]{16})\b/g, "[redacted]")
    .replace(/\b(bearer\s+)[A-Za-z0-9._~+/-]+=*/gi, "$1[redacted]")
    .replace(/\b((?:api[_-]?key|access[_-]?token|token|password|secret)\s*[:=]\s*)[^\s,;]+/gi, "$1[redacted]")
    .replace(/[\x00-\x08\x0e-\x1f\x7f]/g, "").replace(/\s+/g, " ").trim();
  if (!text) return undefined;
  return Array.from(text).length <= limit ? text : Array.from(text).slice(0, limit - 1).join("") + "…";
}

export function makeSender({ cli = process.env.SI_NOTCH_CLI || defaultHelper, spawnChild = spawn } = {}) {
  const queue = [];
  let running = false;
  let disabledUntil = 0;
  // Do not search PATH or use a shell. A missing helper simply drops observations.
  if (!isAbsolute(cli)) return () => {};
  function drain() {
    if (running || queue.length === 0) return;
    running = true;
    const item = queue.shift();
    let child;
    try {
      child = spawnChild(cli, ["emit", JSON.stringify(item.payload)], { stdio: "ignore", windowsHide: true });
    } catch {
      running = false;
      item.resolve(false);
      for (const queued of queue.splice(0)) queued.resolve(false);
      disabledUntil = Date.now() + RETRY_AFTER_MS;
      return;
    }
    let finished = false;
    const timer = setTimeout(() => { try { child.kill(); } catch {} finish(false); }, TIMEOUT_MS);
    function finish(ok) {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      running = false;
      item.resolve(ok);
      if (!ok) {
        for (const queued of queue.splice(0)) queued.resolve(false);
        disabledUntil = Date.now() + RETRY_AFTER_MS;
      }
      else drain();
    }
    child.once("error", () => finish(false));
    child.once("close", (code) => finish(code === 0));
  }
  return (payload) => {
    if (Date.now() < disabledUntil) return Promise.resolve(false);
    return new Promise((resolve) => {
      if (queue.length >= MAX_QUEUE) {
        if (payload.event !== "agent.completed" && payload.event !== "agent.failed" && payload.event !== "session.end") { resolve(false); return; }
        queue.shift().resolve(false);
      }
      queue.push({ payload, resolve });
      drain();
    });
  };
}

export function registerPiEvents(pi, send = makeSender()) {
  let sessionID;
  let cwd;
  let sequence = 0;
  let started = false;
  let settled = false;
  let outcome = "completed";
  let taskSummary;
  let latestResult;
  let metadata = {};

  function emit(kind, extra = {}) {
    if (!sessionID || sessionID.length > 256) return;
    return send({ event: kind, session_id: sessionID, provider: "pi", id: randomUUID(),
      sequence: ++sequence, timestamp: Date.now() / 1000, cwd, ...metadata, ...extra });
  }
  function ensureSession(ctx) {
    const id = ctx?.sessionManager?.getSessionId?.();
    if (typeof id !== "string" || id.length === 0 || id.length > 256) return false;
    if (id !== sessionID) {
      sessionID = id;
      cwd = typeof ctx.cwd === "string" ? ctx.cwd.slice(0, 4096) : undefined;
      sequence = 0;
      started = false;
      settled = false;
      outcome = "completed";
      taskSummary = undefined;
      latestResult = undefined;
    }
    const name = ctx?.model?.id;
    const effort = ctx?.thinkingLevel ?? pi.getThinkingLevel?.();
    metadata = {};
    if (typeof name === "string" && name.length > 0 && Buffer.byteLength(name) <= 256 && !/[\x00-\x1f\x7f]/.test(name)) metadata.model = name;
    if (["off", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].includes(effort)) metadata.reasoning_effort = effort;
    if (!started) { started = true; emit("session.start", { title: displaySummary(cwd && basename(cwd), 100) || "Pi" }); }
    return true;
  }

  pi.on("session_start", (_event, ctx) => { ensureSession(ctx); });
  pi.on("model_select", (_event, ctx) => { if (ensureSession(ctx)) emit("usage.update"); });
  pi.on("thinking_level_select", (_event, ctx) => { if (ensureSession(ctx)) emit("usage.update"); });
  pi.on("before_agent_start", (event, ctx) => {
    if (!ensureSession(ctx)) return;
    taskSummary = event.messageType === "user" ? displaySummary(event.prompt) : undefined;
    latestResult = undefined;
  });
  pi.on("agent_start", (_event, ctx) => {
    if (!ensureSession(ctx)) return;
    settled = false;
    outcome = "completed";
    emit("agent.working", taskSummary ? { title: displaySummary(taskSummary, 100), first_prompt: taskSummary, message: taskSummary } : {});
  });
  pi.on("message_end", (event, ctx) => {
    if (!ensureSession(ctx) || event.message?.role !== "assistant" || !Array.isArray(event.message.content)) return;
    latestResult = displaySummary(event.message.content.filter(block => block.type === "text" && typeof block.text === "string")
      .slice(0, 16).map(block => block.text.slice(0, 4096)).join(" "));
    if (latestResult && event.message.stopReason === "toolUse") emit("agent.working", { message: latestResult });
  });
  pi.on("tool_execution_start", (event, ctx) => {
    if (!ensureSession(ctx)) return;
    emit("tool.start", { tool_name: String(event.toolName || "tool").slice(0, 512) });
  });
  pi.on("tool_execution_end", (event, ctx) => {
    if (!ensureSession(ctx)) return;
    emit(event.isError ? "tool.failed" : "tool.finish", { tool_name: String(event.toolName || "tool").slice(0, 512) });
  });
  pi.on("ui_prompt_start", (_event, ctx) => {
    if (ensureSession(ctx)) emit("agent.waiting", { message: "Waiting for input", attention_request_id: randomUUID() });
  });
  pi.on("ui_prompt_end", (_event, ctx) => {
    if (ensureSession(ctx)) emit("agent.working");
  });
  pi.on("agent_before_settle", (event, ctx) => {
    if (ensureSession(ctx)) outcome = event.outcome || "completed";
  });
  pi.on("agent_settled", async (event, ctx) => {
    if (!ensureSession(ctx)) return;
    settled = true;
    await emit(event.aborted || outcome === "error" || outcome === "aborted" ? "agent.failed" : "agent.completed",
      event.aborted ? { message: "Interrupted" } : latestResult ? { message: latestResult } : {});
  });
  pi.on("session_shutdown", async (_event, ctx) => {
    if (ensureSession(ctx) && !settled) await emit("session.end");
  });
}

export default function siNotchPi(pi) { registerPiEvents(pi); }
