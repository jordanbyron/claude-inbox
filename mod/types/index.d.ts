export type Section = 'pinned' | 'needs_you' | 'active' | 'snoozed' | 'settled'

// One row of the gem's snapshot.json, as its Snapshot class writes it.
export type InboxRow = {
  section: Section
  id?: string
  label: string
  state: string
  actionable: boolean
  isWaiting: boolean
  isTerminal: boolean
  cwd?: string
  line?: string
  wakeAt?: number | 'until_woken'
  remote?: string
  pr?: { short: string; state: string; url: string }
}

export type Folds = { snoozed: boolean; settled: boolean }

// The first key of a chord (g, z, s) waiting for its second; null between chords.
export type Pending = 'g' | 'z' | 's' | null

declare module 'claude-code' {
  interface PluginState {
    'inbox-pane': { rows: InboxRow[]; writtenAt: number; cursor: number; folds: Folds; pending: Pending; editedAt: number }
  }
}
