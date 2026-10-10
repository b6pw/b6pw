# Source scope and exclusion review

This file records the reviewed boundary for the unpublished local candidate.
Source decisions apply to complete Solidity files; no deployed source was
edited, redacted, or represented as a modified chain-matching version.

## Twelve canonical deployed contracts

| Contract | Candidate status | Review reason / consequence |
| --- | --- | --- |
| `B6PWOwnershipCoreNG` | Excluded | The same source contains ordinary ownership plus `createPlatform`, the platform-kernel entry used to create platform-origin records. Removing that path would alter deployed source and break exact-source identity. |
| `B6PWStakeLedgerNG` | Excluded | Ordinary registration and accounting share a source file with platform-origin shared-special-stake/credit handling. No source-level split can preserve the deployed file unchanged. |
| `B6PWSettlementKernelNG` | Excluded | General settlement is co-located with platform-origin listing/transfer invariants and generation metadata. The complete deployed source is withheld rather than redacted. |
| `B6PWPlatformAccountingKernelNG` | Excluded — private | Contains Registrar, special-stake, batch nonce, authorization validation and batch creation implementation, as well as other platform accounting/custody logic in the same contract. |
| `B6PWGovernanceConfigNG` | Excluded — mixed | Contains ordinary governance/oracle configuration and platform batch-operator role/module and batch-policy controls in one deployed implementation. |
| `B6PWQuotePolicyHubNG` | Included | Quote-policy module; no platform batch registration implementation in this source file. |
| `B6PWOracleDirectoryNG` | Included | Oracle composition/read module; no platform batch registration implementation in this source file. |
| `B6PWSpotSourceNG` | Included | Spot-price source adapter; no platform batch registration implementation in this source file. |
| `B6PWChainlinkETHUSDAdapterNG` | Included | ETH/USD feed adapter; no platform batch registration implementation in this source file. |
| `B6PWMarketBusinessNG` | Included | Read-only fee calculation module; no platform batch registration implementation in this source file. |
| `B6PWPlatformBatchOperatorNG` | Excluded — private | Entire deployed implementation organizes and forwards authorized platform batches. |
| `B6PWCustodyNG` | Excluded — private-scope adjacent | Platform-only custody operations for platform-origin IDs (metadata, listing, and direct transfer) are implemented in this file. |

The five included contracts are exact source files from the canonical closure.
The seven excluded contracts remain deployed; their addresses and canonical
runtime hashes are recorded in `docs/MAINNET_DEPLOYMENTS.json`. Their omission
means this is a partial-source release, not a full-system source verification
bundle.

## Shared compile dependencies

The following 14 imported source units are included byte-for-byte unchanged so
that the five selected contracts retain canonical source-unit names and build
metadata. They are interfaces, enums, data structures, events, errors, or
stateless libraries; none implements `createBatch`, `batchCreate`, Registrar
signature validation, batch iteration, or platform registration operations:

- Interfaces: `IEthUsdSourceBinding.sol`, `IGenerationIdentity.sol`,
  `IGovernanceConfig.sol`, `IMarketBusiness.sol`, `IOracleDirectory.sol`,
  `IPriceSource.sol`, `IQuotePolicyHub.sol`, `ISpotSourceBinding.sol`,
  `NextGenErrors.sol`, `NextGenEvents.sol`, `NextGenTypes.sol`.
- Libraries: `BoundedStaticCall.sol`, `FullPrecisionMath.sol`,
  `SourceBindingHash.sol`.

`NextGenTypes.sol` includes the `BatchRequest` data structure;
`NextGenEvents.sol` includes batch/platform event declarations; and
`IGovernanceConfig.sol` includes module/policy interface declarations. These
are ABI-level disclosures, not executable batch-registration logic. They are
listed here deliberately so the final reviewer can assess whether the
interface/schema disclosure fits the approved boundary.

No test harnesses, scripts, deployment artifacts other than canonical public
identity metadata, private evidence, platform automation, backend/frontend
code, or repository history are included.
