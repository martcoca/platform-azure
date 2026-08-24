# Packets

Work in this repository is defined by packets. A packet states a Goal, a Boundary, a
Check, and enough context to execute without reading another repository.

## Working order

| # | Packet | Status | Is |
|---|---|---|---|
| 1 | [`0010-E01-T02.md`](0010-E01-T02.md) | done | Consume the released cost guard action and delete this repository's local copies, without losing the Azure Policy agreement check |
| 2 | [`0010-E01-T06.md`](0010-E01-T06.md) | done | Anchor the contract check so a comment cannot satisfy an assertion about a real YAML line |

Take the packet the Founder names. Otherwise take the next one in this table whose
`Status:` is not `done`. The table is the order; the numbers are only identity.

This repository predates the packet convention: the landing zone in `0009` was delivered
before packets existed here. Only work from this point on appears above.

## Rules

- **One packet in flight at a time.** Never widen a packet to absorb the next, and never
  open one pull request covering two.
- **Never edit a packet body.** It is the record of what was asked. If it asks for the
  wrong thing, say so and stop. If a *step* is impossible as written but its intent is
  clear, do the nearest thing that satisfies the intent and say what you changed —
  stopping is for authority, not for difficulty.
- **You may set `Status:`** and nothing else in the file.
- **Run the Check yourself** before opening a pull request.
- **Write `evidence/<packet-id>.md`** and commit it in the same pull request: the Check
  output, what you verified, what you could not, and any decision the packet left to you.
- **If you are blocked, open an issue labelled `blocked`** naming the packet and what you
  need. A blocker mentioned only in conversation does not survive the conversation.
- **Branch, commit, open a pull request.** Never commit to `main`, never merge your own
  work. Auto-merge lands it when every check passes.
- **Stop at anything irreversible or cost-incurring** — cloud apply, provisioning,
  deletion, publishing, spend — and tell the Founder. You hold no such authority. In this
  repository that specifically includes any `tofu apply`, any Azure Policy change, and any
  IAM or OIDC change.

## If no packet applies

Stop and ask. The absence of a packet is information, not an invitation.
