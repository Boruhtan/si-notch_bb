import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { registerPiEvents, displaySummary, makeSender as makePiSender } from "../../scripts/adapters/pi-si-notch.js";
import OpenCodeV2Plugin, { SINotchPlugin } from "../../scripts/adapters/opencode-si-notch.js";

test("OpenCode observer resolves system, user and custom app installs without running a harness", (t) => {
  const root = mkdtempSync(join(tmpdir(), "si-notch-adapter-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const options = { environment: {}, home: join(root, "home"), systemApplications: join(root, "Applications"),
    pluginURL: pathToFileURL(join(root, "plugins/si-notch.js")).href };
  const helper = (base) => {
    const path = join(base, "si-notch.app/Contents/Helpers/si-notchctl");
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, "fixture; never executed");
    chmodSync(path, 0o700);
    return path;
  };
  assert.equal(SINotchPlugin.resolveHelperForTest(options), undefined);
  const user = helper(join(options.home, "Applications"));
  assert.equal(SINotchPlugin.resolveHelperForTest(options), user);
  const system = helper(options.systemApplications);
  assert.equal(SINotchPlugin.resolveHelperForTest(options), system);
  assert.equal(SINotchPlugin.resolveHelperForTest({ ...options, environment: { SI_NOTCH_CLI: "relative" } }), undefined);
  const custom = helper(join(root, "custom app location"));
  mkdirSync(join(root, "plugins"), { recursive: true });
  writeFileSync(join(root, "plugins/si-notch.json"), JSON.stringify({ helperPath: custom }));
  assert.equal(SINotchPlugin.resolveHelperForTest(options), custom);
  chmodSync(custom, 0o600);
  assert.equal(SINotchPlugin.resolveHelperForTest(options), undefined);
});

test("Pi extension maps real lifecycle boundaries without content", () => {
  const handlers = new Map();
  const pi = { on(name, fn) { handlers.set(name, fn); } };
  const events = [];
  registerPiEvents(pi, (event) => events.push(event));
  const ctx = { cwd: "/tmp/project", sessionManager: { getSessionId: () => "pi-real-session" } };
  const fire = (name, payload = {}) => handlers.get(name)(payload, ctx);
  fire("session_start", { reason: "startup" });
  fire("agent_start");
  fire("tool_execution_start", { toolName: "bash", toolCallId: "tool-1", args: { command: "SECRET" } });
  fire("tool_execution_end", { toolName: "bash", toolCallId: "tool-1", isError: true, result: "SECRET" });
  fire("ui_prompt_start", { kind: "confirm", title: "SECRET" });
  fire("ui_prompt_end", { kind: "confirm" });
  fire("agent_before_settle", { outcome: "completed" });
  fire("agent_settled", { aborted: false });
  fire("session_shutdown");
  assert.deepEqual(events.map((e) => e.event), ["session.start", "agent.working", "tool.start", "tool.failed", "agent.waiting", "agent.working", "agent.completed"]);
  assert.ok(events.every((e) => e.provider === "pi" && e.session_id === "pi-real-session"));
  assert.deepEqual(events.map((e) => e.sequence), [1, 2, 3, 4, 5, 6, 7]);
  assert.ok(!JSON.stringify(events).includes("SECRET"));
  fire("agent_start");
  fire("agent_before_settle", { outcome: "error" });
  fire("agent_settled", { aborted: false });
  assert.equal(events.at(-1).event, "agent.failed");
});

test("sender fails open when helper is unavailable or path is relative", async () => {
  assert.doesNotThrow(() => makePiSender({ cli: "relative-helper" })({ event: "session.start" }));
  assert.doesNotThrow(() => makePiSender({ cli: "/no/such/si-notchctl" })({ event: "session.start" }));
  await new Promise((resolve) => setTimeout(resolve, 40));
});

test("sender pauses after helper failure and keeps the agent hook nonblocking", () => {
  const child = new EventEmitter();
  child.kill = () => {};
  let launches = 0;
  const send = makePiSender({ cli: "/tmp/mock-si-notchctl", spawnChild: () => { launches++; return child; } });
  send({ event: "session.start" });
  send({ event: "agent.working" });
  assert.equal(launches, 1);
  child.emit("close", 2);
  send({ event: "agent.completed" });
  assert.equal(launches, 1);
});

