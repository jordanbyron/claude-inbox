// What the gem's Snapshot writes for three sessions, a blocked one, a working one
// with an open pull request and a hand-settled one. The gem's spec/mod_spec.rb
// writes the same sessions through Snapshot and compares them to this text, so a
// key renamed on either side fails a test on both.
export const SNAPSHOT = `{
  "version": 1,
  "written_at": 1789600000,
  "sections": {
    "pinned": [],
    "needs_you": [
      {
        "id": "a1",
        "session": "u-a1",
        "label": "needs an answer",
        "state": "blocked",
        "actionable": true
      }
    ],
    "active": [
      {
        "id": "b2",
        "session": "u-b2",
        "label": "still going",
        "state": "working",
        "actionable": true,
        "pr": {
          "short": "#7",
          "state": "open",
          "url": "https://github.com/o/r/pull/7"
        }
      }
    ],
    "snoozed": [],
    "settled": [
      {
        "id": "c3",
        "session": "u-c3",
        "label": "put away",
        "state": "done",
        "actionable": true
      }
    ]
  }
}`
