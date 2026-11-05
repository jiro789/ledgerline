# How money moves

*A plain-language walkthrough of card payments, from someone tapping a card to a reconciler
asking "where is my $9.70?"*

If you have never worked in payments, read this first. Everything in the codebase is a
consequence of the flows described here.

For the accounting side — debits, credits, accrual, clearing accounts — see
[accounting.md](accounting.md).

---

## The short version

1. A customer pays a merchant. **No money moves yet** — only a hold on their card.
2. Companies between them (banks, a card network, a processor) agree the payment is real.
3. Days later, money actually moves **between banks**, in one lump sum covering hundreds of
   transactions.
4. Everyone in the chain takes a cut before the money reaches the merchant.
5. By the time the merchant is paid, the original $10.00 has been recorded in three separate
   places, at three different times, with three different numbers.

Reconciling those three records is the entire product.

---

## The cast

| Who | Plain English | Role in the money |
|---|---|---|
| **Payer** | The customer with the card | Their bank is the source of the funds |
| **Issuer** | The payer's bank (issued their card) | Holds the customer's money; pays out on their behalf |
| **Card network** | Visa, Mastercard | Sets the rules and moves messages between banks |
| **Acquirer** | The bank on the merchant's side | Receives the money and passes it down the chain |
| **Processor (PSP)** | Stripe, Adyen, Windcave | The software layer on top of the acquirer that we talk to |
| **Us (the platform)** | A payment facilitator | We take payments for many merchants and hold their money briefly |
| **Master account** | Our bank account | Where every merchant's money physically lands |
| **Merchant** | The shop. **Our customer.** | Is owed money by us |
| **Merchant's bank** | Where the merchant's own account sits | Receives our payout, eventually |

Two words get used loosely and it's worth being exact from the start:

- **Settlement** = money moving between banks. The acquirer pays us.
- **Payout** = us paying a merchant. That's a separate step, and out of scope for v1.

---

## One payment, from tap to bank account

```
PAYER ──tap──► MERCHANT ──► US ──► PROCESSOR ──► CARD NETWORK ──► ISSUER
                                                                    │
                          (1) authorisation: "is there money?"  ◄──┘
                                   nothing moves, only a hold
```

Then later, in the other direction:

```
ISSUER ──► CARD NETWORK ──► ACQUIRER/PROCESSOR ──► OUR MASTER ACCOUNT ──► MERCHANT
              (3) settlement, in bulk              (4) payout, later
```

### Step by step

**1. Authorisation — happens in about a second.**
The payer taps. The message travels payer → merchant → us → processor → network → issuer.
The issuer checks the card is real and the money is available, and places a **hold**. It
replies "approved". **No money moves.** If you look at any account at this moment, nothing
has changed.

**2. Capture — we record it.**
The processor captures the authorised payment, usually automatically. This is the first
moment it becomes real enough for us to book: we write a row in **our ledger**, because we
now owe the merchant money.

**3. Clearing — the arithmetic happens.**
The two banks exchange the details of the transaction. This is where the fees are worked
out: how much goes to the issuer, how much to the card network, how much the acquirer keeps.
Still no money has moved.

**4. Settlement — money moves between banks, in bulk.**
Once or twice a day the acquirer closes a **settlement window**. Everything captured since
the last one goes into a batch. The acquirer receives the funds from the issuers, deducts
its fees, and sends us **one transfer** for the batch total. This is when our master account
is credited.

**5. Funding lag.**
That transfer arrives on a delay — commonly T+1 to T+3 days. "T" is the capture date.
Weekends and public holidays push it further. This delay is the source of most "timing"
confusion.

**6. The bank statement.**
Our bank sends a statement (daily or monthly) listing what actually landed. **This is the
proof.** Everything before it is somebody's claim.

**7. Reconciliation — our job.**
We compare: what we think happened (ledger), what the processor says it is paying us
(settlement file), and what actually arrived (bank statement).

