# Pinky

A promise with money behind it.

Every deployer says they won't dump. Pinky lets them prove it. A deployer locks IMD behind a
promise: *"my wallet will not move more than `maxOut` of this token before the deadline."* When
time is up, the contract buys one answer from the IdentityMD oracle out of the bond — the sum of
the wallet's outgoing `Transfer` values over the exact block range — and that answer decides
where the bond goes. Keep your word and the IMD comes home. Break it and it doesn't.

Runs on Robinhood Chain. Status: contracts compile and 46 Foundry tests pass (unit, fuzz, invariant and
the protocol's oracle conformance vector). Not deployed. An imported-code audit's findings are fixed
(see `ADAPTATION.md`); the launch's own review is still to come.

## How it works

1. **make** — the deployer calls `PinkyVault.make(token, maxOut, duration, bond)`. The vault
   pulls `bond` IMD and records the current block.
2. **close** — once the deadline has passed, anyone calls `close(id)`, which fixes the closing
   block. **Until then the promise keeps running**: a transfer after the deadline but before
   `close` is still counted, so a maker should close at the deadline themselves rather than wait
   for a watcher to do it.
3. **ask** — 32 blocks later anyone calls `ask(id)`. The vault pays the Intake 0.5 IMD from the
   bond and sends an `oracle.request` with `evidence: "chain"` and a pinned `log-sum` recipe:
   `Transfer` events of `token`, filtered to `from = maker`, summed over `[startBlock, endBlock]`.
   The price charged can never exceed the price the Intake quoted when the promise was made.
4. **verdict** — the Intake calls `onOracleResult` with the signed attestation. The vault checks
   the signature in its own EIP-712 domain, the chain id, both block numbers, that the panel and
   quorum are at least what the request was bought with, and that at least `quorum` members
   agreed, and records `Kept` (sum ≤ `maxOut`) or `Broken`. No funds move in the callback.
5. **payout** — anyone calls `payout(id)`.
   - Kept: the rest of the bond returns to the maker.
   - Broken: 10% to the watcher who asked, half of the remainder to PINKY stakers, the rest to
     `0x…dEaD`. A maker who asked about their own promise gets no bounty; that share burns or
     goes to stakers with the rest.

If the oracle gives no answer, `ask` can be repeated after 24 hours, three times in all. Every
request a bond paid for stays answerable until a verdict lands, so a late answer to an earlier
request still counts, and the first watcher to ask keeps the bounty. After three failed attempts,
or seven days after closing, `refund(id)` returns what is left to the maker.

## Where IMD is used

| | |
|---|---|
| Bond | Held in IMD; the minimum is 5 IMD and never less than three oracle fees |
| Oracle | Every settlement is an on-chain `oracle.request` paid in IMD through the Intake |
| Broken promises | IMD is burned and streamed to PINKY stakers |
| Token | PINKY launches through the IMD ProjectFactory, paired with IMD |

## Contracts

| File | What it is |
|---|---|
| `src/PinkyVault.sol` | Bonds, the oracle request, the verdict and the payout |
| `src/PinkyStaking.sol` | Stake PINKY, earn forfeited IMD over a seven-day stream. No owner. Stream time that passes with nobody staked is paid to the next staker, not lost |
| `src/OracleAttestation.sol` | The IdentityMD consumer library, unchanged from launch 976 |
| `src/LaunchToken.sol` | The fixed launch token |

## Build

```
forge build
forge test
```

Foundry 1.8.3, solc 0.8.26. Dependencies are vendored under `lib/` (OpenZeppelin Contracts
v5.5.0, forge-std v1.9.7); nothing is downloaded at build time.

## Trust and known limits

- **Owner.** The vault owner can change the Intake, the action id, the oracle signer and the
  panel settings. A malicious owner could point the signer at a key of their own and forge
  verdicts. The owner cannot redirect a bond through the Intake: a promise is never charged more
  per request than the price quoted when it was made, so an Intake that quotes more leaves the
  promise to be refunded. A panel change applies to new requests only. IMD, the staking contract
  and the minimum bond cannot be changed.
- **One wallet.** A promise covers one wallet and one token. Tokens the deployer holds elsewhere
  are not covered.
- **No answer favours the maker.** If the oracle cannot answer, the bond is refunded. A maker who
  could make the question unanswerable would get their bond back. Anyone may re-ask after a day;
  each re-ask costs the bond another oracle fee, three in all.
- **Answers are paired by the writer.** The vault does not pin the oracle's `questionHash`; an
  answer is bound to a promise by the Intake request id, the chain id and the exact block range.
  Two promises closed in the same blocks rely on the Intake's writer delivering each answer under
  its own request id.
- **Window length.** The oracle has attested log sums on Robinhood Chain over ranges of about
  18,000 blocks (roughly half an hour). Longer terms are untested.
- **Standard tokens only.** Rebasing or fee-on-transfer tokens are out of scope.
- **Gas-limited payout.** The staker share is sent in a `try`; if it fails, that share is burned.

## Checked against the live oracle

On 2026-10-09 the exact question the vault builds was paid for on Robinhood Chain
(`0x1e725da5203496444ba7a33cb4a66bb71e82e990c9a9bf823160edc83b0e2b96`, oracle request
`c5e21f11-5172-4f9b-a506-9babcdfa47c2`). The window held four IMD transfers worth 18.6457 IMD; one,
6.2152 IMD, came from the address in the filter. The oracle attested 6215220149346698936 wei in
2 minutes 15 seconds, with the `filter.from` recipe as asked. Four of five panel members agreed at
a quorum of four, so the launch asks for a panel of seven with a quorum of five.

That request had no callback. Delivery into the vault is covered by tests against a mock Intake
and has not run on chain yet.

## Launch

PINKY launches through the IdentityMD ProjectFactory on Robinhood Chain (chain id 4663), paired
with IMD. `LaunchToken` mints the whole fixed supply of 1,000,000,000 PINKY to the factory, which
splits it: 10% to the swarm, 88% seeds the pool and 2% goes to the policy's wallet. No contract
here is sent any of it at launch; PinkyStaking only holds what stakers deposit later. The pool
opens at the network's trading fee of 1.25%. The token has no mint, owner, pause, blocklist, fee or
upgrade path, and the brief asked for none.

## Open items

- A site that lists promises and their verdicts.
