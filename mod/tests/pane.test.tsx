import type { On } from 'claude-code'
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
  { section: 'active', id: 'uuid-term', label: 'a terminal', state: 'working', actionable: false },
  { section: 'settled', id: 'c3', label: 'put away', state: 'done', actionable: true },
]

// The op's result rides under `value`, so a seeded read is `{ value: { value, version } }`.
const seeded = (value: unknown) => ({ value: { value, version: 1 } })

// Answers what a session start asks of the engine, with a fresh snapshot so no headless
// inbox starts, and records the panes it opens and the state it sets. `polled` settles
// with the start's first poll.
const startable = (on: On, sections: Record<string, unknown[]> = {}) => {
  const opened: string[] = []
  const set: Record<string, unknown> = {}
  let done = () => {}
  const polled = new Promise<void>(resolve => (done = resolve))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', () => ({ value: undefined }))
  on('session.id', () => ({ value: 'u-test' }))
  on('fs.read', () => ({ value: JSON.stringify({ written_at: 1_700_000_000, sections }) }))
  on('state.set', async ($, e, next) => {
    set[e.key] = e.value
    const result = await next(e)
    if (e.key === 'writtenAt') done()
    return result
  })
  on('ui.open', ($, e) => {
    opened.push(e.id)
    return { value: { isPlaced: true } }
  })
  return { opened, polled, set }
}

test('without the gem the pane says so, on every surface that seats a pane', async ($, on) => {
  mock.env(on, { HOME: '/Users/me' })
  mock.clock(on, { now: 1_700_000_000_000 })
  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /claude-inbox is not running/ })).toBeDefined()
    await ui.unmount()
  }
})

test('a snapshot older than thirty seconds is called stale, just now before a minute', async ($, on) => {
  mock.env(on, { HOME: '/Users/me' })
  mock.clock(on, { now: 1_700_000_000_000 })
  on('state.get', ($, e, next) => (e.key === 'writtenAt' ? seeded(1_700_000_000 - 45) : next(e)))
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /stopped just now; rows are stale/ })).toBeDefined()
  await ui.unmount()
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
    expect(await ui.find({ type: 'Text', text: /Active · 2/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Settled · 1/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /confirm: drop it\?/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /#7 open/ })).toBeDefined()
    expect(await ui.find({ text: /1 folded/ })).toBeDefined()
    expect(await ui.find({ text: /put away/ })).toBeUndefined()
    await ui.press({ key: 'g' })
    await ui.press({ key: 'e' })
    await ui.press({ key: 'z' })
    expect(await ui.find({ type: 'Button', key: 'x' })).toBeUndefined()
    await ui.press({ key: 'a' })
    expect(await ui.find({ text: /put away/ })).toBeDefined()
    expect(await ui.find({ type: 'Button', key: 'x' })).toBeDefined()
    await ui.press({ key: 'z' })
    await ui.press({ key: 'c' })
    expect(await ui.find({ text: /put away/ })).toBeUndefined()
    // Cursor and folds live in session state, so put them back for the next surface.
    await ui.press({ key: 'g' })
    await ui.press({ key: 'g' })
    await ui.unmount()
  }
})

test('the session the pane sits in leads the list under This session, with its own keys', async ($, on) => {
  mock.env(on, { HOME: '/Users/me' })
  mock.clock(on, { now: 1_700_000_000_000 })
  const [viewing, ...others] = ROWS
  on('state.get', ($, e, next) => {
    if (e.key === 'rows') return seeded(others)
    if (e.key === 'current') return seeded(viewing)
    if (e.key === 'writtenAt') return seeded(1_700_000_000)
    return next(e)
  })
  const written: string[] = []
  on('fs.write', ($, e) => {
    written.push(e.path)
    return { value: undefined }
  })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /^This session$/ })).toBeDefined()
  expect(await ui.find({ text: /needs an answer/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /Needs you/ })).toBeUndefined()
  await ui.press({ key: 'row:a1' })
  expect(written).toEqual([])
  await ui.press({ key: 'x' })
  expect(written).toEqual(['/Users/me/.config/claude-inbox/actions/pane-1700000000000.json'])
  await ui.unmount()
})