**8. Payout — not in v1.**
We pay the merchant, usually on a schedule of their choosing. Out of scope, but it is why we
are holding their money in the first place.

---

## Where the money is at each moment

| Step | Who physically holds the funds | Can we see it? |
|---|---|---|
| Authorisation | Nobody. A hold on the payer's account | No |
| Capture | Nobody. A promise | Only in our ledger |
| Clearing | Nobody. The numbers are now agreed | Only in the settlement file |
| Settlement | Acquirer → **our master account** | Bank statement |
| Payout | Merchant's bank | No — out of scope |

The important consequence: **we only ever see the money at the moment it lands in our own
account.** Everything else is records of promises.

That is also why this project models a *facilitator*. A software vendor with no custody never
sees a bank statement. A direct acquirer paying straight into each merchant's account never
sees one either. Only a platform holding funds in a master account has all three records in
one place — which is what makes three-way reconciliation possible at all.

---

## Why there are three records

| Record | Written by | Says | Trust level |
|---|---|---|---|
| `ledger_entries` | us, at capture | "we believe this happened" | our claim |
| `settlement_lines` | processor, daily | "this is what we will pay you" | their claim |
| `bank_lines` | our bank | "this is what arrived" | **fact** |

Three claims, three timings, three levels of detail. Reconciliation is deciding which one is
wrong when they disagree.

---

## Where the fees go

A $10.00 payment does not deliver $10.00 to anyone. Four parties take a cut:

```
$10.00  gross
  −0.18  interchange        → the payer's bank (issuer). Set by the card network.
  −0.04  scheme fee         → Visa / Mastercard
  −0.03  acquirer margin    → the processor's own cut
  ─────
  $9.75  arrives in our master account

  −0.30  our platform fee   → what we charge the merchant
  ─────
  $9.45  owed to the merchant
  $0.05  our margin (0.30 charged − 0.25 paid to the processor)
```

The first three cuts are invisible to us individually. The processor bundles them into a
single number, which is what we see as **the processor fee**. That bundling is also why
"interchange++" pricing exists: it itemises those three so you can argue about them.

**Mechanically, the fee is never invoiced — it is deducted.** The acquirer is holding the
money at settlement, so it simply remits less. That is why you cannot refuse it, and why the
settlement file has gross, fee, and net on every line. The file is the receipt for a
deduction you never saw happen.

Some processors do settle **gross** instead, then bill you monthly. Then the fee arrives as a
separate debit weeks later. Same economics, different plumbing — and one more thing to
reconcile.

---

## Two fees, not one

The single most common modelling mistake in payment platforms is treating "the fee" as one
thing. There are two, they move in opposite directions, and the difference between them is
your business.

| Fee | Who charges it | Who pays it | Where it lives |
|---|---|---|---|
| **Processor fee** | the processor | **us** | `settlement_lines.fee_minor` — a cost |
| **Platform fee** | us | the merchant | `ledger_entries` with `kind = 'fee'` — revenue |

The ledger records **what we owe the merchant**. The settlement file records **what we will
receive**. They are different numbers by design.

### Worked example

$10.00 payment. We charge the merchant 3%. The processor charges us 25c.

```
gross                      1000
platform fee (3%)           −30   → merchant is owed 970
processor fee               −25   → we receive 975

975 received − 970 owed = 5   ← our margin
```

Move the processor's cut and the margin flips:

| processor fee | we receive | merchant owed | margin |
|---|---|---|---|
| 25c | 975 | 970 | **+5** |
| 30c | 970 | 970 | 0 |
| 35c | 965 | 970 | **−5** |

At 35c we paid five cents for the privilege of processing the payment. That is not something
to discover in a monthly invoice. It is arithmetic, per transaction, and it belongs in a
report with an alarm on the negative cases.

### Caps quietly destroy margin on small tickets

A "3% capped at 25c" schedule looks merchant-friendly and is brutal on low-value payments,
because the processor's fixed cost dominates:

