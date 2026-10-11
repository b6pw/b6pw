# B6PW Mainnet Smart Contracts — Open-Source Subset

This repository publishes the complete Solidity implementations of eight of
B6PW’s twelve deployed contract implementations on Robinhood Mainnet. It is a
partial source release: it does not publish all twelve implementations or the
complete B6PW platform source.

## Canonical deployment

- Network: Robinhood Mainnet
- Chain ID: `4663`
- Canonical generation: `0x9bdba15f79a2a534825717b5cd4285b78ec7e232c9610419fd6222476b4c092d`
- Contract addresses and runtime fingerprints:
  [`docs/MAINNET_DEPLOYMENTS.json`](docs/MAINNET_DEPLOYMENTS.json)

The source scope was prepared against the canonical provenance record for this
generation. A read-only chain check at block `85894438` (2026-10-11
`14:14:38 UTC`) found that the runtime bytecode of the eight included
contracts matched the recorded canonical runtime fingerprints. This is a
dated identity check, not a guarantee about future chain state.

## Included implementations

| Contract | Mainnet address | Canonical runtime Keccak-256 |
| --- | --- | --- |
| `B6PWOwnershipCoreNG` | `0xB74D1A08Ce58a8818ddF24e9861597fEaC05E775` | `0xb2269015dbdb32f7a949ff6ba7a1eb99580a722c3ca0fdfbd2206b5c68dbc518` |
| `B6PWStakeLedgerNG` | `0x7E4D8c42EB06DA7eE3d0B88A31604eDa78C77341` | `0xaba8f6256a261653a5ffd404ea7e330ca7fba8545a2f87d2be85365caa36275b` |
| `B6PWSettlementKernelNG` | `0x8FdC97A4e91Aa4C5e1345d928CA1F8D36A1edF79` | `0x5c1e5b4d147032aa87ecef92e9e0e68dd6f9d228bf17210ae15850bbc82cdeb6` |
| `B6PWQuotePolicyHubNG` | `0x479de0be528F09feC7201aa267F9233308Dcb216` | `0x03bd7d72b803a00aba55bc539cb9983fec653cdad8e6ae350bb27caf12a1403a` |
| `B6PWOracleDirectoryNG` | `0xD6369c9557e6c5cCB9bF506cEa2EaF28718782E4` | `0x3cb35cb5c9d85643c903a6fa8283e7d24c3868e716521e5751f4b7a137337b71` |
| `B6PWSpotSourceNG` | `0xd665C56e2c4Da5e12F548cebd13fc064Ad2C9293` | `0xd2f014ed954bdb9878972f1c381cf46157fd9128384c5ef28b9a45c0fe016b95` |
| `B6PWChainlinkETHUSDAdapterNG` | `0xDa230c98c9B418e6A504771AbdFF2F613592a977` | `0x636df45aa78301617a01655f2c8c2a1bf1681f3040f2409a1707d178fd07066a` |
| `B6PWMarketBusinessNG` | `0x4A9B3967c1E2736007Ba91DEc2C5303Da380c6fd` | `0xd14c8b4bdedfc027eab8b97462e6ff11716798460b766ece6a51a4766b709e06` |

## Build and included dependencies

The package contains eight contract implementations, sixteen interface files,
and three libraries. Build with Foundry and Solidity `0.8.24`, optimizer
enabled for 200 runs, `via_ir = false`, and EVM target `paris`:

```sh
forge build --offline --no-cache
```

The isolated review build compiled the eight implementations and their exact
source dependencies. The reviewed ABI, metadata, creation bytecode, deployed
bytecode template, link references, and normalized immutable locations matched
the corresponding canonical build artifacts.

Some included interface declarations describe platform administration,
Registrar, batch, special-stake, or custody operations. These are interface
declarations only. The implementations behind those declarations, including
the following four deployed contracts, remain private and are not included:

- `B6PWPlatformAccountingKernelNG`
- `B6PWGovernanceConfigNG`
- `B6PWPlatformBatchOperatorNG`
- `B6PWCustodyNG`

Platform batch-registration programs, internal operations and administration
tools, wallet tools, backend and frontend code, deployment credentials, and
internal Git history are also excluded. This subset cannot rebuild the full
twelve-contract deployment.

## License

The included `LICENSE` is MIT. It applies only to B6PW-authored materials that
B6PW has the right to license. No third-party Solidity source dependency is
bundled in this package; separately obtained tools and dependencies remain
subject to their own licenses.

## Known issue and review limits

`NG-P2-001` is classified as
`KNOWN_CORE_DEFECT_OPERATIONALLY_MITIGATED`: operational measures mitigate
the issue, but the source code has **not** been fixed. See
[`docs/security/NG-P2-001.md`](docs/security/NG-P2-001.md).

The documented ownership/platform-accounting callback review and source/runtime
checks are limited to their stated scope. Passing those checks does not mean
that the complete B6PW system has no vulnerabilities, and this repository is
not a claim of a full-system security audit.