test('a poll lifts the row whose session is this one out of the list', async ($, on) => {
  mock.env(on, { HOME: '/Users/me' })
  mock.clock(on, { now: 1_700_000_000_000 })
  const { polled, set } = startable(on, {
    needs_you: [{ id: 'a1', session: 'u-test', label: 'mine' }],
    active: [{ id: 'b2', session: 'u-b2', label: 'other' }],
  })
  await $.session.start({ cwd: '/tmp/proj', surface: 'terminal', isInteractive: true })
  await polled
  expect((set.current as { id?: string } | null)?.id).toBe('a1')
  expect((set.rows as { id?: string }[]).map(row => row.id)).toEqual(['b2'])
})

test('x leaves a settle request for the inbox to apply', async ($, on) => {
  mock.env(on, { HOME: '/Users/me' })
  mock.clock(on, { now: 1_700_000_000_000 })
  on('state.get', ($, e, next) => (e.key === 'rows' ? seeded(ROWS) : e.key === 'writtenAt' ? seeded(1_700_000_000) : next(e)))
  const written: { path: string; text: string }[] = []
  on('fs.write', ($, e) => {
    written.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'x' })
  expect(written.length).toBe(1)
  expect(written[0]?.path).toBe('/Users/me/.config/claude-inbox/actions/pane-1700000000000.json')
  expect(JSON.parse(written[0]?.text ?? '{}')).toEqual({ action: 'settle', id: 'a1', at: 1_700_000_000_000 })
  await ui.unmount()
})

test('Enter asks the attached inbox for the row, naming this session, and refuses a terminal', async ($, on) => {
  mock.env(on, { HOME: '/Users/me' })
  mock.clock(on, { now: 1_700_000_000_000 })
  on('state.get', ($, e, next) => (e.key === 'rows' ? seeded(ROWS) : e.key === 'writtenAt' ? seeded(1_700_000_000) : next(e)))
  const written: { path: string; text: string }[] = []
  on('fs.write', ($, e) => {
    written.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'row:uuid-term' })
  expect(written.length).toBe(0)
  await ui.press({ key: 'row:b2' })
  expect(written.length).toBe(1)
  expect(written[0]?.path).toBe('/Users/me/.config/claude-inbox/switch.json')
  expect(JSON.parse(written[0]?.text ?? '{}')).toEqual({ id: 'b2', from: 'pane', at: 1_700_000_000 })
  await ui.unmount()
})

test('a click on a row puts the cursor on it before it asks for the switch', async ($, on) => {
  mock.env(on, { HOME: '/Users/me' })
  mock.clock(on, { now: 1_700_000_000_000 })
  on('state.get', ($, e, next) => (e.key === 'rows' ? seeded(ROWS) : e.key === 'writtenAt' ? seeded(1_700_000_000) : next(e)))
  const written: { path: string; text: string }[] = []
  on('fs.write', ($, e) => {
    written.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ key: 'row:b2' }))?.props.label).toBe('still going')
  await ui.press({ key: 'row:b2' })
  await ui.press({ key: 'x' })
  expect(written.map(one => one.path)).toEqual(['/Users/me/.config/claude-inbox/switch.json', '/Users/me/.config/claude-inbox/actions/pane-1700000000000.json'])
  expect(JSON.parse(written[1]?.text ?? '{}')).toMatchObject({ action: 'settle', id: 'b2' })
  await ui.unmount()
})

test('an unfocused pane says how to focus it', async ($, on) => {
  mock.env(on, { HOME: '/Users/me' })
  mock.clock(on, { now: 1_700_000_000_000 })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, isFocused: false } })
  expect(await ui.find({ type: 'Text', text: /takes you here/ })).toBeDefined()
  await ui.unmount()
})

test('the pane opens when a session starts', async ($, on) => {
  mock.env(on, { HOME: '/Users/me' })
  mock.clock(on, { now: 1_700_000_000_000 })
  const { opened, polled } = startable(on)
  await $.session.start({ cwd: '/tmp/proj', surface: 'terminal', isInteractive: true })
  await polled
  expect(opened).toEqual(['inbox'])
})

test('with openOnStart off only /inbox opens it', { options: { openOnStart: false } }, async ($, on) => {
  mock.env(on, { HOME: '/Users/me' })
  mock.clock(on, { now: 1_700_000_000_000 })
  const { opened, polled } = startable(on)
  await $.session.start({ cwd: '/tmp/proj', surface: 'terminal', isInteractive: true })
  await polled
  expect(opened).toEqual([])
})
