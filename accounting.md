# Accounting, for engineers

*Everything you need to understand Ledgerline's ledger, in plain language. No accounting
background assumed.*

If a term is missing, it is probably in the glossary at the end.

---

## 1. The one idea

Accounting answers two questions about the same money:

1. **What do we have?** (assets)
2. **Who does it belong to?** (liabilities, and us)

Every concept below is a consequence of the fact that those two answers must always agree.

If we hold $4,975 in the bank and $4,750 of it belongs to a merchant, then $225 belongs to
us. If those numbers ever stop adding up, something is wrong — and the whole discipline
exists to make that impossible to hide.

---

## 2. The five kinds of account

Everything in a ledger is one of five types. Ours map like this:

| Type | Plain English | Our accounts |
|---|---|---|
| **Asset** | What we have, or are owed | `bank:master`, `psp:receivable` |
| **Liability** | What we owe someone else | `merchant:*:pending`, `merchant:*:available` |
| **Equity** | What belongs to us, after liabilities | (implicit — see §10) |
| **Revenue** | What we earned | `revenue:platform_fee` |
| **Expense** | What it cost us | `expense:processor_fee` |

Two questions to classify anything:

- *Is it ours, or someone else's?* → asset vs liability
- *Is it a stock (a balance) or a flow (something that happened)?* → balance sheet vs
  income statement

Assets and liabilities are **stocks** — they exist at a point in time. Revenue and expenses
are **flows** — they accumulate over a period. That distinction is why you can ask "what's the
bank balance?" but not really "what's the revenue balance?" without a date range.

---

## 3. Debits and credits, demystified

This is the concept everyone trips on, and it's genuinely simple once the framing is right.

**Every account has two sides: a left side and a right side.**

- Left = **debit** (Dr)
- Right = **credit** (Cr)

They are just sides. Debit does not mean good. Credit does not mean money you can spend.

Whether a debit *increases* or *decreases* an account depends on the account's type:

| Account type | Debit does | Credit does |
|---|---|---|
| Asset | increases ↑ | decreases ↓ |
| Expense | increases ↑ | decreases ↓ |
| Liability | decreases ↓ | increases ↑ |
| Revenue | decreases ↓ | increases ↑ |
| Equity | decreases ↓ | increases ↑ |

Mnemonic: **DEAD CLIC** — Debits increase Expenses, Assets, Drawings; Credits increase
Liabilities, Income, Capital.

### Reading it as a sentence

> "Debit the bank, credit the merchant."

means: the bank account goes up, the merchant's balance goes up. Money arrived, and we now owe
more. Both are increases, on opposite sides, because one is an asset and one is a liability.

### Why an entry always nets to zero

Because a debit and a credit are the same amount entered on opposite sides. If you write +500
to one account and −500 to another under a signed convention, the sum is zero. That's the
whole rule.

**Software convention we use:** signed amounts, where **positive = debit** and
**negative = credit**. So `sum(amount) = 0` per entry. It's the same rule as the two-column
version, just easier to add up.

---

## 4. The accounting equation

```
Assets = Liabilities + Equity
```

In plain words: **everything we have is either owed to someone else or belongs to us.**

This is not a rule imposed on the data — it is an identity. If it ever fails, something was
mis-recorded, and double-entry makes that failure loud instead of silent.

Our version, after a payment settles:

```
bank 4,975  =  merchant available 4,750  +  our margin 225
```

---

## 5. Journal entries and lines

A **journal entry** is one event: "capture ORD-1234", "settle batch 4471".

A **journal line** is one leg of that event: an amount applied to one account.

```
journal entry 901  (payment, ORD-1234)
  line 1   psp:receivable        +5000
  line 2   merchant:42:pending   −4750
  line 3   revenue               −250
                                 ─────
                                     0
```

The entry header carries *what happened and when*. The lines carry *how it affected each
account*. This is why the header has no amounts: an event can touch three accounts, or five.

**Minimum two lines per entry.** Sometimes more. Never one.

---

## 6. Why double-entry

A single-sided ledger records one effect: "merchant balance += 47.50". It cannot tell you
*where that money came from*, and it cannot detect its own errors.

Double-entry forces you to state both sides, which gives you:

- **Self-checking.** The entry must net to zero, or it doesn't commit.
- **Provability.** Any balance is the sum of lines that explain it.
- **No money creation.** You cannot conjure a balance without saying what funded it.
- **A place for in-transit money.** See §8.
- **Auditability.** The journal is a chronological, complete record.

The cost: more rows, and balances become sums. Worth it for anything holding other people's
money.

---

## 7. Accrual vs cash accounting

The distinction that explains most "why is this booked now?" confusion.

**Cash accounting:** record it when money moves.
**Accrual accounting:** record it when the obligation arises, regardless of cash.

We use accrual, because we must know what we owe the moment we accept a payment — not two
days later when the processor pays us.

| Moment | What is true | What we record |
|---|---|---|
| Capture | We will be paid; we owe the merchant | Receivable, liability, revenue |
| Settlement | Cash actually arrived | Convert receivable to bank; recognise cost |

Consequence: **there is always a period where we are owed money and owe money, before any
cash moves.** Those are the receivable and payable accounts, and they are not errors.

---

## 8. Clearing and suspense accounts

Two similar ideas, both about money that is somewhere in between.

**Clearing account** — a known, temporary holding account used to move money between two
places. `psp:receivable` is effectively a clearing account: money that left the processor's
books and hasn't arrived on ours. It should return to zero regularly.

**Suspense account** — where you park money you cannot yet explain. An orphan bank credit
(money arrived that no batch claims) belongs here until someone resolves it. A suspense
balance is always a red flag; it should be empty and watched.

Rule of thumb: **clearing accounts have a deadline, suspense accounts have an owner.** If a
balance in either is old, that's a finding.

---

## 9. Buckets: pending, available, reserved

A custodian rarely has a single "balance" per customer. It has states, because money can be
real but not yet usable.

| Bucket | Meaning | Ours |
|---|---|---|
| **Pending credit** | Incoming, not yet final | `merchant:<id>:pending` |
| **Available** | Withdrawable now | `merchant:<id>:available` |
| **Reserved / pending debit** | Promised to an outgoing payment | `payout:<id>:pending` (v1.1) |

The move from pending to available is a real journal entry, not a status flag update:

```
merchant:pending    +4750   (clear the old bucket)
merchant:available  −4750   (fill the new one)
```

Why bother? Because a status flag on a row is easy to change and impossible to audit, whereas
a journal entry is dated, attributable, and reversible.

---

## 10. Equity, and where "our money" lives

Equity is the residual: `Assets − Liabilities`. It's what's left for the owners.

We have no explicit equity account, because revenue and expense do the job — revenue
increases equity, expense decreases it. Our margin of 225 is simply:

```
revenue 250 − expense 25 = 225
```

If you wanted that money visible as a separate pot (for example, to prove merchant funds and
platform funds are held separately), you'd add `equity:platform_funds` and transfer into it
at settlement. That's a reporting refinement, not a correctness requirement.

---

## 11. Immutability and corrections

Posted entries are **never edited or deleted**. Not because it's inconvenient, but because
the journal is evidence.

To fix a mistake, you **post a reversing entry** and then the correct one. The mistake stays
visible, dated, and attributable — which is exactly what an auditor wants.

```
wrong:     revenue −250        (should have been −200)
reversal:  revenue +250
correct:   revenue −200
```

This is why our entries have `kind = 'adjustment'` and why the audit log is hash-chained.
Corrections are normal. Silent edits are fraud-adjacent.

**Corollary:** make the tables append-only. Reject `UPDATE` and `DELETE` at the database
level; the rule then holds even for code you haven't written yet.

---

## 12. Materiality

Not every discrepancy is worth chasing.

**Material** means large enough to change a decision. A 2-cent FX rounding difference on a
1,000-cent payment is immaterial; a missing 5,000-cent payout is not.

This is why the auto-heal rules in this project are narrow and explicit: timing differences
within a weekend, FX residuals under a threshold, duplicated lines where one is provably a
copy. Everything else goes to a human.

Materiality is a judgement encoded as a threshold, and the threshold should be a config
value, not a constant buried in code.

---

## 13. Period close and reconciliation

**Period close** — declaring "the books for October are final". After close, you don't post
into that period; you post into the next one. It gives everyone a stable number to report on.

