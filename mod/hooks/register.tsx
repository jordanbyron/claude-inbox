import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Folds, InboxRow, Pending, Section } from '../types'

const PANE = 'inbox'
const POLL_MS = 500
// Older than this and the writer has quit: it rewrites every 5 s even when nothing changed.
const STALE_S = 30
// How long a headless start gets to produce a fresh snapshot before another is tried.
const RESTART_S = 60
// A chord's first key waits this long for its second.
const CHORD_MS = 5000
// How long an attached inbox gets to take a switch request before the pane gives up on it.
const SWITCH_MS = 3000
// The gem's files, under HOME. The snapshot is read; the actions directory and switch.json
// take the pane's requests, which the gem applies: nothing here edits the gem's own state.
const SNAPSHOT = '.config/claude-inbox/snapshot.json'
const ACTIONS = '.config/claude-inbox/actions'
const SWITCH = '.config/claude-inbox/switch.json'
// The sessions to switch to; the one this pane sits in is lifted out into `current`.
const rows = atom({ plugin: 'inbox-pane', key: 'rows' } as const, [])
const current = atom({ plugin: 'inbox-pane', key: 'current' } as const, null)
const writtenAt = atom({ plugin: 'inbox-pane', key: 'writtenAt' } as const, 0)
const cursor = atom({ plugin: 'inbox-pane', key: 'cursor' } as const, 0)
const folds = atom({ plugin: 'inbox-pane', key: 'folds' } as const, { snoozed: true, settled: true })
const pending = atom({ plugin: 'inbox-pane', key: 'pending' } as const, null)

export type SnapshotRow = {
  id?: string
  session?: string
  label?: string
  state?: string
  actionable?: boolean
  waiting?: boolean
  line?: string
  wake_at?: number | 'until_woken'
  remote?: string
  pr?: { short?: string; state?: string; url?: string }
}
type Snapshot = { written_at?: number; sections?: Partial<Record<Section, SnapshotRow[]>> }
// This session, as the gem's files name it, and the headless inbox this module may start.
type Host = { session: string; command: string; headlessStartedAt: number; isHeadlessRunning: boolean }
type Fold = keyof Folds
type Item = { kind: 'row'; row: InboxRow } | { kind: 'fold'; section: Fold; count: number }
type Snooze = 'm15' | 'h1' | 'tomorrow_9am' | 'until_woken'
type Action = { action: 'settle' | 'wake' | 'pin'; id: string } | { action: 'snooze'; id: string; choice: Snooze }

const ORDER: Section[] = ['pinned', 'needs_you', 'active', 'snoozed', 'settled']
const TITLE: Record<Section, string> = { pinned: 'Pinned', needs_you: 'Needs you', active: 'Active', snoozed: 'Snoozed', settled: 'Settled' }
const GLYPH: Record<string, string> = { blocked: '●', failed: '✗', working: '◐', idle: '◌', done: '✓', stopped: '✓' }
const COLOR: Record<string, string> = { blocked: 'red', failed: 'red', working: 'green', idle: 'cyan' }
const PR_COLOR: Record<string, string> = { open: 'green', draft: 'yellow', merged: 'magenta', closed: 'red' }
const SNOOZE: Record<string, { choice: Snooze; label: string }> = {
  '1': { choice: 'm15', label: '15m' },
  '2': { choice: 'h1', label: '1h' },
  '3': { choice: 'tomorrow_9am', label: 'tomorrow 9am' },
  '4': { choice: 'until_woken', label: 'until woken' },
}
// What each chord's second key does, drawn under the footer while it waits.
const MENU: Record<NonNullable<Pending>, [string, string][]> = {
  g: [
    ['g', 'first'],
    ['e', 'last'],
  ],
  z: [
    ['a', 'toggle the fold'],
    ['o', 'open it'],
    ['c', 'close it'],
  ],
  s: [
    ['1', '15 minutes'],
    ['2', '1 hour'],
    ['3', 'tomorrow 9am'],
    ['4', 'until woken'],
  ],
}

function isFold(section: Section): section is Fold {
  return section === 'snoozed' || section === 'settled'
}

// The Button drawn for an item, its label: the ring walks these with the arrows, a click presses one.
function itemKey(item: Item): string {
  return item.kind === 'fold' ? `fold:${item.section}` : `row:${item.row.id ?? item.row.label}`
}

// The visible box drawn for an item, what the pane scrolls to.
function viewKey(item: Item): string {
  return `view:${itemKey(item)}`
}

