export type Section = 'pinned' | 'needs_you' | 'active' | 'snoozed' | 'settled'

// One row of the gem's snapshot.json, as its Snapshot class writes it.
export type InboxRow = {
  section: Section
  id?: string
  // The daemon's sessionId, the name $.session.id() gives the session the pane sits in.
  session?: string
  label: string
  state: string
  actionable: boolean
  isWaiting: boolean
  isUnread: boolean
  line?: string
  wakeAt?: number | 'until_woken'
  remote?: string
  color?: string
  pr?: { short: string; state: string; url: string }
}

export type Folds = { snoozed: boolean; settled: boolean }

// The first key of a chord (g, z, s) waiting for its second; null between chords.
export type Pending = 'g' | 'z' | 's' | null

declare module 'claude-code' {
  interface PluginState {
    // `update` is the gem's notice for a newer release ("v0.6.0 available"), null while this one is the latest.
    'inbox-pane': { rows: InboxRow[]; current: InboxRow | null; writtenAt: number; update: string | null; cursor: number; folds: Folds; pending: Pending }
  }
}