| payment | 3% | capped fee | processor fixed | margin |
|---|---|---|---|---|
| $100 | 300 | 300 | 25 | +275 |
| $10 | 30 | 25 | 25 | **0** |
| $5 | 15 | 15 | 25 | **−10** |

Small tickets are usually the most common tickets. Track them.

---

## Why everything arrives in batches

The processor does not pay per transaction — that would be absurdly expensive. It settles in
windows:

- one cut-off per day, often late evening; anything captured after it rolls into the next batch
- one bank credit covers every transaction in the window
- the credit usually arrives 1–3 days later
- some processors fund more than once a day, so "daily" is not a guarantee

This is why the reconciliation has two completely different jobs:

```
ledger ─────► settlement line      one to one     (per transaction)
settlement ─► bank credit          many to one    (per batch)
```

Forty transactions become one bank line. Any matcher that assumes one-to-one will drown.

---

## The books: double-entry

Everything so far describes the *outside world*. This section is about how we record it
internally, and it is the part most platforms get structurally wrong.

A single-sided ledger records only what we owe merchants. That is half the picture, and it
leaves nowhere to put money that is ours-but-not-yet-arrived.

**Double-entry never records one side alone.** Every movement touches at least two accounts
and the entry must sum to zero:

> Someone deposits $1,000 with us to buy crypto.
> We debit **bank** by $1,000 and credit **their balance** by $1,000.
> Two lines, one journal entry, net zero.
> We now hold an asset we did not have, and owe a liability we did not have, and the books
> still balance.

### The chart of accounts

| Account | Type | Purpose | What it means |
|---|---|---|---|
| `bank:master:NZD` | asset | `master` | cash actually in our bank |
| `psp:receivable:NZD` | asset | `receivable` | **money in transit** — owed by the processor, not yet arrived |
| `merchant:<id>:pending:NZD` | liability | `pending` | owed to the merchant, but not yet withdrawable |
| `merchant:<id>:available:NZD` | liability | `available` | owed to the merchant, and withdrawable |
| `revenue:platform_fee:NZD` | revenue | `platform_fee` | our earnings |
| `expense:processor_fee:NZD` | expense | `processor_fee` | what processing costs us |

The `code` is a human-readable identifier. **All the meaning is in `type` and `purpose`
columns** — never parse a code string to decide what an account is for. Two merchants get two
pairs of liability accounts, one pair per currency they transact in, created at onboarding.

### Pending vs available

This is the mirror of what a custodian subledger calls *pending credit* and *available*:

| Subledger state | Our account | Side |
|---|---|---|
| pending credit | `merchant:<id>:pending` | liability |
| available | `merchant:<id>:available` | liability |
| pending debit | `payout:<id>:pending` (v1.1, when payouts land) | liability |
| — | `psp:receivable` | **asset** — the opposite side |

Note the last row. `receivable` is *not* pending credit: it is an asset, money someone owes
**us**. Pending and available are liabilities, money we owe **them**. They are mirror images,
and conflating them is how platforms end up promising money they have not received.

The practical difference: crediting `pending` means the merchant can see the money but cannot
withdraw it. Crediting `available` at capture would mean we front every merchant payment and
carry the credit risk until the processor pays us.

### The three tables

| Table | Written | Holds |
|---|---|---|
| `accounts` | once per merchant at onboarding | identity and type of each account |
| `journal_entries` | once per event | what happened, when, and the reference to match on |
| `journal_lines` | 2+ per event | the debits and credits |

### The actual rows

A $50.00 payment, our fee 5% (2.50), processor fee 0.25.

**`accounts`**

| id | code | type | purpose | merchant_id |
|---|---|---|---|---|
| 1 | `bank:master:NZD` | asset | master | – |
| 2 | `psp:receivable:NZD` | asset | receivable | – |
| 3 | `revenue:platform_fee:NZD` | revenue | platform_fee | – |
| 4 | `expense:processor_fee:NZD` | expense | processor_fee | – |
| 5 | `merchant:42:pending:NZD` | liability | pending | 42 |
| 6 | `merchant:42:available:NZD` | liability | available | 42 |