// The session the pane sits in leads, in a group of its own.
function groupsOf(list: InboxRow[], folded: Folds, current: InboxRow | null): { section: Section | null; items: Item[] }[] {
  const lead = current ? [{ section: null, items: [{ kind: 'row', row: current } as Item] }] : []
  return lead.concat(
    ORDER.flatMap(section => {
      const own = list.filter(row => row.section === section)
      if (own.length === 0) return []
      const items: Item[] = isFold(section) && folded[section] ? [{ kind: 'fold', section, count: own.length }] : own.map(row => ({ kind: 'row', row }))
      return [{ section, items }]
    }),
  )
}

async function listed($: EngineInterface): Promise<Item[]> {
  return groupsOf(await read($, rows), await read($, folds), await read($, current)).flatMap(group => group.items)
}

// The stored cursor may point past a list that has shrunk since it was set.
function onList(flat: Item[], at: number): number {
  return Math.min(at, Math.max(0, flat.length - 1))
}

async function readJson<T>($: EngineInterface, path: string, fallback: T): Promise<T> {
  try {
    return JSON.parse(await $.fs.read(path)) as T
  } catch {
    return fallback
  }
}

export function rowOf(section: Section, one: SnapshotRow): InboxRow {
  const pr = one.pr?.short && one.pr.url ? { short: one.pr.short, state: one.pr.state ?? '', url: one.pr.url } : undefined
  return {
    section,
    id: one.id,
    session: one.session,
    label: one.label ?? one.id ?? '',
    state: one.state ?? 'unknown',
    actionable: one.actionable === true,
    isWaiting: one.waiting === true,
    line: one.line,
    wakeAt: one.wake_at,
    remote: one.remote,
    pr,
  }
}

function wakeLabel(wakeAt: number | 'until_woken'): string {
  if (wakeAt === 'until_woken') return 'until woken'
  const at = new Date(wakeAt * 1000)
  return `${String(at.getHours()).padStart(2, '0')}:${String(at.getMinutes()).padStart(2, '0')}`
}

function ago(seconds: number): string {
  return seconds < 60 ? 'just now' : `${Math.floor(seconds / 60)}m ago`
}

async function inboxFile($: EngineInterface, path: string): Promise<string> {
  return `${(await $.env.get('HOME')) ?? ''}/${path}`
}

async function nowS($: EngineInterface): Promise<number> {
  return Math.floor((await $.clock.now()) / 1000)
}

// Read each time: it is the transcript's name, which the daemon reports as sessionId,
// and a /clear may mint a new one mid-session.
async function sessionId($: EngineInterface, host: Host): Promise<string> {
  return $.session.id().catch(() => host.session)
}

// Leaves one request for the inbox to apply; its poller takes it within half a second
// and the next snapshot shows the row where the gem's own rules put it.
async function ask($: EngineInterface, host: Host, action: Action): Promise<void> {
  const actions = await inboxFile($, ACTIONS)
  const at = Math.floor(await $.clock.now())
  await $.fs.write(`${actions}/${host.session}-${at}.json`, JSON.stringify({ ...action, at }))
}

// Asks the inbox attached to this session for another one. It takes the file when it
// does; a file still there after SWITCH_MS, and still ours, means no inbox is attached to
// this session.
async function requestSwitch($: EngineInterface, host: Host, id: string): Promise<void> {
  const path = await inboxFile($, SWITCH)
  const from = await sessionId($, host)
  const at = await nowS($)
  await $.fs.write(path, JSON.stringify({ id, from, at }))
  $.ui.toast(`switching to ${id}…`)
  $.clock.after(SWITCH_MS, () => {
    void readJson<{ from?: string; at?: number } | null>($, path, null).then(async left => {
      if (left === null || left.from !== from || left.at !== at) return
      await $.fs.write(path, '')
      $.ui.toast('no inbox is attached to this session: run claude-inbox, attach from it, and press Enter here')
    })
  })
}

// Only while no inbox writes the snapshot; the gem's writer lock turns a second one away.
function startHeadless($: EngineInterface, host: Host, now: number): void {
  if (host.isHeadlessRunning || now - host.headlessStartedAt < RESTART_S) return
  host.headlessStartedAt = now
  host.isHeadlessRunning = true
  void (async () => {
    try {
      const child = $.process.spawn({ argv: [host.command, '--headless'] })
      for await (const piece of child) {
        if ('text' in piece) $.ui.log(`${host.command} --headless: ${piece.text.trim()}`, { to: 'debug' })
      }
    } catch (error) {
      $.ui.log(`${host.command} --headless did not start: ${String(error)}`, { to: 'debug' })
    } finally {
      host.isHeadlessRunning = false
    }
  })()
}

