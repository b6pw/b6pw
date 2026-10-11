# B6PW source scope and exclusion review

This file records the approved scope for this 33-file, partial-source release:
8 of the 12 deployed contract implementations, 16 compile-required interfaces,
3 libraries, and the reviewed release documentation/configuration. Source
decisions apply to complete Solidity files; no deployed source was edited,
redacted, or represented as a modified chain-matching version. The user has
approved the platform-origin and special-stake paths present in the eight
included canonical implementations, plus the exact compile-required interface
declarations described below. That approval does not extend to the four
excluded implementations or private operational tooling.

## Twelve canonical deployed contracts

| Contract | Release scope | Review reason / consequence |
| --- | --- | --- |
| `B6PWOwnershipCoreNG` | Included in the approved 8/12 source release | Exact deployed source includes the `createPlatform` entry used by PlatformAccountingKernel to create platform-origin records. It is included unmodified within the user's approved source scope; that code path is visible and identified for user review. |
| `B6PWStakeLedgerNG` | Included in the approved 8/12 source release | Exact deployed source includes platform-origin and shared-special-stake accounting branches. It is included unmodified within the user's approved source scope; no batch-registration implementation is present in this file. |
| `B6PWSettlementKernelNG` | Included in the approved 8/12 source release | Exact deployed source includes platform-origin listing/transfer invariants and generation metadata. It is included unmodified; no source-level redaction or claim of a modified chain-matching version is made. |
| `B6PWPlatformAccountingKernelNG` | Excluded — private | Contains Registrar, special-stake, batch nonce, authorization validation and batch creation implementation, as well as other platform accounting/custody logic in the same contract. |
| `B6PWGovernanceConfigNG` | Excluded — private | Contains ordinary governance/oracle configuration and platform batch-operator role/module and batch-policy controls in one deployed implementation. |
| `B6PWQuotePolicyHubNG` | Included | Quote-policy module; no platform batch registration implementation in this source file. |
| `B6PWOracleDirectoryNG` | Included | Oracle composition/read module; no platform batch registration implementation in this source file. |
| `B6PWSpotSourceNG` | Included | Spot-price source adapter; no platform batch registration implementation in this source file. |
| `B6PWChainlinkETHUSDAdapterNG` | Included | ETH/USD feed adapter; no platform batch registration implementation in this source file. |
| `B6PWMarketBusinessNG` | Included | Read-only fee calculation module; no platform batch registration implementation in this source file. |
| `B6PWPlatformBatchOperatorNG` | Excluded — private | Entire deployed implementation organizes and forwards authorized platform batches. |
| `B6PWCustodyNG` | Excluded — private | Platform-only custody operations for platform-origin IDs (metadata, listing, and direct transfer) are implemented in this file. |

The eight included contracts are exact source files from the canonical closure.
The four excluded contracts remain deployed; their addresses and canonical
runtime hashes are recorded in `docs/MAINNET_DEPLOYMENTS.json`. Their omission
means this is a partial-source release, not a full-system source verification
bundle.

## Shared compile dependencies

The following 19 imported source units are included byte-for-byte unchanged so
that the eight selected contracts retain canonical source-unit names and build
metadata. They are interfaces, enums, data structures, events, errors, or
stateless libraries; none implements `createBatch`, `batchCreate`, Registrar
signature validation, batch iteration, or platform registration operations.
All interface declarations listed here are within the user's approved
8-contract source-release scope; this does not approve the underlying private
implementations:

- Interfaces: `ICustody.sol`, `IEthUsdSourceBinding.sol`,
  `IGenerationIdentity.sol`, `IGovernanceConfig.sol`, `IMarketBusiness.sol`,
  `IOracleDirectory.sol`, `IOwnershipCore.sol`, `IPlatformAccounting.sol`,
  `IPriceSource.sol`, `IQuotePolicyHub.sol`, `ISettlementKernel.sol`,
  `ISpotSourceBinding.sol`, `IStakeLedger.sol`, `NextGenErrors.sol`,
  `NextGenEvents.sol`, `NextGenTypes.sol`.
- Libraries: `BoundedStaticCall.sol`, `FullPrecisionMath.sol`,
  `SourceBindingHash.sol`.

`NextGenTypes.sol` includes the `BatchRequest` data structure;
`NextGenEvents.sol` includes batch/platform event declarations; and
`IGovernanceConfig.sol` includes module/policy interface declarations. These
are ABI-level disclosures, not executable batch-registration logic. Their
inclusion here is explicitly approved for this 8-contract source release.

The three newly necessary interfaces `IOwnershipCore.sol`,
`ISettlementKernel.sol`, and `IStakeLedger.sol` expose the peer-core ABI used by
the added source files. `ICustody.sol` exposes custody admin, metadata, and
platform-binding declarations. `IPlatformAccounting.sol` additionally exposes
`registrar()`, `batchNonce()`, `registrarCodeHash()`, `setRegistrar()`,
`specialStakeOf()`, `stakeSpecial()`, `topUpSpecial()`, `unstakeSpecial()`,
`batchCreate()`, and custody/authorization control declarations. These are
interface-only declarations required by the unmodified source closure; they do
not contain the private PlatformAccounting/BatchOperator implementations,
registrar signature validation implementation, batch iteration implementation,
or scripts. The seven additional interfaces (`IEthUsdSourceBinding`,
`IGenerationIdentity`, `IMarketBusiness`, `IOracleDirectory`, `IPriceSource`,
`IQuotePolicyHub`, and `ISpotSourceBinding`) are also included because the exact
imported source graph requires them to compile.

No test harnesses, scripts, private deployment artifacts, private evidence,
platform automation, backend/frontend code, any of the four excluded contract
implementations, or repository history are included. This is an 8-of-12
implementation source package, not a claim that all deployed contract source
is public.