**`journal_entries`**

| id | kind | reference | occurred_at |
|---|---|---|---|
| 901 | payment | ORD-1234 | 10:02 |
| 902 | settlement | batch-4471 | +2 days |

**`journal_lines` — entry 901, capture**

| account | amount | reads as |
|---|---|---|
| 2 `psp:receivable` | **+5000** | debit: the processor owes us 50.00 |
| 5 `merchant:42:pending` | **−4750** | credit: we owe the merchant 47.50, not yet payable |
| 3 `platform_fee` | **−250** | credit: we earned 2.50 |

**`journal_lines` — entry 902, settlement**

| account | amount | reads as |
|---|---|---|
| 1 `bank:master` | **+4975** | debit: cash actually arrived |
| 4 `processor_fee` | **+25** | debit: their cut is now a cost |
| 2 `psp:receivable` | **−5000** | credit: no longer owed to us |
| 5 `merchant:42:pending` | **+4750** | debit: it is no longer pending |
| 6 `merchant:42:available` | **−4750** | credit: now withdrawable |

Five lines in the second entry, because settlement does two things at once: it converts a
receivable into cash, and it converts pending into available.

### Why two entries and not one

You might expect a single entry: debit something, credit the merchant, credit the fee. The
missing piece is **when**.

At capture the processor holds the money, so our bank balance has not changed — there is no
bank account to debit. The debit goes to `psp:receivable`. Two days later the batch lands and
receivable is converted into cash.

> **The number of journal entries is driven by when money changes hands, not by how many
> parties are involved.**

### Resulting balances

```sql
SELECT a.code, a.type, SUM(l.amount_minor) AS balance
FROM journal_lines l JOIN accounts a ON a.id = l.account_id
GROUP BY 1, 2 ORDER BY 1;
```

```
bank:master:NZD               4975   asset
psp:receivable:NZD               0   asset, cleared
merchant:42:available:NZD    −4750   liability, withdrawable
merchant:42:pending:NZD          0   liability, cleared
revenue:platform_fee:NZD      −250   revenue
expense:processor_fee:NZD      +25    expense
                             ──────
                                   0
```

Merchant owed = 4750 (all of it now available). Our margin = 250 − 25 = 225.
And `4975 = 4750 + 225`.

### What this buys

1. **`psp:receivable` is the in-transit account.** It goes positive at capture and should
   return to zero at settlement. If it does not clear, that is `missing_bank_credit` — a
   number on a balance sheet rather than two tables you have to diff.

2. **`pending` vs `available` encodes what we have actually promised.** A merchant can only
   withdraw from `available`. We never promise money we have not received.

3. **Balances are cached, and the cache is provable.** `account_balances` holds a running
   balance per account, maintained by a statement-level trigger. It is never the source of
   truth: a rebuild job recomputes from `journal_lines` and asserts equality. Measured on
   100k lines for one merchant, the cached read is 0.04 ms against 11 ms for the aggregate —
   and the gap grows with history.

4. **The invariant is structural.** The database refuses to commit an unbalanced entry.

### How it is enforced

```sql
CREATE CONSTRAINT TRIGGER journal_lines_balanced
    AFTER INSERT OR UPDATE OR DELETE ON journal_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION assert_entry_balanced();
```

Deferred so an entry can be written across several statements and validated once at COMMIT.

An important limit: **balance checking proves internal consistency, not correct attribution.**
A line posted to the wrong account still balances. The test that catches misattribution is the
one that checks account-specific expectations — e.g. *after settlement, `psp:receivable` for
this entry must be zero*.

### The cost

More rows per action (3–5 lines per event), plus a cache table to keep reads cheap.

