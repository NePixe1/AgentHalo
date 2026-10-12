// Agent Halo: local metadata only. No prompts, tool arguments or credentials.
import { mkdir, writeFile, rename, unlink } from "node:fs/promises"
import { join } from "node:path"
import { homedir } from "node:os"
import { randomUUID } from "node:crypto"

export const AgentHaloStatus = async ({ client, directory }) => {
  const root = join(homedir(), ".agent-halo", "cache", "opencode")
  const instance = randomUUID()
  const file = join(root, `${process.pid}-${instance}.json`)
  const startedAt = new Date(Date.now() - process.uptime() * 1000).toISOString()
  const sessions = new Map()
  let closed = false, timer, pending, writing = Promise.resolve()
  let models = new Map()
  let modelsLoading = false, modelsCheckedAt = 0
  const usageRevision = new Map()
  const session = (id) => {
    if (!id) return null
    if (!sessions.has(id)) sessions.set(id, {
      id, title: "", parentID: "", directory, state: "idle", active: false,
      tools: new Set(), waits: new Set(), updatedAt: new Date().toISOString(),
      completedAt: null, model: "", provider: "", input: 0, output: 0,
      cacheRead: 0, context: 0, contextWindow: 0, event: "session.created",
    })
    return sessions.get(id)
  }
  function touch(s, event) { s.updatedAt = new Date().toISOString(); s.event = event }
  function activeState(s) {
    s.state = s.waits.size ? "attention" : s.tools.size || s.compacting ? "working" : "thinking"
  }
  function snapshot() {
    return { version: 1, instance, pid: process.pid, startedAt,
      timestamp: new Date().toISOString(), directory,
      sessions: [...sessions.values()].map(({ tools, waits, ...s }) => s) }
  }
  function flush() {
    if (closed) return writing
    clearTimeout(pending)
    pending = null
    const data = JSON.stringify(snapshot())
    writing = writing.then(async () => {
      await mkdir(root, { recursive: true })
      await writeFile(file + ".tmp", data, "utf8")
      await rename(file + ".tmp", file)
    }).catch(() => {})
    return writing
  }
  function schedule() {
    if (!closed && !pending) { pending = setTimeout(flush, 50); pending.unref?.() }
  }
  async function metadata(id) {
    const revision = usageRevision.get(id) || 0
    try {
      const { data } = await client.session.get({ path: { id } })
      const s = session(id)
      if (s && data) { s.title = data.title || s.title; s.parentID = data.parentID || ""; schedule() }
      if (s) {
        const messages = await client.session.messages({ path: { id }, query: { directory, limit: 20 } })
        const latest = [...(messages.data || [])].reverse().find(m => m.info?.role === "assistant" && usableUsage(m.info))
        if (latest && revision === (usageRevision.get(id) || 0)) { modelInfo(s, latest.info); schedule() }
      }
    } catch {}
  }
  function usableUsage(info) {
    const t = info.tokens
    return t && (t.input > 0 || t.output > 0 || t.cache?.read > 0 || t.cache?.write > 0)
  }
  async function refreshModels() {
    if (modelsLoading || Date.now() - modelsCheckedAt < 30000) return
    modelsLoading = true; modelsCheckedAt = Date.now()
    try {
      const { data } = await client.provider.list({ query: { directory } })
      for (const provider of data?.all || []) for (const [id, model] of Object.entries(provider.models || {})) {
        if (!(model.limit?.context > 0)) continue
        models.set(`${provider.id}/${id}`, model.limit.context)
        if (model.id) models.set(`${provider.id}/${model.id}`, model.limit.context)
      }
      for (const s of sessions.values()) s.contextWindow = models.get(`${s.provider}/${s.model}`) || s.contextWindow
      schedule()
    } catch {} finally { modelsLoading = false }
  }
  function modelInfo(s, info) {
    s.model = info.modelID || info.model?.modelID || s.model
    s.provider = info.providerID || info.model?.providerID || s.provider
    s.contextWindow = models.get(`${s.provider}/${s.model}`) || 0
    if (!s.contextWindow) void refreshModels()
    // New assistant records start at zero while streaming. Keep the last real usage.
    if (info.role === "assistant" && usableUsage(info)) {
      s.input = info.tokens.input || 0; s.output = info.tokens.output || 0
      s.cacheRead = info.tokens.cache?.read || 0
      s.context = s.input + s.cacheRead + (info.tokens.cache?.write || 0) + s.output
      usageRevision.set(s.id, (usageRevision.get(s.id) || 0) + 1)
    }
  }
  function toolPart(s, part) {
    const key = part.callID || part.id
    if (!key) return
    if (part.state?.status === "running" || part.state?.status === "pending") {
      s.active = true; s.tools.add(key)
    } else {
      s.tools.delete(key)
      s.waits.delete(key)
    }
    if (s.active) activeState(s)
  }
  async function eventHandler({ event }) {
    const p = event.properties || {}, info = p.info || {}, part = p.part || {}
    if (event.type === "server.instance.disposed") {
      if (!p.directory || p.directory === directory) await dispose()
      return
    }
    const id = p.sessionID || info.sessionID || part.sessionID ||
      (event.type.startsWith("session.") ? info.id : null)
    if (!id) return
    const isNew = !sessions.has(id)
    const s = session(id)
    if (isNew) void metadata(id)
    if (event.type === "session.deleted") { sessions.delete(id); schedule(); return }
    if (event.type === "session.created" || event.type === "session.updated") {
      s.title = info.title || s.title; s.parentID = info.parentID || s.parentID
    } else if (event.type === "session.status" && p.status?.type !== "idle") {
      s.active = true; s.completedAt = null; activeState(s)
      // Retrying is still activity, not a terminal fault.
    } else if (event.type === "session.idle" ||
      (event.type === "session.status" && p.status?.type === "idle")) {
      if (s.waits.size) s.state = "attention"
      else if (s.state !== "error" && s.active) {
        s.state = "done"; s.active = false; s.completedAt = new Date().toISOString()
        s.tools.clear(); s.compacting = false
      }
    } else if (event.type === "permission.asked" || event.type === "question.asked") {
      s.waits.add(p.id || event.type); s.active = true; s.state = "attention"
    } else if (["permission.replied", "question.replied", "question.rejected"].includes(event.type)) {
      s.waits.delete(p.requestID || p.id || (event.type.startsWith("permission") ? "permission.asked" : "question.asked"))
      activeState(s)
    } else if (event.type === "session.error") {
      s.state = p.error?.name === "MessageAbortedError" ? "idle" : "error"
      s.active = false; s.tools.clear(); s.waits.clear(); s.compacting = false
    } else if (event.type === "session.compacted") {
      s.compacting = false; if (s.active) activeState(s)
    } else if (event.type === "message.updated") {
      modelInfo(s, info)
      if (info.role === "user" && !info.summary && !info.synthetic) {
        s.active = true; s.completedAt = null; activeState(s)
      }
    } else if (event.type === "message.part.updated") {
      if (part.type === "tool") toolPart(s, part)
      // Text (including intermediate commentary) never marks completion.
    } else return
    touch(s, event.type); schedule()
  }
  async function dispose() {
    if (closed) return
    closed = true; clearInterval(timer); clearTimeout(pending)
    await writing
    await unlink(file).catch(() => {})
  }
  await flush()
  timer = setInterval(flush, 3000); timer.unref?.()
  // SDK reads hydrate resumed sessions without turning historical idle into done.
  void (async () => {
    await refreshModels()
    try {
      const { data } = await client.session.status()
      for (const [id, status] of Object.entries(data || {})) {
        if (sessions.has(id)) continue
        const s = session(id)
        if (status.type !== "idle") { s.active = true; activeState(s) }
        void metadata(id)
      }
    } catch {}
    try {
      const { data } = await client.session.list({ query: { directory, limit: 1 } })
      const latest = (data || []).filter(s => !s.parentID && (!s.directory || s.directory === directory))
        .sort((a, b) => (b.time?.updated || 0) - (a.time?.updated || 0))[0]
      if (latest && !sessions.has(latest.id)) {
        const s = session(latest.id); s.title = latest.title || ""; void metadata(s.id)
      }
    } catch {}
    schedule()
  })()
  return {
    event: eventHandler,
    "chat.message": async (input) => {
      const s = session(input.sessionID); if (!s) return
      s.active = true; s.completedAt = null; modelInfo(s, input); activeState(s)
      touch(s, "chat.message"); void metadata(s.id); schedule()
    },
    "tool.execute.before": async (input) => {
      const s = session(input.sessionID); if (!s) return
      s.active = true; s.tools.add(input.callID)
      if (input.tool === "question") s.waits.add(input.callID)
      activeState(s); touch(s, "tool.execute.before"); schedule()
    },
    "tool.execute.after": async (input) => {
      const s = session(input.sessionID); if (!s) return
      s.tools.delete(input.callID); s.waits.delete(input.callID)
      if (s.active) activeState(s)
      touch(s, "tool.execute.after"); schedule()
    },
    "experimental.session.compacting": async ({ sessionID }) => {
      const s = session(sessionID); if (!s) return
      s.compacting = true; s.active = true; activeState(s)
      touch(s, "context.compacting"); schedule()
    },
    dispose,
  }
}
