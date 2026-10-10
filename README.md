# B6PW Mainnet Smart Contracts — Public Subset Candidate

This is a local, unpublished review candidate for the intended repository
[`b6pw/b6pw`](https://github.com/b6pw/b6pw). It contains five complete contract
implementations from the canonical Robinhood Mainnet generation. It does **not**
publish all twelve deployed contract implementations and must not be described
as a complete 12/12 source release.

## Canonical deployment

- Chain ID: `4663` (Robinhood Mainnet)
- Candidate: `400d3bd0c2c6835902a255e8dc1aeae3ee284c94c532c6d2b54285d8540a5b28`
- Generation: `0x9bdba15f79a2a534825717b5cd4285b78ec7e232c9610419fd622476b4c092d`
- Canonical input used for this review: `nextgen/runtime/MAINNET_CANONICAL_PROVENANCE.json` in the preparation workspace. This candidate carries a current-only deployment projection rather than unrelated historical manifests.
- Contract address/runtime inventory (including source-publication status):
  [`docs/MAINNET_DEPLOYMENTS.json`](docs/MAINNET_DEPLOYMENTS.json)

The formal source closure contains 36 Solidity files and has SHA-256
`8573ba698181bbb1aa453eccb2a1df55d4bd446954a76931c66e66c4ee7fec4d`. This
candidate intentionally omits seven deployed implementations, so its file set
cannot reproduce that full-closure digest or rebuild all twelve contracts.

## Included implementations

| Contract | Mainnet address | Canonical runtime Keccak-256 |
| --- | --- | --- |
| `B6PWQuotePolicyHubNG` | `0x479de0be528F09feC7201aa267F9233308Dcb216` | `0x03bd7d72b803a00aba55bc539cb9983fec653cdad8e6ae350bb27caf12a1403a` |
| `B6PWOracleDirectoryNG` | `0xD6369c9557e6c5cCB9bF506cEa2EaF28718782E4` | `0x3cb35cb5c9d85643c903a6fa8283e7d24c3868e716521e5751f4b7a137337b71` |
| `B6PWSpotSourceNG` | `0xd665C56e2c4Da5e12F548cebd13fc064Ad2C9293` | `0xd2f014ed954bdb9878972f1c381cf46157fd9128384c5ef28b9a45c0fe016b95` |
| `B6PWChainlinkETHUSDAdapterNG` | `0xDa230c98c9B418e6A504771AbdFF2F613592a977` | `0x636df45aa78301617a01655f2c8c2a1bf1681f3040f2409a1707d178fd07066a` |
| `B6PWMarketBusinessNG` | `0x4A9B3967c1E2736007Ba91DEc2C5303Da380c6fd` | `0xd14c8b4bdedfc027eab8b97462e6ff11716798460b766ece6a51a4766b709e06` |

## Build and source identity

Build with Foundry and Solidity `0.8.24`, optimizer enabled for 200 runs,
`via_ir = false`, EVM target `paris`:

```sh
forge build --offline --no-cache
```

The local isolated build compiled all five included contract implementations
and their 14 exact source dependencies. Its contract ABI, metadata, creation
bytecode, and deployed-bytecode template matched the corresponding formal
build artifacts. The canonical Mainnet `eth_getCode` recheck recorded in the
013 evidence is a historical snapshot at block `82909508` on 2026-10-08; this
candidate does not claim a fresh chain read at publication time. See the
canonical provenance and internal review evidence before relying on identity.

The shared source dependencies are copied unchanged. Some are declaration-only
interfaces/types/events and include ABI-level platform/batch names and data
shapes needed by the canonical compilation inputs. They do not contain the
private batch-registration implementation. Their inclusion is explicit in
[`SOURCE_SCOPE.md`](SOURCE_SCOPE.md) and must be reviewed as part of any final
user sign-off.

## Publication boundary

The seven other deployed contract implementations are intentionally absent.
This repository subset does not claim that their source is public, nor that the
entire deployed system can be independently rebuilt from this package. The
private batch-registration tools, operational scripts, platform wallet tools,
backend, frontend, deployment materials, and Git history are also absent.

MIT applies only to the included B6PW-authored materials whose rights are
controlled by B6PW. No third-party Solidity source dependency is bundled here;
any separately obtained tooling remains under its own license.

## Known issue

NG-P2-001 is disclosed as
`KNOWN_CORE_DEFECT_OPERATIONALLY_MITIGATED`. The source defect is **not fixed**;
the mitigation is an operational policy. See
[`docs/security/NG-P2-001.md`](docs/security/NG-P2-001.md).

This package is not published and is not a release authorization or a user
sign-off record.
