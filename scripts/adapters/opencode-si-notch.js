// OpenCode local plugin. Supports user-level and project-level plugin directories.
// Observational only: no permission responses, prompt contents, or tool arguments.
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { accessSync, constants, lstatSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";

const MAX_QUEUE = 16;
const TIMEOUT_MS = 1200;
const RETRY_AFTER_MS = 5000;

function resolveHelper({ environment = process.env, home = homedir(), systemApplications = "/Applications", pluginURL = import.meta.url } = {}) {
  function executable(path) {
    if (typeof path !== "string" || !isAbsolute(path) || /[\x00-\x1f]/.test(path)) return;
    try {
      if (!statSync(path).isFile()) return;
      accessSync(path, constants.X_OK);
      return path;
    } catch {}
  }
  if (environment.SI_NOTCH_CLI !== undefined) return executable(environment.SI_NOTCH_CLI);
  const directory = dirname(fileURLToPath(pluginURL));
  try {
    const config = join(directory, "si-notch.json");
    const info = lstatSync(config);
    if (info.isFile() && info.size <= 8192) {
      const settings = JSON.parse(readFileSync(config, "utf8"));
      if (settings.helperPath !== undefined) return executable(settings.helperPath);
    }
  } catch {}
  return [join(dirname(dirname(directory)), "Helpers/si-notchctl"),
    join(systemApplications, "si-notch.app/Contents/Helpers/si-notchctl"),
    join(home, "Applications/si-notch.app/Contents/Helpers/si-notchctl")]
    .map(executable).find(Boolean);
}

function makeSender({ cli = resolveHelper(), spawnChild = spawn } = {}) {
  const queue = [];
  let running = false;
  let disabledUntil = 0;
  if (typeof cli !== "string" || !isAbsolute(cli)) return () => Promise.resolve(false);
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

function createOpenCodeHooks({ directory } = {}, send = makeSender()) {
  const sessions = new Map();
  const tools = new Map();
  const cwd = typeof directory === "string" ? directory.slice(0, 4096) : undefined;
  function session(id) {
    if (typeof id !== "string" || id.length === 0 || id.length > 256) return;
    let state = sessions.get(id);
    if (!state) {
      state = { sequence: 0, status: "idle", started: false };
      sessions.set(id, state);
      if (sessions.size > 256) sessions.delete(sessions.keys().next().value);
    }
    return state;
  }
  function emit(id, kind, extra = {}) {
    const state = session(id);
    if (!state) return;
    return send({ event: kind, session_id: id, provider: "opencode", id: randomUUID(),
      sequence: ++state.sequence, timestamp: Date.now() / 1000,
      title: "OpenCode", cwd, ...state.metadata, ...extra });
  }
  function ensure(id) {
    const state = session(id);
    if (state && !state.started) { state.started = true; emit(id, "session.start"); }
    return state;
  }
  function busy(id) {
    const state = ensure(id);
    if (state && state.status !== "working") {
      state.status = "working";
      emit(id, "agent.working");
    }
  }
  function complete(id) {
    const state = ensure(id);
    if (state && state.status !== "completed" && state.status !== "failed" && state.status !== "idle") {
      state.status = "completed";
      return emit(id, "agent.completed");
    }
  }
  function toolEvent(id, callID, tool, status) {
    if (!ensure(id)) return;
    const key = typeof callID === "string" && callID.length <= 256 ? `${id}\0${callID}` : undefined;
    if (key && tools.get(key) === status) return;
    if (key) {
      tools.set(key, status);
      if (tools.size > 2048) tools.delete(tools.keys().next().value);
    }
    const kind = status === "running" ? "tool.start" : status === "error" ? "tool.failed" : "tool.finish";
    if (status === "running") busy(id);
    emit(id, kind, { tool_name: String(tool || "tool").slice(0, 512) });
  }
  return {
    "chat.params": (input, output) => {
      const state = ensure(input?.sessionID);
      if (!state) return;
      const name = input?.model?.id ?? input?.model?.modelID;
      const effort = output?.options?.reasoningEffort ?? input?.model?.variant;
      const metadata = {};
      if (typeof name === "string" && name.length > 0 && Buffer.byteLength(name) <= 256 && !/[\x00-\x1f\x7f]/.test(name)) metadata.model = name;
      if (["none", "off", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].includes(effort)) metadata.reasoning_effort = effort;
      else if (metadata.model) metadata.reasoning_effort = "";
      state.metadata = metadata;
      return emit(input.sessionID, "usage.update");
    },
    event: ({ event }) => {
      const p = event?.properties || event?.data || {};
      switch (event?.type) {
        case "session.created":
          ensure(p.info?.id ?? p.sessionID);
          break;
        case "session.status":
          if (p.status?.type === "busy" || p.status?.type === "retry" || p.status === "busy" || p.status === "retry") busy(p.sessionID);
          else if (p.status?.type === "idle" || p.status === "idle") return complete(p.sessionID);
          break;
        case "session.idle":
          return complete(p.sessionID);
        case "session.error": {
          const state = ensure(p.sessionID);
          if (state) { state.status = "failed"; return emit(p.sessionID, "agent.failed", { message: "OpenCode session error" }); }
          break;
        }
        case "session.deleted": {
          const id = p.info?.id ?? p.sessionID;
          if (ensure(id)) {
            const delivered = emit(id, "session.end");
            sessions.delete(id);
            for (const key of tools.keys()) if (key.startsWith(`${id}\0`)) tools.delete(key);
            return delivered;
          }
          break;
        }
        case "message.part.updated": {
          const part = p.part ?? p;
          if (part?.type !== "tool") break;
          const status = part.state?.status;
          if (status === "running" || status === "completed" || status === "error") {
            toolEvent(part.sessionID, part.callID, part.tool, status);
          }
          break;
        }
        case "permission.asked": {
          const state = ensure(p.sessionID);
          if (state) {
            state.status = "approval";
            emit(p.sessionID, "approval.request", {
              approval_id: typeof p.id === "string" && p.id.length <= 256 ? p.id : randomUUID(),
              message: "Permission requested",
            });
          }
          break;
        }
        case "permission.replied":
          busy(p.sessionID);
          break;
      }
    },
    "tool.execute.before": (input) => {
      toolEvent(input?.sessionID, input?.callID, input?.tool, "running");
    },
    "tool.execute.after": (input, output) => {
      toolEvent(input?.sessionID, input?.callID, input?.tool, output?.error ? "error" : "completed");
    },
  };
}

export const SINotchPlugin = async (context) => createOpenCodeHooks(context);

// The plugin loader sees only SINotchPlugin as a module export. Tests inject an
// in-memory sink through a property rather than exporting another plugin function.
SINotchPlugin.createHooksForTest = createOpenCodeHooks;
SINotchPlugin.resolveHelperForTest = resolveHelper;

// OpenCode V2 reads the default definition and calls setup(ctx). V1 reads the
// named function above. Their lifecycle APIs are deliberately handled apart.
export default {
  id: "si-notch",
  async setup(ctx) {
    const hooks = createOpenCodeHooks({ directory: ctx.location?.directory });
    if (ctx.session?.hook) await ctx.session.hook("context", (event) => {
      try { hooks["chat.params"]({ sessionID: event.sessionID, model: event.model }, { options: event.options }); } catch {}
    });
    const controller = new AbortController();
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          try { await hooks.event({ event }); } catch {}
        }
      } catch {
        // The notifier must never interrupt the agent or plugin host.
      }
    })();
    await ctx.tool.hook("execute.before", (event) => {
      try { hooks["tool.execute.before"]({
        sessionID: event.sessionID, callID: event.callID ?? event.id, tool: event.tool,
      }); } catch {}
    });
    await ctx.tool.hook("execute.after", (event) => {
      try { hooks["tool.execute.after"]({
        sessionID: event.sessionID, callID: event.callID ?? event.id, tool: event.tool,
      }, { error: event.status === "error" ? true : undefined }); } catch {}
    });
    return () => controller.abort();
  },
};
