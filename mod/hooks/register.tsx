import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Folds, InboxRow, Pending, Section } from '../types'

const PANE = 'inbox'
const POLL_MS = 1000
// Older than this and the writer has quit: it rewrites every 5 s even when nothing changed.
const STALE_S = 30
// How long a headless start gets to produce a fresh snapshot before another is tried.
const RESTART_S = 60
// A chord's first key waits this long for its second.
const CHORD_MS = 5000
// How long an attached inbox gets to take a switch request before the pane gives up on it.
const SWITCH_MS = 3000
// The gem's files, under HOME. The snapshot is read; state.json and switch.json take the pane's writes.
const SNAPSHOT = '.config/claude-inbox/snapshot.json'
const GEM_STATE = '.config/claude-inbox/state.json'
const SWITCH = '.config/claude-inbox/switch.json'
const rows = atom({ plugin: 'inbox-pane', key: 'rows' } as const, [])
const writtenAt = atom({ plugin: 'inbox-pane', key: 'writtenAt' } as const, 0)
const cursor = atom({ plugin: 'inbox-pane', key: 'cursor' } as const, 0)
const folds = atom({ plugin: 'inbox-pane', key: 'folds' } as const, { snoozed: true, settled: true })
const pending = atom({ plugin: 'inbox-pane', key: 'pending' } as const, null)
// When the pane last wrote state.json, in ms: a snapshot older than that still shows the row where it was.
const editedAt = atom({ plugin: 'inbox-pane', key: 'editedAt' } as const, 0)

type SnapshotRow = {
  id?: string
  label?: string
  state?: string
  actionable?: boolean
  waiting?: boolean
  terminal?: boolean
  cwd?: string
  line?: string
  wake_at?: number | 'until_woken'
  remote?: string
  pr?: { short?: string; state?: string; url?: string }
}
type Snapshot = { written_at?: number; sections?: Partial<Record<Section, SnapshotRow[]>> }
// One entry of state.json, the keys the gem's Store::Entry writes.
type Entry = {
  pinned?: boolean
  pinned_at?: number
  wake_at?: number | 'until_woken'
  snoozed_at?: number
  settled_at?: number
  revived_at?: number
  state_since?: number
}
type GemState = { version: number; sessions: Record<string, Entry> }
// The headless inbox this module may start: which command, and whether one of ours is up.
type Headless = { command: string; startedAt: number; isRunning: boolean }
type Fold = 'snoozed' | 'settled'
type Item = { kind: 'row'; row: InboxRow } | { kind: 'fold'; section: Fold; count: number }
type Snooze = 'm15' | 'h1' | 'tomorrow_9am' | 'until_woken'
// Where a row lands right after an edit here, before the snapshot confirms it.
type Landing = { section: Section; wakeAt?: number | 'until_woken' }

