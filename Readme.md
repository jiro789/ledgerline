# Ledgerline

Reconciliation and break investigation for payment systems.

Every payment company records the same money three times: in its ledger, in the
processor's settlement file, and in its bank statement. The three never quite agree,
and the gaps cost real money and real hours.

Ledgerline matches what can be matched, classifies what cannot, heals only the
classes that are provably safe, and explains the rest.

**Status: very early.** Built in public. Nothing works yet — this README grows as
the system does.

## What it will do

- Three-way matching: ledger, settlement file, bank statement
- Deterministic matching, with optimal assignment for ambiguous clusters
- A break taxonomy and a small allowlisted set of auto-heal rules
- A read-only investigator agent that explains unresolved breaks and cites its evidence
- A hash-chained audit log

## Scope

Data is synthetic but structurally realistic. No real bank connections, no real money.
The point is the reconciliation logic and the audit trail, not the integrations.

## Stack

Go · PostgreSQL · Temporal · Ollama (local)