**The cache must be statement-level, not row-level.** A per-row `UPSERT` against a hot
account is quadratic: measured at **155 seconds** for 300k lines in one transaction, versus
**1.8 seconds** when one upsert per account per statement is used. Same correctness, 84× the
write cost if you get it wrong.

Rebuild and verify:

```sql
TRUNCATE account_balances;
INSERT INTO account_balances(account_id, balance_minor)
SELECT account_id, SUM(amount_minor) FROM journal_lines GROUP BY account_id;

-- expect zero rows
SELECT b.account_id, b.balance_minor, l.s
FROM account_balances b
JOIN (SELECT account_id, SUM(amount_minor) s FROM journal_lines GROUP BY account_id) l
  USING (account_id)
WHERE b.balance_minor <> l.s;
```

---

## The equalities everything is built on

**Per transaction**

```
settlement_line.gross     = the payment amount in ledger_entries
settlement_line.net       = gross − processor fee
merchant owed             = gross − platform fee
margin                    = platform fee − processor fee
```

**Per batch**

```
sum(settlement_lines.net) = bank_lines.amount        the cash that actually arrived
```

**The one that matters**

> **Every dollar in the master account belongs either to a merchant or to us.**
>
> `bank credit = sum(merchant balances) + sum(our margins)`

With double-entry in place this is not a check we run — it is an accounting identity the
schema enforces, because every journal entry must net to zero. What reconciliation adds is
the *external* comparison: do the processor's claims and the bank's facts agree with the
books we already know are internally consistent?

Note what is **not** an invariant: "the ledger equals the settlement file". That is only true
in the special case where the two fees happen to match, and assuming it is the mistake this
whole section exists to prevent.

---

## What each break means, in this flow

| Break | Where the flow stopped |
|---|---|
| `missing_settlement` | captured in step 2, never appeared in step 4 |
| `missing_ledger` | appeared in step 4, we never recorded step 2 |
| `duplicate_settlement` | the processor sent the same batch twice |
| `amount_mismatch` | the amount in the file disagrees with what we recorded |
| `fee_mismatch` | the processor's cut changed and nobody told us |
| `timing` | the money arrived later than T+2 — often benign, sometimes not |
| `missing_bank_credit` | the processor said it paid; the statement says it didn't |
| `orphan_bank_credit` | money arrived that no batch claims |

`missing_bank_credit` is the dangerous one. It means someone is holding money that should be
in our account — a processor failure, a bank failure, or a settlement to the wrong place.

---

## Settlement files contain more than payments

A real file carries sales, refunds, chargebacks, reserve holds and releases, and
adjustments. Matching must be like-for-like: a refund line never matches a payment entry.
That is why `settlement_lines` has its own `kind`.

---

## What we deliberately do not model

- **Payouts to merchants.** Real, important, separate system.
- **Currency conversion.** Multi-currency entries exist; FX does not.
- **The chargeback lifecycle.** We see the resulting debit, not the dispute.
- **Card authorisation.** The processor owns it; we start at capture.
- **Interchange optimisation.** We see a bundled fee, not its components.

---

## Glossary

| Term | Meaning |
|---|---|
| **Acquirer** | The bank on the merchant side that receives card funds |
| **Authorisation** | "Is there money?" — a hold, not a transfer |
| **Capture** | Submitting an authorised payment for settlement |
| **Clearing** | The interbank exchange of transaction details and fee calculation |
| **Interchange** | The fee paid to the payer's bank; set by the card network |
| **Scheme fee** | The fee paid to Visa/Mastercard |
| **Processor / PSP** | The software layer we integrate with |
| **Settlement** | Money moving between banks; the acquirer paying us |
| **Settlement window** | The period of transactions bundled into one payment |
| **Payout** | Us paying a merchant |
| **T+N** | N business days after capture |
| **Reserve** | A percentage withheld against risk, released later |
| **Reconciliation** | Proving three records of the same money agree |