const ORDER: Section[] = ['pinned', 'needs_you', 'active', 'snoozed', 'settled']
const TITLE: Record<Section, string> = { pinned: 'Pinned', needs_you: 'Needs you', active: 'Active', snoozed: 'Snoozed', settled: 'Settled' }
const NEEDS_YOU = new Set(['blocked', 'failed'])
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
const MENU: Record<'g' | 'z' | 's', [string, string][]> = {
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

// The hidden Button standing for an item: the ring walks these with the arrows.
function itemKey(item: Item): string {
  return item.kind === 'fold' ? `fold:${item.section}` : `row:${item.row.id ?? item.row.label}`
}

// The visible box drawn for an item, what the pane scrolls to.
function viewKey(item: Item): string {
  return `view:${itemKey(item)}`
}

function groupsOf(list: InboxRow[], folded: Folds): { section: Section; items: Item[] }[] {
  return ORDER.flatMap(section => {
    const own = list.filter(row => row.section === section)
    if (own.length === 0) return []
    const items: Item[] = isFold(section) && folded[section] ? [{ kind: 'fold', section, count: own.length }] : own.map(row => ({ kind: 'row', row }))
    return [{ section, items }]
  })
}

async function readJson<T>($: EngineInterface, path: string, fallback: T): Promise<T> {
  try {
    return JSON.parse(await $.fs.read(path)) as T
  } catch {
    return fallback
  }
}

function rowOf(section: Section, one: SnapshotRow): InboxRow {
  const pr = one.pr?.short && one.pr.url ? { short: one.pr.short, state: one.pr.state ?? '', url: one.pr.url } : undefined
  return {
    section,
    id: one.id,
    label: one.label ?? one.id ?? '',
    state: one.state ?? 'unknown',
    actionable: one.actionable === true,
    isWaiting: one.waiting === true,
    isTerminal: one.terminal === true,
    cwd: one.cwd,
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

async function nowS($: EngineInterface): Promise<number> {
  return Math.floor((await $.clock.now()) / 1000)
}

// Store::Entry.snooze_until, so a snooze set here wakes when the gem's would.
function wakeAt(choice: Snooze, now: number): number | 'until_woken' {
  if (choice === 'm15') return now + 15 * 60
  if (choice === 'h1') return now + 3600
  if (choice === 'until_woken') return 'until_woken'
  const at = new Date(now * 1000)
  at.setHours(9, 0, 0, 0)
  if (at.getTime() / 1000 <= now) at.setDate(at.getDate() + 1)
  return Math.floor(at.getTime() / 1000)
}

const MUTATE: Record<'settle' | 'wake' | 'pin', (entry: Entry, now: number) => void> = {
  settle: (entry, now) => {
    entry.settled_at = now
    delete entry.wake_at
    delete entry.snoozed_at
    delete entry.revived_at
  },
  wake: (entry, now) => {
    delete entry.wake_at
    delete entry.snoozed_at
    delete entry.settled_at
    entry.revived_at = now
  },
  pin: (entry, now) => {
    if (entry.pinned) {
      delete entry.pinned
      delete entry.pinned_at
    } else {
      entry.pinned = true
      entry.pinned_at = now
    }
  },
}

// Where Store::Row#section puts a row once each edit lands.
function landingOf(row: InboxRow, action: 'settle' | 'wake' | 'pin'): Landing {
  const plain: Section = NEEDS_YOU.has(row.state) ? 'needs_you' : 'active'
  if (action === 'settle') return { section: 'settled' }
  if (action === 'wake') return { section: plain }
  return { section: row.section === 'pinned' ? plain : 'pinned' }
}

// The gem's Store::Entry mutators, applied to its file; the gem reads it back as soon as it changes.
// The row moves here at once, and the next snapshot has the gem's word on it.
async function edit($: EngineInterface, id: string, change: (entry: Entry, now: number) => void, landing: Landing): Promise<void> {
  const home = (await $.env.get('HOME')) ?? ''
  const gem = await readJson<Partial<GemState>>($, `${home}/${GEM_STATE}`, {})
  const sessions = gem.sessions ?? {}
  const now = await nowS($)
  const entry = sessions[id] ?? (sessions[id] = { state_since: now })
  change(entry, now)
  await $.fs.write(`${home}/${GEM_STATE}`, JSON.stringify({ version: gem.version ?? 1, sessions }))
  await update($, editedAt, () => now * 1000).catch(() => undefined)
  // Best effort: the snapshot brings the gem's own placement within a second anyway.
  await update($, rows, list => (list ?? []).map(row => (row.id === id ? { ...row, section: landing.section, wakeAt: landing.wakeAt } : row))).catch(
    () => undefined,
  )
}

// Asks the inbox holding the terminal to attach to `id`. It takes the file when it
// does; a file still there after SWITCH_MS means no inbox is attached to take it.
async function requestSwitch($: EngineInterface, id: string): Promise<void> {
  const home = (await $.env.get('HOME')) ?? ''
  const path = `${home}/${SWITCH}`
  await $.fs.write(path, JSON.stringify({ id, at: await nowS($) }))
  $.ui.toast(`switching to ${id}…`)
  $.clock.after(SWITCH_MS, () => {
    void $.fs.exists(path).then(async isStillThere => {
      if (!isStillThere) return
      await $.fs.write(path, '')
      $.ui.toast('no inbox is attached to switch: run claude-inbox, attach from it, and press Enter here')
    })
  })
}

// One headless inbox per machine: the gem holds a lock, so a second start exits at once.
function startHeadless($: EngineInterface, headless: Headless, now: number): void {
  if (headless.isRunning || now - headless.startedAt < RESTART_S) return
  headless.startedAt = now
  headless.isRunning = true
  void (async () => {
    try {
      const child = $.process.spawn({ argv: [headless.command, '--headless'] })
      for await (const piece of child) {
        if ('text' in piece) $.ui.log(`${headless.command} --headless: ${piece.text.trim()}`, { to: 'debug' })
      }
    } catch (error) {
      $.ui.log(`${headless.command} --headless did not start: ${String(error)}`, { to: 'debug' })
    } finally {
      headless.isRunning = false
    }
  })()
}

async function poll($: EngineInterface, headless: Headless): Promise<void> {
  const home = (await $.env.get('HOME')) ?? ''
  const now = await nowS($)
  const path = `${home}/${SNAPSHOT}`
  const snapshot = await readJson<Snapshot | null>($, path, null)
  const written = snapshot?.written_at ?? 0
  // A snapshot from before the pane's last edit would put the row back where it was; the gem's
  // next write, within a second or two, carries the edit.
  const mtimeMs = snapshot === null ? 0 : await $.fs.stat(path).then(stat => stat.mtimeMs).catch(() => 0)
  if (snapshot !== null && mtimeMs > (await read($, editedAt))) {
    await update($, rows, () => ORDER.flatMap(section => (snapshot.sections?.[section] ?? []).map(one => rowOf(section, one))))
  }
  await update($, writtenAt, () => written)
  if (now - written > STALE_S) startHeadless($, headless, now)
}

// Puts the ring on the item's hidden Button, so Enter acts on it, and scrolls it into view.
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

async function setFold($: EngineInterface, list: InboxRow[], name: Fold | undefined, open: boolean): Promise<void> {
  await update($, pending, () => null)
  if (!name) return
  const folded = await update($, folds, f => ({ ...(f ?? { snoozed: true, settled: true }), [name]: !open }))
  // The item under the cursor may have just become a fold, or the fold its rows.
  const flat = groupsOf(list, folded).flatMap(group => group.items)
  const at = flat.findIndex(item => (item.kind === 'fold' ? item.section : item.row.section) === name)
  if (at >= 0) await moveTo($, flat, at)
}

async function startChord($: EngineInterface, key: Pending): Promise<void> {
  await update($, pending, () => key)
  $.clock.after(CHORD_MS, () => void update($, pending, now => (now === key ? null : now)))
}

export const register: Register = (on, options) => {
  const command = typeof options.command === 'string' && options.command !== '' ? options.command : 'claude-inbox'
  const headless: Headless = { command, startedAt: 0, isRunning: false }

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'inbox', description: 'Open the inbox of background sessions' })
    const started = await next(e)
    // A pinned line outlives a reload, so an earlier version's is cleared here.
    $.ui.status(undefined)
    void poll($, headless)
    $.clock.every(POLL_MS, () => void poll($, headless))
    const opened = await $.ui.open({ id: PANE, title: 'Inbox', columns: 48 })
    if (!opened.isPlaced) $.ui.log(`inbox: /inbox opens the pane (${opened.reason})`, { to: 'debug' })
    return started
  })

  on('command.run', { command: 'inbox' }, async $ => {
    void poll($, headless)
    const opened = await $.ui.open({ id: PANE, title: 'Inbox', focus: true, columns: 48 })
    const surfaces = (await $.session.surfaces()).join(', ') || 'none'
    if (!opened.isPlaced) return { text: `Inbox pane not drawn: ${opened.reason}. Surfaces: ${surfaces}.` }
    return { text: `Inbox pane open on ${surfaces}. ctrl+x tab focuses it; the keys are claude-inbox's.` }
  })

  // The ring walks the items' hidden Buttons and nothing else: entering the pane it lands on
  // the cursor's item, the arrows move it to the next, and the cursor follows.
  on('ui.focus', { requestId: PANE }, async ($, e, next) => {
    const flat = groupsOf(await read($, rows), await read($, folds)).flatMap(group => group.items)
    if (e.element === undefined) {
      const item = flat[Math.min(await read($, cursor), Math.max(0, flat.length - 1))]
      return item ? next({ ...e, element: itemKey(item) }) : next(e)
    }
    const at = flat.findIndex(item => itemKey(item) === e.element)
    if (at < 0) return {}
    await update($, cursor, () => at)
    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const list = await read($, rows)
    const folded = await read($, folds)
    const chord = await read($, pending)
    const written = await read($, writtenAt)
    const ageS = (await nowS($)) - written
    const groups = groupsOf(list, folded)
    const flat = groups.flatMap(group => group.items)
    const at = Math.min(await read($, cursor), Math.max(0, flat.length - 1))
    const selected = flat[at]
    const row = selected?.kind === 'row' ? selected.row : undefined
    const section = selected?.kind === 'fold' ? selected.section : row?.section
    const fold = section && isFold(section) ? section : undefined
    const heads = groups.map(group => flat.indexOf(group.items[0] as Item))
    const notice =
      written === 0
        ? `claude-inbox is not running: starting ${command} --headless.`
        : ageS > STALE_S
          ? `claude-inbox stopped ${Math.floor(ageS / 60)}m ago; rows are stale.`
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
      void edit($, row.id, MUTATE[action], landingOf(row, action)).then(() => $.ui.toast(`${verb} ${row.label}`))
    }
    const key = (hotkey: string, onPress: () => void) => <Button key={hotkey} hotkey={hotkey} plain label="" onPress={onPress} />
    // Enter on an item: a fold opens, a row asks the attached inbox to switch to it.
    const enter = (item: Item) => () => {
      if (item.kind === 'fold') return void setFold($, list, item.section, true)
      if (item.row.id) void requestSwitch($, item.row.id)
    }

    // Only the keys a chord allows are mounted while it waits, so any other key is a no-op.
    const keys =
      chord === 'g'
        ? [key('g', () => void moveTo($, flat, 0)), key('e', () => void moveTo($, flat, flat.length - 1))]
        : chord === 'z'
          ? [
              key('a', () => void setFold($, list, fold, fold ? folded[fold] : false)),
              key('o', () => void setFold($, list, fold, true)),
              key('c', () => void setFold($, list, fold, false)),
            ]
          : chord === 's'
            ? Object.entries(SNOOZE).map(([digit, { choice, label }]) =>
                key(digit, () => {
                  if (!row?.id || !row.actionable) return $.ui.toast('nothing here can be snoozed')
                  const snooze = (entry: Entry, now: number) => {
                    entry.wake_at = wakeAt(choice, now)
                    entry.snoozed_at = now
                  }
                  void nowS($).then(now =>
                    edit($, row.id ?? '', snooze, { section: 'snoozed', wakeAt: wakeAt(choice, now) }).then(() => {
                      void update($, pending, () => null)
                      $.ui.toast(`snoozed ${row.label} ${label}`)
                    }),
                  )
                }),
              )
            : [
                key('j', () => void moveTo($, flat, at + 1)),
                key('k', () => void moveTo($, flat, at - 1)),
                key('g', () => void startChord($, 'g')),
                key('n', () => void moveTo($, flat, heads.find(h => h > at) ?? heads[0] ?? 0)),
                key('p', () => void moveTo($, flat, heads.filter(h => h < at).pop() ?? heads[heads.length - 1] ?? 0)),
                key('z', () => void startChord($, 'z')),
                key('h', () => void setFold($, list, fold, false)),
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
        {/* The header shares the pane's top row with the engine's close mark, which takes the last cells. */}
        <Box columnGap={2} paddingRight={3}>
          <Text color="cyan" bold>
            claude-inbox
          </Text>
          {chips.filter(([n]) => n > 0).map(([n, glyph, color]) => (
            <Text color={color} dimColor={color === undefined}>
              {glyph} {n}
            </Text>
          ))}
          {list.length === 0 && <Text dimColor>nothing running</Text>}
        </Box>
        {notice !== null && <Text color="yellow">{notice}</Text>}
        {notice === null && flat.length === 0 && <Text dimColor>No sessions.</Text>}
        {groups.map(group => (
          <Box flexDirection="column" marginTop={1}>
            <Text bold dimColor>
              {TITLE[group.section]} · {list.filter(one => one.section === group.section).length}
            </Text>
            {group.items.map(item => {
              const isHere = item === selected
              if (item.kind === 'fold') {
                return (
                  <Box key={viewKey(item)}>
                    <Text color={isHere ? 'yellow' : undefined}>{isHere ? '› ' : '  '}</Text>
                    <Text dimColor>▸ {item.count} folded · za opens</Text>
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
                    <Text bold={isHere} dimColor={isQuiet && !isHere} wrap="truncate-end">
                      {one.label}
                      {one.wakeAt !== undefined ? ` · ${wakeLabel(one.wakeAt)}` : ''}
                    </Text>
                    {one.pr ? (
                      <Text color={isQuiet ? undefined : PR_COLOR[one.pr.state]} dimColor={isQuiet}>
                        {' '}
                        {one.pr.short} {one.pr.state}
                      </Text>
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
        {/* Drawn nowhere: one Button per item for the ring and Enter, then the hotkeys. */}
        <Box height={0} overflow="hidden">
          {flat.map(item => (
            <Button key={itemKey(item)} plain label="" onPress={enter(item)} />
          ))}
          {keys}
        </Box>
      </Box>
    )
  })
}