test("OpenCode plugin observes session, permission, tools and final state without content", () => {
    const events = [];
    const hooks = SINotchPlugin.createHooksForTest({ directory: "/tmp/project" }, (payload) => events.push(payload));
    const event = (type, properties) => hooks.event({ event: { type, properties } });
    event("session.created", { info: { id: "oc-real-session", title: "SECRET" } });
    event("session.status", { sessionID: "oc-real-session", status: { type: "busy" } });
    event("permission.asked", { sessionID: "oc-real-session", id: "request-1", pattern: "SECRET" });
    event("permission.replied", { sessionID: "oc-real-session", requestID: "request-1" });
    hooks["tool.execute.before"]({ sessionID: "oc-real-session", tool: "bash", callID: "c1" }, { args: { command: "SECRET" } });
    hooks["tool.execute.after"]({ sessionID: "oc-real-session", tool: "bash", callID: "c1" }, { output: "SECRET" });
    event("message.part.updated", { part: { type: "tool", sessionID: "oc-real-session", callID: "c1", tool: "bash", state: { status: "completed", output: "SECRET" } } });
    event("message.part.updated", { part: { type: "tool", sessionID: "oc-real-session", callID: "c2", tool: "read", state: { status: "running", input: "SECRET" } } });
    event("message.part.updated", { part: { type: "tool", sessionID: "oc-real-session", callID: "c2", tool: "read", state: { status: "error", error: "SECRET" } } });
    event("session.status", { sessionID: "oc-real-session", status: { type: "idle" } });
    event("session.idle", { sessionID: "oc-real-session" });
    assert.deepEqual(events.map((e) => e.event), ["session.start", "agent.working", "approval.request", "agent.working", "tool.start", "tool.finish", "tool.start", "tool.failed", "agent.completed"]);
    assert.deepEqual(events.map((e) => e.sequence), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    assert.equal(events[2].approval_id, "request-1");
    assert.ok(!JSON.stringify(events).includes("SECRET"));
});

test("OpenCode V2 definition maps data-based session lifecycle", () => {
  assert.equal(OpenCodeV2Plugin.id, "si-notch");
  assert.equal(typeof OpenCodeV2Plugin.setup, "function");
  const events = [];
  const hooks = SINotchPlugin.createHooksForTest({ directory: "/tmp/project" }, (payload) => events.push(payload));
  const fire = (type, data) => hooks.event({ event: { type, data, location: { directory: "/tmp/project" } } });
  fire("session.created", { sessionID: "v2-session", title: "SECRET" });
  fire("session.status", { sessionID: "v2-session", status: "busy" });
  fire("session.status", { sessionID: "v2-session", status: "idle" });
  fire("session.deleted", { sessionID: "v2-session" });
  assert.deepEqual(events.map((e) => e.event), ["session.start", "agent.working", "agent.completed", "session.end"]);
  assert.deepEqual(events.map((e) => e.sequence), [1, 2, 3, 4]);
  assert.ok(!JSON.stringify(events).includes("SECRET"));
});


test("Pi displays bounded task and final text, never thinking or tool content", () => {
  const handlers = new Map(), events = [];
  registerPiEvents({ on(name, handler) { handlers.set(name, handler); } }, e => events.push(e));
  const ctx = { cwd: "/tmp/project", sessionManager: { getSessionId: () => "pi-summary" } };
  const fire = (name, payload = {}) => handlers.get(name)(payload, ctx);
  fire("session_start");
  fire("before_agent_start", { messageType: "user", prompt: "Fix the layout token=secret-value" });
  fire("agent_start");
  assert.equal(events.at(-1).title, "Fix the layout token=[redacted]");
  fire("message_end", { message: { role: "assistant", content: [
    { type: "thinking", thinking: "PRIVATE_THOUGHT" },
    { type: "toolCall", name: "bash", arguments: { command: "PRIVATE_COMMAND" } },
    { type: "text", text: "Layout fixed. Tests passed." }
  ] } });
  fire("agent_settled");
  assert.equal(events.at(-1).message, "Layout fixed. Tests passed.");
  assert.ok(!JSON.stringify(events).includes("PRIVATE_"));
  assert.ok(!JSON.stringify(events).includes("secret-value"));
  assert.equal(Array.from(displaySummary("я".repeat(900))).length, 600);
});