**Reconciliation** — proving that two independent records of the same thing agree. Not
"checking the books balance" (they always do, by construction) but comparing *our* books
against *someone else's* record:

| Reconciliation | Compares | Question |
|---|---|---|
| Bank rec | our cash account vs the bank statement | did every payment we recorded actually arrive? |
| Processor rec | our settlements vs the settlement file | did they pay us for everything we captured? |
| Trial balance | total debits vs total credits | are the books internally consistent? |
| Merchant rec | our liability vs what merchants say they're owed | do they agree with our subledger? |

The first two are what this project does. The trial balance is what the database enforces.

---

## 14. Multi-currency

Three ideas:

- **Transaction currency** — the currency the payment was made in (NZD).
- **Base currency** — the currency your books are kept in.
- **FX gain/loss** — when the rate moves between when you recorded and when you settled.

And the one that bites every time: **currencies have different numbers of decimals.** NZD has
2, JPY has 0, KWD has 3. Money is stored as an integer in minor units with an explicit
exponent per currency — never a float, never an assumption of two decimals.

v1 avoids conversion entirely: one currency per account. Conversion is a separate problem
with its own accounts and its own losses.

---

## 15. How this maps to our schema

| Concept | Where it lives |
|---|---|
| Account types, chart of accounts | `accounts.type`, `accounts.purpose` |
| Event | `journal_entries` |
| Debit/credit legs | `journal_lines` (signed, sum zero) |
| Balance rule enforcement | deferred constraint trigger |
| Balances | `SUM(journal_lines)` per account |
| Pending / available buckets | separate liability accounts per merchant |
| Clearing account (in transit) | `psp:receivable` |
| Immutable history | append-only tables + hash-chained audit log |
| Corrections | `kind = 'adjustment'` entries, never edits |
| External records | `settlement_files` / `settlement_lines`, `bank_statements` / `bank_lines` |

---

## 16. Pitfalls worth naming

1. **Storing balances without being able to prove them.** A cached balance is correct
   engineering; a cached balance with no rebuild-and-compare job is a future incident. Keep
   the journal authoritative and the cache disposable.
2. **Editing posted entries.** Every "quick fix" becomes an unexplainable number.
3. **Floats for money.** Rounding is not a display problem, it is a correctness problem.
4. **One fee.** There are at least two — what you charge and what you're charged.
5. **Assuming the ledger equals the settlement file.** It only does when the fees match.
6. **Treating revenue as a liability.** Revenue is ours; nothing is owed back.
7. **Parsing account codes.** Put semantics in columns.
8. **Creating money with a single-sided insert.** If a balance can appear without a
   counterpart, the invariant is decorative.
9. **No suspense account.** Unexplained money then gets force-fitted somewhere wrong.
10. **Reconciling to your own books.** That's a trial balance, not a reconciliation.

---

## 17. Glossary

| Term | Meaning |
|---|---|
| **Accrual** | Recording when the obligation arises, not when cash moves |
| **Asset** | What we have or are owed |
| **Balance sheet** | Statement of assets, liabilities and equity at a moment |
| **Clearing account** | Temporary account for money in transit; should return to zero |
| **Contra account** | An account that offsets another (e.g. refunds against revenue) |
| **Credit** | The right-hand side of an account |
| **Debit** | The left-hand side of an account |
| **Double-entry** | Every entry has two or more sides that sum to zero |
| **Equity** | Residual: assets minus liabilities |
| **Expense** | A cost incurred |
| **FX gain/loss** | Difference caused by exchange rate movement |
| **General ledger** | The full set of accounts |
| **Immaterial** | Too small to change a decision |
| **Journal entry** | One event, recorded as two or more lines |
| **Liability** | What we owe someone else |
| **Materiality** | The threshold above which a difference matters |
| **Minor units** | Integer representation of money (cents) |
| **Period close** | Freezing a period so it can be reported |
| **Posting** | The act of recording a line into an account |
| **Reconciliation** | Proving two independent records agree |
| **Reserve** | Funds withheld against risk |
| **Revenue** | Income earned |
| **Reversal** | An entry that undoes a previous one |
| **Subledger** | A detailed ledger per customer, summarised into the general ledger |
| **Suspense account** | Where unexplained money waits for an owner |
| **Trial balance** | Sum of all debits vs all credits; must be equal |