async function poll($: EngineInterface, host: Host): Promise<void> {
  const file = await inboxFile($, SNAPSHOT)
  const now = await nowS($)
  const snapshot = await readJson<Snapshot | null>($, file, null)
  const written = snapshot?.written_at ?? 0
  if (snapshot !== null) {
    const all = ORDER.flatMap(section => (snapshot.sections?.[section] ?? []).map(one => rowOf(section, one)))
    const id = await sessionId($, host)
    await update($, current, () => all.find(one => one.session === id) ?? null)
    await update($, rows, () => all.filter(one => one.session !== id))
  }
  await update($, writtenAt, () => written)
  if (now - written > STALE_S) startHeadless($, host, now)
}

// Puts the ring on the item's Button, so Enter acts on it, and scrolls it into view.
async function ringOn($: EngineInterface, item: Item): Promise<void> {
  await $.ui.focus({ requestId: PANE, key: itemKey(item) }).catch(() => undefined)
  await $.ui.scroll({ in: PANE, to: { key: viewKey(item) }, block: 'nearest' }).catch(() => undefined)
}

// Moves the cursor and keeps it on screen.
async function moveTo($: EngineInterface, flat: Item[], to: number): Promise<void> {
  const at = Math.max(0, Math.min(flat.length - 1, to))
  await update($, cursor, () => at)
  await update($, pending, () => null)
  const item = flat[at]
  if (item) await ringOn($, item)
}

async function setFold($: EngineInterface, list: InboxRow[], current: InboxRow | null, name: Fold | undefined, open: boolean): Promise<void> {
  await update($, pending, () => null)
  if (!name) return
  const folded = await update($, folds, f => ({ ...f, [name]: !open }))
  // The item under the cursor may have just become a fold, or the fold its rows.
  const groups = groupsOf(list, folded, current)
  const at = groups.findIndex(group => group.section === name)
  if (at >= 0) await moveTo($, groups.flatMap(group => group.items), groups.slice(0, at).flatMap(group => group.items).length)
}

async function startChord($: EngineInterface, key: Pending): Promise<void> {
  await update($, pending, () => key)
  $.clock.after(CHORD_MS, () => void update($, pending, now => (now === key ? null : now)))
}

