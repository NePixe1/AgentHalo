import assert from 'node:assert/strict'
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises'
import { tmpdir, homedir } from 'node:os'
import { join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'

const home = await mkdtemp(join(tmpdir(), 'agent-halo-opencode-test-'))
const original = { HOME: process.env.HOME, USERPROFILE: process.env.USERPROFILE }
process.env.HOME = process.env.USERPROFILE = home
assert.equal(homedir(), home, 'test must never write into the real user profile')
let plugin
try {
  const source = await readFile(new URL('../src/shared/integrations/opencode/agent-halo-status.js', import.meta.url), 'utf8')
  const { AgentHaloStatus } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'))
  const client = {
    provider: { list: async () => ({ data: { all: [{ id: 'test', models: { model: { limit: { context: 1000 } } } }] } }) },
    session: {
      get: async ({ path }) => ({ data: { title: 'Session ' + path.id, parentID: path.id === 'child' ? 'root' : undefined } }),
      messages: async () => ({ data: [] }),
      status: async () => ({ data: {} }),
      list: async () => ({ data: [] }),
    },
  }
  plugin = await AgentHaloStatus({ client, directory: home })
  const event = (type, properties = {}) => plugin.event({ event: { type, properties: { sessionID: 'root', ...properties } } })
  const read = async (id = 'root') => {
    await delay(100)
    const root = join(home, '.agent-halo', 'cache', 'opencode')
    const files = (await readdir(root)).filter(f => f.endsWith('.json'))
    const data = JSON.parse(await readFile(join(root, files[0]), 'utf8'))
    return id ? data.sessions.find(s => s.id === id) : data
  }
  assert.equal((await read(null)).sessions.length, 0)
  await plugin['chat.message']({ sessionID: 'root', model: { providerID: 'test', modelID: 'model' } })
  assert.equal((await read()).state, 'thinking')
  for (const callID of ['a', 'b']) await plugin['tool.execute.before']({ sessionID: 'root', callID, tool: 'bash' })
  await plugin['tool.execute.after']({ sessionID: 'root', callID: 'a' })
  assert.equal((await read()).state, 'working', 'parallel tool still active')
  await event('permission.asked', { id: 'permit' })
  assert.equal((await read()).state, 'attention')
  await event('permission.replied', { requestID: 'permit' })
  assert.equal((await read()).state, 'working')
  await plugin['tool.execute.after']({ sessionID: 'root', callID: 'b' })
  assert.equal((await read()).state, 'thinking')
  await event('message.part.updated', { part: { sessionID: 'root', type: 'text', text: 'intermediate answer' } })
  assert.equal((await read()).state, 'thinking', 'text does not imply completion')
  await event('session.status', { status: { type: 'retry' } })
  assert.equal((await read()).state, 'thinking', 'retry is not fatal')
  await plugin['experimental.session.compacting']({ sessionID: 'root' })
  assert.equal((await read()).state, 'working')
  await event('session.compacted')
  await event('message.updated', { info: { role: 'assistant', modelID: 'model', providerID: 'test', tokens: { input: 100, output: 20, cache: { read: 30, write: 10 } } } })
  let state = await read()
  assert.equal(state.context, 160)
  assert.equal(state.contextWindow, 1000)
  await event('message.updated', { info: { role: 'assistant', tokens: { input: 0, output: 0, cache: { read: 0, write: 0 } } } })
  state = await read()
  assert.equal(state.input, 100, 'streaming zero must not erase previous input')
  assert.equal(state.output, 20, 'streaming zero must not erase previous output')
  assert.equal(state.context, 160, 'streaming zero must not erase context')
  client.session.messages = async () => ({ data: [
    { info: { role: 'assistant', modelID: 'model', providerID: 'test', tokens: { input: 321, output: 45 } } },
    { info: { role: 'assistant', tokens: { input: 0, output: 0 } } },
  ] })
  await plugin['chat.message']({ sessionID: 'resumed', model: { providerID: 'test', modelID: 'model' } })
  assert.equal((await read('resumed')).input, 321, 'known model still hydrates last usable usage')
  await event('session.idle')
  state = await read()
  assert.equal(state.state, 'done')
  await event('session.status', { status: { type: 'idle' } })
  assert.equal((await read()).completedAt, state.completedAt, 'duplicate idle does not flash again')
  await event('permission.asked', { id: 'child-permit', sessionID: 'child' })
  assert.equal((await read('child')).parentID, 'root')
  assert.equal((await read()).state, 'done', 'child events never change parent')
  await event('session.error')
  await event('session.idle')
  assert.equal((await read()).state, 'error', 'idle does not erase terminal error')
  await event('session.error', { error: { name: 'MessageAbortedError' } })
  assert.equal((await read()).state, 'idle', 'user cancellation is not a red fault')
  await plugin.dispose()
  assert.equal((await readdir(join(home, '.agent-halo', 'cache', 'opencode'))).filter(f => f.endsWith('.json')).length, 0)
  console.log('PASS: OpenCode lifecycle, parallel tools, permissions, retries, compaction, metrics, children and cleanup')
} finally {
  await plugin?.dispose()
  for (const [key, value] of Object.entries(original)) {
    if (value === undefined) delete process.env[key]
    else process.env[key] = value
  }
  await rm(home, { recursive: true, force: true })
}
