# Adaptation notes

Pinky arrived already shaped for the ProjectFactory: `LaunchToken` (Pinky / PINKY, 10^27 minor
units to `msg.sender`, no other functions), `PinkyStaking(address, address)` and
`PinkyVault(address, address, address, address, bytes32, address, uint256, uint16, uint16, uint32)`
with the owner as the first constructor argument, no initialization calls, no proxy, no
DELEGATECALL / CALLCODE / SELFDESTRUCT, and constructors that call no other contract. None of
that needed changing, and the constructor signatures are unchanged so the constructor arguments the
requester wrote in `launch.json` still apply. Every library function the contracts call is
`internal`; the one `public` function in `OracleAttestation.sol` is on the abstract consumer
contract, not the library, and `src/OracleAttestation.sol` is byte-identical to the protocol copy in
the oracle-consumer reference.

The changes below are the audit findings that reproduced, plus the launch terms.

## Audit findings that reproduced and were fixed

Each was reproduced against the unchanged code in a scratch test before the fix.

| Finding | File | Change | Test |
| --- | --- | --- | --- |
| [medium] staking strands the stream while `totalStaked == 0` | `src/PinkyStaking.sol` `updateReward` | `lastUpdate` only advances while someone is staked, so stream time that passes with nobody staked is credited to the next staker instead of staying in the contract forever. `notify` is unchanged and still refuses when nobody is staked. The up-to-604,799 wei per `notify` lost to `amount / DURATION` truncation is dust and is left as is. | `test/PinkyStaking.t.sol`: `test_StreamSurvivesAPeriodWithNobodyStaked`, `test_AGapInTheMiddleOfTheStreamIsNotLostEither`, `test_ANotifyAfterAGapStillAccountsForEverything`, `testFuzz_NothingIsStrandedWhenTheStreamEnds` |
| [low] `setPanel` during a pending request refuses its answer | `src/PinkyVault.sol` `Terms`, `ask`, `onOracleResult`, `_body` | The panel size and quorum a request was bought with are recorded per promise in `terms[id]` at `ask` (the smallest over its asks, since every request a bond paid for stays answerable) and the attestation is checked against those, not the owner's current settings. `_body` now takes the panel it writes as parameters. | `test/PinkyVault.t.sol`: `test_ChangingThePanelDuringARequestDoesNotRefuseItsAnswer`, `test_ARequestBoughtWithASmallerPanelIsStillAnswerable` |
| [low] `agreed >= quorum` not required | `src/PinkyVault.sol` `onOracleResult` | Added `a.agreed < a.quorum` to the `InvalidAttestation` check, as the oracle-consumer reference requires. | `test/PinkyVault.t.sol`: `test_RefusesAnAnswerThePanelDidNotAgreeOn` |
| [low] the maker can ask about their own broken promise and collect the 10% bounty | `src/PinkyVault.sol` `payout`, `ask` | The bounty is zero when the asker is the maker; that share goes with the rest to stakers and the burn. `ask` records the asker only on the first ask, or replaces a maker-asker with the first watcher who re-asks, so a maker cannot ask first to deny a watcher's bounty. | `test/PinkyVault.t.sol`: `test_AMakerWhoAsksAboutTheirOwnBrokenPromiseGetsNoBounty`, `test_AMakerWhoAsksAboutTheirOwnKeptPromiseStillGetsTheBond`, `test_AMakerWhoAsksFirstYieldsTheBountyToTheWatcherWhoReasks` |
| [low] `setProtocol` can point `ask` at an intake whose price equals a bond | `src/PinkyVault.sol` `Terms`, `make`, `ask` | `make` records the Intake price it saw in `terms[id].maxPrice`; `ask` refuses a price above it with `InvalidPayment`. The owner keeps the Intake, action, signer and panel setters the oracle-consumer reference requires, but can no longer move a bond through them. A real price rise leaves older promises to `refund`, which the README now says. | `test/PinkyVault.t.sol`: `test_AskRefusesAPriceAboveTheOneTheBondWasMadeUnder` |
| [low] anyone can re-ask after a day, which kills a still-valid pending answer and replaces the asker | `src/PinkyVault.sol` `ask` | A re-ask no longer deletes the earlier request's `promiseIdFor` entry: every request the bond paid for stays answerable until a verdict lands, the first answer wins, and a later one is refused with `WrongStatus`. The asker is not replaced by a re-asker (see the bounty row). Re-asking stays open to anyone, so a watcher can retry when the oracle refused a request the maker will not retry; the cost is bounded by `MAX_ATTEMPTS` and documented. | `test/PinkyVault.t.sol`: `test_AskAgainAfterATimeoutAndEitherAnswerCounts` (the old `test_AskAgainAfterATimeoutAndTheOldRequestIsDead`, changed with the behaviour), `test_AThirdPartyReaskDoesNotTakeTheWatchersBounty` |

The new storage is one `mapping(uint256 => Terms) public terms` beside `promises`; the `Promise`
struct and the `promises(id)` getter are unchanged so existing readers keep working. The callback
still fits the Intake's 200,000 gas stipend from cold storage
(`test_CallbackFitsTheIntakeStipendFromColdStorage`, using `vm.cool`).

## Audit findings not changed

- **[info] transfers after `endTime` but before `close` are counted.** Reproduces and is the
  documented design: the window ends at the block of `close`, which anyone may call. Not changed;
  the README now says prominently that a maker should close at the deadline themselves.
- **[info] `questionHash` is not pinned.** Reproduces: the vault binds an answer to a promise by the
  Intake request id, the chain id and the exact block range, and trusts the writer's pairing. The
  oracle's canonical question document cannot be reproduced on chain from the body, so pinning it
  would need an owner-fed hash the oracle only knows after the request. Not changed; documented as
  a trust assumption in the README.
- **[info] coverage statement.** Its one actionable point, `pool.fee` not checked against the
  launch's terms, is handled below.

## Launch terms

- `launch.json`: `pool.fee` 3000 → 12500, the launch policy's 1.25%, which admission requires.
  Nothing else in the file changed; the manifest step owns it.
- `test/LaunchToken.t.sol` (new): name, symbol, decimals, the fixed 10^27 supply to the deployer,
  a plain transfer, and that nothing mints after launch, as the launch-token reference asks.
- `README.md`: the launch section (chain, pair, supply split by the factory, the pool's 1.25%
  fee, and that the token has no extra features because the brief asked for none), the changed
  bounty / re-ask / price rules, the staking stream change, and the trust assumptions above.

## Checks run

`forge build` and `forge test` with the project's own `foundry.toml`: 46 tests pass (unit, fuzz,
invariant, the protocol's oracle conformance vector). A scratch copy of the protected project floor
(constructors on an empty chain 4663 with the `launch.json` arguments, supply untouched, runtime
under 24,576 bytes, no DELEGATECALL / CALLCODE / SELFDESTRUCT) passes: LaunchToken 1,489 bytes,
PinkyStaking 2,549 bytes, PinkyVault 12,528 bytes. Not run: anything against the live chain.