export const register: Register = (on, options) => {
  const command = typeof options.command === 'string' && options.command !== '' ? options.command : 'claude-inbox'
  const host: Host = { session: 'pane', command, headlessStartedAt: 0, isHeadlessRunning: false }

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'inbox', description: 'Open the inbox of background sessions' })
    const started = await next(e)
    host.session = await $.session.id()
    // A pinned line outlives a reload, so an earlier version's is cleared here.
    $.ui.status(undefined)
    void poll($, host)
    $.clock.every(POLL_MS, () => void poll($, host))
    if (options.openOnStart === false) return started
    const opened = await $.ui.open({ id: PANE, title: 'Inbox', columns: 48 })
    if (!opened.isPlaced) $.ui.log(`inbox: /inbox opens the pane (${opened.reason})`, { to: 'debug' })
    return started
  })

  on('command.run', { command: 'inbox' }, async $ => {
    void poll($, host)
    const opened = await $.ui.open({ id: PANE, title: 'Inbox', focus: true, columns: 48 })
    const surfaces = (await $.session.surfaces()).join(', ') || 'none'
    if (!opened.isPlaced) return { text: `Inbox pane not drawn: ${opened.reason}. Surfaces: ${surfaces}.` }
    return { text: `Inbox pane open on ${surfaces}. ctrl+x tab focuses it; the keys are claude-inbox's.` }
  })

  // The ring walks the items' Buttons and nothing else: entering the pane it lands on
  // the cursor's item, the arrows move it to the next, and the cursor follows.
  on('ui.focus', { requestId: PANE }, async ($, e, next) => {
    const flat = await listed($)
    if (e.element === undefined) {
      const item = flat[onList(flat, await read($, cursor))]
      return item ? next({ ...e, element: itemKey(item) }) : next(e)
    }
    const at = flat.findIndex(item => itemKey(item) === e.element)
    if (at < 0) return {}
    await update($, cursor, () => at)
    return next(e)
  })

  // An arrow in a focused pane scrolls its body a row while the tree is taller than the
  // window, and only walks the ring once it cannot: so the person's single-row scroll
  // moves the cursor instead, and the wheel, the page keys and the pane's own scrolls pass.
  on('ui.scroll', { requestId: PANE }, async ($, e, next) => {
    if (e.origin.kind !== 'person' || e.pointer !== undefined || Math.abs(e.by) !== 1) return next(e)
    const flat = await listed($)
    const at = onList(flat, await read($, cursor))
    await moveTo($, flat, at + e.by)
    return {}
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const list = await read($, rows)
    const viewing = await read($, current)
    const folded = await read($, folds)
    const chord = await read($, pending)
    const written = await read($, writtenAt)
    const ageS = (await nowS($)) - written
    const groups = groupsOf(list, folded, viewing)
    const flat = groups.flatMap(group => group.items)
    const at = onList(flat, await read($, cursor))
    const selected = flat[at]
    const row = selected?.kind === 'row' ? selected.row : undefined
    const section = selected?.kind === 'fold' ? selected.section : row === viewing ? undefined : row?.section
    const fold = section && isFold(section) ? section : undefined
    const heads = groups.map(group => flat.indexOf(group.items[0] as Item))
    const notice =
      written === 0
        ? `claude-inbox is not running: starting ${command} --headless.`
        : ageS > STALE_S
          ? `claude-inbox stopped ${ago(ageS)}; rows are stale.`
          : null

    // The gem's header chips, compact: a glyph and a count per section that has rows.
    const count = (of: (one: InboxRow) => boolean) => list.filter(of).length
    const chips: [number, string, string | undefined][] = [
      [count(one => one.section === 'pinned'), '★', 'cyan'],
      [count(one => one.section === 'needs_you'), '●', 'red'],
      [count(one => one.section === 'active' && one.state === 'working' && !one.isWaiting), '✻', 'yellow'],
      [count(one => one.section === 'active' && one.isWaiting), '◌', 'yellow'],
      [count(one => one.section === 'snoozed'), 'z', 'magenta'],
      [count(one => one.section === 'settled'), '◦', undefined],
    ]

    const onRow = (action: 'settle' | 'wake' | 'pin', verb: string) => () => {
      if (!row?.id || !row.actionable) return $.ui.toast('nothing here can be changed from the pane')
      void ask($, host, { action, id: row.id }).then(() => $.ui.toast(`${verb} ${row.label}`))
    }
    const key = (hotkey: string, onPress: () => void) => <Button key={hotkey} hotkey={hotkey} plain label="" onPress={onPress} />
    // Enter or a click on an item: the cursor lands on it, a fold opens, a row the inbox can
    // attach to asks for the switch.
    const enter = (item: Item) => () => {
      void moveTo($, flat, flat.indexOf(item))
      if (item.kind === 'fold') return void setFold($, list, viewing, item.section, true)
      if (item.row === viewing) return $.ui.toast('you are in this session')
      if (!item.row.id || !item.row.actionable) return $.ui.toast('this session cannot be attached')
      void requestSwitch($, host, item.row.id)
    }

    // Only the keys a chord allows are mounted while it waits, so any other key is a no-op.
    const keys =
      chord === 'g'
        ? [key('g', () => void moveTo($, flat, 0)), key('e', () => void moveTo($, flat, flat.length - 1))]
        : chord === 'z'
          ? [
              key('a', () => void setFold($, list, viewing, fold, fold ? folded[fold] : false)),
              key('o', () => void setFold($, list, viewing, fold, true)),
              key('c', () => void setFold($, list, viewing, fold, false)),
            ]
          : chord === 's'
            ? Object.entries(SNOOZE).map(([digit, { choice, label }]) =>
                key(digit, () => {
                  if (!row?.id || !row.actionable) return $.ui.toast('nothing here can be snoozed')
                  void ask($, host, { action: 'snooze', id: row.id, choice }).then(() => {
                    void update($, pending, () => null)
                    $.ui.toast(`snoozed ${row.label} ${label}`)
                  })
                }),
              )
            : [
                key('j', () => void moveTo($, flat, at + 1)),
                key('k', () => void moveTo($, flat, at - 1)),
                key('g', () => void startChord($, 'g')),
                key('n', () => void moveTo($, flat, heads.find(h => h > at) ?? heads[0] ?? 0)),
                key('p', () => void moveTo($, flat, heads.filter(h => h < at).pop() ?? heads[heads.length - 1] ?? 0)),
                key('z', () => void startChord($, 'z')),
                key('h', () => void setFold($, list, viewing, fold, false)),
                key('l', selected ? enter(selected) : () => undefined),
                key('x', onRow('settle', 'settled')),
                key('u', onRow('wake', 'woke')),
                key('t', onRow('pin', 'pinned')),
                key('s', () => void startChord($, 's')),
                key('c', () => {
                  if (!row?.id) return
                  void $.ui.copy({ text: `claude attach ${row.id}`, surface: e.surface }).then(copied =>
                    $.ui.toast(copied.isCopied ? `copied: claude attach ${row.id}` : 'no clipboard here'),
                  )
                }),
                key('o', () => (row?.pr ? void $.process.run(['open', row.pr.url]) : $.ui.toast('no pull request linked'))),
                key('w', () => (row?.remote ? void $.process.run(['open', row.remote]) : $.ui.toast('no claude.ai/code page for this session'))),
                key('q', () => void $.ui.close({ id: PANE })),
              ]

    return (
      <Box flexDirection="column">
        {/* The engine draws its close mark on a row of its own above the body, so the header can't share it. */}
        <Box columnGap={2}>
          <Text color="cyan" bold>
            claude-inbox
          </Text>
          {chips.filter(([n]) => n > 0).map(([n, glyph, color]) => (
            <Text color={color} dimColor={color === undefined}>
              {glyph} {n}
            </Text>
          ))}
          {list.length === 0 && viewing === null && <Text dimColor>nothing running</Text>}
        </Box>
        {notice !== null && <Text color="yellow">{notice}</Text>}
        {notice === null && flat.length === 0 && <Text dimColor>No sessions.</Text>}
        {groups.map(group => (
          <Box flexDirection="column" marginTop={1}>
            <Text bold dimColor>
              {group.section === null ? 'This session' : `${TITLE[group.section]} · ${list.filter(one => one.section === group.section).length}`}
            </Text>
            {group.items.map(item => {
              const isHere = item === selected
              if (item.kind === 'fold') {
                return (
                  <Box key={viewKey(item)}>
                    <Text color={isHere ? 'yellow' : undefined}>{isHere ? '› ' : '  '}</Text>
                    <Button key={itemKey(item)} plain dimColor label={`▸ ${item.count} folded · za opens`} onPress={enter(item)} autoFocus={isHere || undefined} />
                  </Box>
                )
              }
              const one = item.row
              const isQuiet = isFold(one.section)
              return (
                <Box key={viewKey(item)} flexDirection="column">
                  <Box>
                    <Text color={isHere ? 'yellow' : undefined}>{isHere ? '› ' : '  '}</Text>
                    <Text color={COLOR[one.state]} dimColor={isQuiet || one.state === 'done'}>
                      {GLYPH[one.state] ?? '·'}{' '}
                    </Text>
                    {/* A Button cannot truncate, so its Box clips a long label to the row. */}
                    <Box height={1} flexShrink={1} overflow="hidden">
                      <Button
                        key={itemKey(item)}
                        plain
                        dimColor={isQuiet && !isHere}
                        label={one.wakeAt !== undefined ? `${one.label} · ${wakeLabel(one.wakeAt)}` : one.label}
                        onPress={enter(item)}
                        autoFocus={isHere || undefined}
                      />
                    </Box>
                    {/* The label gives up its cells to the PR chip, which would otherwise wrap under it. */}
                    {one.pr ? (
                      <Box flexShrink={0}>
                        <Text color={isQuiet ? undefined : PR_COLOR[one.pr.state]} dimColor={isQuiet}>
                          {' '}
                          {one.pr.short} {one.pr.state}
                        </Text>
                      </Box>
                    ) : null}
                  </Box>
                  {!isQuiet && one.line !== undefined ? (
                    <Box paddingLeft={4}>
                      <Text dimColor wrap="truncate-end">↳ {one.line}</Text>
                    </Box>
                  ) : null}
                </Box>
              )
            })}
          </Box>
        ))}
        <Box flexDirection="column" marginTop={1}>
          {!e.props.isFocused && <Text dimColor>ctrl+x tab takes you here</Text>}
          {e.props.isFocused && chord === null && <Text dimColor>esc leaves</Text>}
          {e.props.isFocused && chord !== null && (
            <Box flexDirection="column">
              <Text dimColor>{chord}…</Text>
              {MENU[chord].map(([key, what]) => (
                <Text dimColor>
                  {'  '}
                  <Text bold>{key}</Text> {what}
                </Text>
              ))}
            </Box>
          )}
        </Box>
        {/* Drawn nowhere: the hotkeys. */}
        <Box height={0} overflow="hidden">
          {keys}
        </Box>
      </Box>
    )
  })
}
