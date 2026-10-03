import { expect, mock, test } from 'claude-code/testing'

const PANE = {
  plugin: 'inbox-pane',
  component: 'Pane',
  requestId: 'inbox',
  props: { title: 'Inbox', isFocused: true, bodyColumns: 48, placement: 'dock', scroll: { offset: 0, bodyRows: 30 }, view: {} },
  viewport: { columns: 160, rows: 40 },
} as const
const ROWS = [{ section: 'needs_you', id: 'a1', label: 'needs an answer', state: 'blocked', actionable: true, line: 'confirm: drop it?' }]
const seeded = (value: unknown) => ({ value: { value, version: 1 } })

test('s then 1 leaves a fifteen-minute snooze request', async ($, on) => {
  mock.env(on, { HOME: '/Users/me' })
  mock.clock(on, { now: 1_700_000_000_000 })
  on('state.get', ($, e, next) => (e.key === 'rows' ? seeded(ROWS) : e.key === 'writtenAt' ? seeded(1_700_000_000) : next(e)))
  const written: string[] = []
  on('fs.write', ($, e) => {
    written.push(e.text)
    return { value: undefined }
  })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Button', key: '1' })).toBeUndefined()
  await ui.press({ key: 's' })
  expect(await ui.find({ type: 'Button', key: '1' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /15 minutes/ })).toBeDefined()
  await ui.press({ key: '1' })
  expect(written.length).toBe(1)
  expect(JSON.parse(written[0] ?? '{}')).toEqual({ action: 'snooze', id: 'a1', choice: 'm15', at: 1_700_000_000_000 })
  await ui.unmount()
})
