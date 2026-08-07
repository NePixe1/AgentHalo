import { appendFileSync, existsSync, mkdirSync, renameSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

type JsonRecord = Record<string, unknown>;

const logPath = join(homedir(), ".agent-halo", "logs", "pi-status.jsonl");
const maxLogBytes = 2 * 1024 * 1024;

export default function registerAgentHaloPiStatus(pi: any) {
  let state = "idle";

  const latestAssistant = (ctx: any): any => {
    try {
      const branch = ctx.sessionManager?.getBranch?.() ?? [];
      for (let index = branch.length - 1; index >= 0; index -= 1) {
        const message = branch[index]?.message;
        if (message?.role === "assistant") return message;
      }
    } catch {
      // A partially-written session must never interrupt Pi.
    }
    return null;
  };

  const writeStatus = (event: string, nextState: string, ctx: any,
    extra: JsonRecord = {}) => {
    state = nextState;
    try {
      const context = ctx.getContextUsage?.() ?? null;
      // Only publish context fields as a complete set. A lone model.contextWindow
      // without tokens makes readers show a false 0% pill.
      const hasContextUsage = context != null
        && typeof context.tokens === "number"
        && typeof context.contextWindow === "number"
        && context.contextWindow > 0;
      const assistant = latestAssistant(ctx);
      const usage = assistant?.usage ?? {};
      const model = ctx.model ?? {};
      const record: JsonRecord = {
        version: 1,
        timestamp: new Date().toISOString(),
        source: "pi-extension",
        event,
        state,
        pid: process.pid,
        sessionId: ctx.sessionManager?.getSessionId?.() ?? null,
        cwd: ctx.cwd ?? process.cwd(),
        provider: model.provider ?? assistant?.provider ?? null,
        model: model.id ?? assistant?.model ?? null,
        contextTokens: hasContextUsage ? context.tokens : null,
        contextWindow: hasContextUsage ? context.contextWindow : null,
        contextPercent: hasContextUsage ? (context.percent ?? null) : null,
        inputTokens: usage.input ?? null,
        outputTokens: usage.output ?? null,
        cacheRead: usage.cacheRead ?? null,
        cacheWrite: usage.cacheWrite ?? null,
        ...extra,
      };
      mkdirSync(dirname(logPath), { recursive: true });
      if (existsSync(logPath) && statSync(logPath).size >= maxLogBytes) {
        try { renameSync(logPath, `${logPath}.1`); } catch { /* keep appending */ }
      }
      appendFileSync(logPath, `${JSON.stringify(record)}\n`, "utf8");
    } catch {
      // Monitoring is observational and must never break an agent session.
    }
  };

  pi.on("session_start", (_event: any, ctx: any) =>
    writeStatus("session_start", "idle", ctx));
  pi.on("session_shutdown", (event: any, ctx: any) =>
    writeStatus("session_shutdown", "offline", ctx,
      { reason: event?.reason ?? null }));
  pi.on("input", (_event: any, ctx: any) =>
    writeStatus("input", "thinking", ctx));
  pi.on("before_agent_start", (_event: any, ctx: any) =>
    writeStatus("before_agent_start", "thinking", ctx));
  pi.on("agent_start", (_event: any, ctx: any) =>
    writeStatus("agent_start", "thinking", ctx));
  pi.on("turn_start", (_event: any, ctx: any) =>
    writeStatus("turn_start", "thinking", ctx));

  pi.on("message_update", (event: any, ctx: any) => {
    const updateType = event?.assistantMessageEvent?.type ?? "";
    // A start event is sufficient to change the ring. Ignoring token deltas
    // avoids synchronous disk I/O for every streamed token.
    if (updateType === "thinking_start") {
      writeStatus("message_update", "thinking", ctx, { updateType });
    } else if (updateType === "text_start" || updateType === "toolcall_start") {
      writeStatus("message_update", "working", ctx, { updateType });
    }
  });

  pi.on("tool_execution_start", (event: any, ctx: any) =>
    writeStatus("tool_execution_start", "working", ctx,
      { toolName: event?.toolName ?? null }));
  pi.on("tool_execution_end", (event: any, ctx: any) =>
    writeStatus("tool_execution_end", "thinking", ctx,
      { toolName: event?.toolName ?? null, toolError: event?.isError === true }));

  pi.on("message_end", (event: any, ctx: any) => {
    const message = event?.message;
    if (message?.role !== "assistant") return;
    if (message.stopReason === "error") {
      writeStatus("message_end", "error", ctx, {
        stopReason: message.stopReason,
      });
    }
  });

  // agent_end may be followed by retry, compaction or queued continuation.
  // agent_settled is Pi's authoritative terminal point for the whole turn.
  pi.on("agent_settled", (_event: any, ctx: any) => {
    const assistant = latestAssistant(ctx);
    if (assistant?.stopReason === "error") {
      writeStatus("agent_settled", "error", ctx, {
        stopReason: assistant.stopReason,
      });
      return;
    }
    writeStatus("agent_settled", "done", ctx,
      { stopReason: assistant?.stopReason ?? null });
  });

  pi.on("model_select", (_event: any, ctx: any) =>
    writeStatus("model_select", state, ctx));
}
