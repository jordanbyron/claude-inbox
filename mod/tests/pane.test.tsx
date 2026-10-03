import { expect, mock, test } from 'claude-code/testing'

const PANE = {
  plugin: 'inbox-pane',
  component: 'Pane',
  requestId: 'inbox',
  props: { title: 'Inbox', isFocused: true, bodyColumns: 48, placement: 'dock', scroll: { offset: 0, bodyRows: 30 }, view: {} },
  viewport: { columns: 160, rows: 40 },
} as const

const ROWS = [
  { section: 'needs_you', id: 'a1', label: 'needs an answer', state: 'blocked', actionable: true, line: 'confirm: drop it?' },
  { section: 'active', id: 'b2', label: 'still going', state: 'working', actionable: true, line: 'running bin/ci', pr: { short: '#7', state: 'open', url: 'https://github.com/o/r/pull/7' } },
  { section: 'settled', id: 'c3', label: 'put away', state: 'done', actionable: true },
]

// The op's result rides under `value`, so a seeded read is `{ value: { value, version } }`.
const seeded = (value: unknown) => ({ value: { value, version: 1 } })

test('without the gem the pane says so, on every surface that seats a pane', async ($, on) => {
  mock.env(on, { HOME: '/Users/me' })
  mock.clock(on, { now: 1_700_000_000_000 })
  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /claude-inbox is not running/ })).toBeDefined()
    await ui.unmount()
  }
})

test("rows sit under the gem's sections, Settled folded until za opens it", async ($, on) => {
  mock.env(on, { HOME: '/Users/me' })
  mock.clock(on, { now: 1_700_000_000_000 })
  on('state.get', ($, e, next) => {
    if (e.key === 'rows') return seeded(ROWS)
    if (e.key === 'writtenAt') return seeded(1_700_000_000)
    return next(e)
  })
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /Needs you · 1/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Active · 1/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Settled · 1/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /confirm: drop it\?/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /#7 open/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /1 folded/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /put away/ })).toBeUndefined()
    await ui.press({ key: 'g' })
    await ui.press({ key: 'e' })
    await ui.press({ key: 'z' })
    expect(await ui.find({ type: 'Button', key: 'x' })).toBeUndefined()
    await ui.press({ key: 'a' })
    expect(await ui.find({ type: 'Text', text: /put away/ })).toBeDefined()
    expect(await ui.find({ type: 'Button', key: 'x' })).toBeDefined()
    await ui.press({ key: 'z' })
    await ui.press({ key: 'c' })
    expect(await ui.find({ type: 'Text', text: /put away/ })).toBeUndefined()
    // Cursor and folds live in session state, so put them back for the next surface.
    await ui.press({ key: 'g' })
    await ui.press({ key: 'g' })
    await ui.unmount()
  }
})

test('x on an actionable row writes a settle into state.json', async ($, on) => {
  mock.env(on, { HOME: '/Users/me' })
  mock.clock(on, { now: 1_700_000_000_000 })
  on('state.get', ($, e, next) => (e.key === 'rows' ? seeded(ROWS) : e.key === 'writtenAt' ? seeded(1_700_000_000) : next(e)))
  const written: string[] = []
  on('fs.read', ($, e, next) => (e.path.endsWith('state.json') ? { value: '{"version":1,"sessions":{}}' } : next(e)))
  on('fs.write', ($, e) => {
    written.push(e.text)
    return { value: undefined }
  })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'x' })
  expect(written.length).toBe(1)
  expect(JSON.parse(written[0] ?? '{}').sessions.a1.settled_at).toBe(1_700_000_000)
  await ui.unmount()
})

test('an unfocused pane says how to focus it', async ($, on) => {
  mock.env(on, { HOME: '/Users/me' })
  mock.clock(on, { now: 1_700_000_000_000 })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, isFocused: false } })
  expect(await ui.find({ type: 'Text', text: /takes you here/ })).toBeDefined()
  await ui.unmount()
})
