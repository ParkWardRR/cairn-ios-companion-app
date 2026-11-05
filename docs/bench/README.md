# Bench records

One file per hardware run, named `<subject>-YYYY-MM-DD.md`. A rewrite phase is **Proven** only
when its record is here; a green CI run proves nothing about a radio, a receiver or a car.

Every record states, at the top:

- the date, and where the run happened
- the **firmware commit** flashed on the dongle at the time
- the **app build number** (`git rev-list --count HEAD` of the commit the build came from) and its
  channel
- what hardware was involved — which dongle, which car, which phone

and then the numbers the phase asked for, whatever they show. A failed row gets its link log, not
a guess at the cause.

[RUNBOOK.md](RUNBOOK.md) is what to do on the day, in the order that stops a run being wasted.

The app writes most of a record itself: Dongle screen → Bench → Bench Report. Tap a row's name
before you run it, so the record can say how long that row took.

| Record | Phase | Subject |
|---|---|---|
| [first-link-2026-11-05.md](first-link-2026-11-05.md) | — | First contact: pairing proven 5/5, but no session outlived 21 s |

The first record is deliberately not an R1 one: R1 is still outstanding, because a link that
drops every few seconds cannot have its pairing timed.
