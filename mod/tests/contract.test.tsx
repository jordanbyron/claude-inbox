import { expect, test } from 'claude-code/testing'

import { rowOf } from '../hooks/register'
import type { SnapshotRow } from '../hooks/register'
import type { Section } from '../types'
import { SNAPSHOT } from './snapshot.fixture'

type Fixture = { written_at: number; sections: Record<Section, SnapshotRow[]> }

test("the rows the pane reads are the ones the gem's Snapshot writes", () => {
  const snapshot = JSON.parse(SNAPSHOT) as Fixture
  expect(snapshot.written_at).toBe(1_789_600_000)
  const rows = (Object.keys(snapshot.sections) as Section[]).flatMap(section => snapshot.sections[section].map(one => rowOf(section, one)))
  expect(rows.map(row => [row.section, row.id, row.label, row.state, row.actionable])).toEqual([
    ['needs_you', 'a1', 'needs an answer', 'blocked', true],
    ['active', 'b2', 'still going', 'working', true],
    ['settled', 'c3', 'put away', 'done', true],
  ])
  expect(rows[1]?.pr).toEqual({ short: '#7', state: 'open', url: 'https://github.com/o/r/pull/7' })
  expect(rows[0]?.isWaiting).toBe(false)
})
