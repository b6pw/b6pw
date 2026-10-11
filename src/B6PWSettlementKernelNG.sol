pragma solidity 0.8.24;

import {IGenerationIdentity} from "../interfaces/IGenerationIdentity.sol";
import {IGovernanceConfig} from "../interfaces/IGovernanceConfig.sol";
import {IOracleDirectory} from "../interfaces/IOracleDirectory.sol";
import {IMarketBusiness} from "../interfaces/IMarketBusiness.sol";
import {IOwnershipCore} from "../interfaces/IOwnershipCore.sol";
import {ISettlementKernel} from "../interfaces/ISettlementKernel.sol";
import {IStakeLedger} from "../interfaces/IStakeLedger.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
import "../interfaces/NextGenErrors.sol";
import {NextGenEvents} from "../interfaces/NextGenEvents.sol";
import {NG} from "../interfaces/NextGenTypes.sol";

/// @notice Permanent settlement core for NextGen Market sale and Direct Transfer.
/// @dev Ownership, stake and configuration are held by their fixed peer cores.
///      This contract owns only listings and protocol-fee liabilities.
contract B6PWSettlementKernelNG is ISettlementKernel, NextGenEvents {
    uint256 private constant USD6_TO_WEI_SCALE = 1e30;
    uint256 private constant IDENTITY_READ_GAS = 30_000;
    uint256 private constant ORACLE_READ_GAS = 120_000;
    uint256 private constant MARKET_MODULE_GAS = 100_000;

    uint256 private immutable _chainId;
    bytes32 private immutable _generationId;
    address private immutable _config;

    mapping(bytes32 => NG.Listing) private _listings;
    mapping(address => uint256) private _protocolFeeCredits;
    uint256 private _totalProtocolFeeLiability;
    bool private _entered;

    struct SaleQuote {
        uint256 feeWei;
        uint256 minimumFeeWei;
        uint256 oracleVersion;
        uint256 marketVersion;
        NG.EthObservation observation;
        NG.BusinessPolicy policy;
    }

    struct DirectQuote {
        bytes32 idHash;
        uint256 feeWei;
        uint256 oracleVersion;
        address feeRecipient;
        NG.BusinessPolicy policy;
    }

    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    constructor(address config_) {
        if (config_ == address(0) || config_.code.length == 0) {
            revert InvalidConfiguration();
        }

        IGovernanceConfig configContract = IGovernanceConfig(config_);
        uint256 configuredChainId = configContract.chainId();
        if (configuredChainId != block.chainid) revert WrongChain();

        bytes32 configuredGeneration = configContract.generationId();
        if (configuredGeneration == bytes32(0) || configContract.config() != config_) {
            revert InvalidConfiguration();
        }

        _chainId = configuredChainId;
        _generationId = configuredGeneration;
        _config = config_;
    }

    function chainId() external view override returns (uint256) {
        return _chainId;
    }

    function generationId() external view override returns (bytes32) {
        return _generationId;
    }

    function config() external view override returns (address) {
        return _config;
    }

    function roleId() external pure override returns (bytes32) {
        return keccak256(bytes("B6PW_NEXTGEN_V1:Settlement"));
    }

    function getListing(string calldata id) external view override returns (NG.Listing memory) {
        NG.CoreBindings memory bindings = _requireSealedCore();
        bytes32 idHash_ = IOwnershipCore(bindings.ownership).idHash(id);
        NG.Listing memory listing = _listings[idHash_];
        if (listing.active && !_listingIsCurrent(bindings.ownership, idHash_, listing)) {
            listing.active = false;
        }
        return listing;
    }

    function previewListing(uint256 priceWei)
        external
        view
        override
        returns (uint256 feeWei, uint256 minimumFeeWei, uint256 oracleVersion, uint256 marketVersion)
    {
        SaleQuote memory quote = _saleQuote(priceWei);
        feeWei = quote.feeWei;
        minimumFeeWei = quote.minimumFeeWei;
        oracleVersion = quote.oracleVersion;
        marketVersion = quote.marketVersion;
    }

    function previewDirectFee() external view override returns (uint256 feeWei, uint256 oracleVersion) {
        NG.CoreBindings memory bindings = _requireSealedCore();
        NG.BusinessPolicy memory policy = IGovernanceConfig(_config).policy();
        NG.OracleState memory oracle = _oracleState();
        (, NG.EthObservation memory observation) = _readCurrentEthUsd(oracle, policy);
        feeWei = _minimumFeeWei(policy.minimumFeeUsd6, observation.ethUsd.price);
        oracleVersion = oracle.version;
        if (feeWei == 0) revert FeeBounds();
        // Keep the binding read in this path so preview cannot be used with an
        // unsealed or partially configured Core graph.
        bindings;
    }

    function list(NG.ListRequest calldata request)
        external
        override
        nonReentrant
        returns (bytes32 listingId)
    {
        NG.CoreBindings memory bindings = _requireSealedCore();
        _requireGeneration(request.generationId);
        _requireDeadline(request.deadline);
        if (request.priceWei == 0) revert FeeBounds();

        IOwnershipCore ownership = IOwnershipCore(bindings.ownership);
        bytes32 idHash_ = ownership.idHash(request.id);
        _reconcileStaleListing(bindings.ownership, idHash_);
        NG.Record memory record = ownership.getRecord(idHash_);
        if (record.owner != msg.sender) revert OwnerMismatch();
        if (record.status != NG.Lifecycle.NORMAL) revert InvalidLifecycle();
        if (record.ownershipNonce != request.expectedOwnershipNonce) {
            revert NonceMismatch();
        }
        if (_listings[idHash_].active) revert InvalidLifecycle();

        SaleQuote memory quote = _saleQuote(request.priceWei);

        if (request.expectedFeeWei != quote.feeWei || quote.feeWei > request.maxFeeWei) {
            revert FeeBounds();
        }
        if (request.expectedOracleVersion != quote.oracleVersion
            || request.expectedMarketVersion != quote.marketVersion) {
            revert VersionMismatch();
        }

        uint256 listingNonce = ownership.markListed(
            idHash_,
            msg.sender,
            request.expectedOwnershipNonce
        );
        NG.Record memory listedRecord = ownership.getRecord(idHash_);
        if (listedRecord.owner != msg.sender
            || listedRecord.status != NG.Lifecycle.LISTED
            || listedRecord.ownershipNonce != listingNonce) {
            revert InvalidLifecycle();
        }

        listingId = keccak256(abi.encode(
            _chainId,
            _generationId,
            address(this),
            idHash_,
            msg.sender,
            listingNonce
        ));
        if (listingId == bytes32(0)) revert InvalidListing();

        NG.Listing memory snapshot = NG.Listing({
            listingId: listingId,
            seller: msg.sender,
            ownershipNonce: listingNonce,
            priceWei: request.priceWei,
            feeWei: quote.feeWei,
            feeBps: quote.policy.marketFeeBps,
            minimumFeeWei: quote.minimumFeeWei,
            ethUsdPrice18: quote.observation.ethUsd.price,
            ethUsdObservedAt: quote.observation.ethUsd.observedAt,
            oracleMaxAge: quote.policy.ethUsdMaxAge,
            freeLockDuration: quote.policy.marketFreeLock,
            economicPolicyVersion: IGovernanceConfig(_config).economicPolicyVersion(),
            sourceVersion: quote.oracleVersion,
            marketVersion: quote.marketVersion,
            platformOrigin: record.platformOrigin,
            originPlatform: record.originPlatform,
            createdGeneration: record.createdGeneration,
            active: true
        });
        _listings[idHash_] = snapshot;
        emit ListingCreated(idHash_, listingId, snapshot);
    }

    function cancelListing(
        string calldata id,
        uint256 expectedNonce,
        bytes32 expectedListingId
    ) external override nonReentrant {
        NG.CoreBindings memory bindings = _requireSealedCore();
        IOwnershipCore ownership = IOwnershipCore(bindings.ownership);
        bytes32 idHash_ = ownership.idHash(id);
        _reconcileStaleListing(bindings.ownership, idHash_);
        NG.Listing storage listing = _listings[idHash_];
        if (!listing.active) revert InvalidListing();
        if (listing.listingId != expectedListingId || listing.ownershipNonce != expectedNonce) {
            revert ListingMismatch();
        }

        NG.Record memory record = ownership.getRecord(idHash_);
        if (record.owner != msg.sender) revert OwnerMismatch();
        if (record.status != NG.Lifecycle.LISTED) revert InvalidLifecycle();
        if (record.ownershipNonce != listing.ownershipNonce) {
            revert NonceMismatch();
        }

        uint256 nextNonce = ownership.cancelListed(idHash_, msg.sender, listing.ownershipNonce);
        NG.Record memory cancelledRecord = ownership.getRecord(idHash_);
        if (cancelledRecord.owner != msg.sender
            || cancelledRecord.status != NG.Lifecycle.NORMAL
            || cancelledRecord.ownershipNonce != nextNonce) {
            revert InvalidLifecycle();
        }

        listing.active = false;
        emit ListingCancelled(idHash_, expectedListingId);
    }

    function buy(NG.BuyRequest calldata request) external payable override nonReentrant {
        NG.CoreBindings memory bindings = _requireSealedCore();
        _requireGeneration(request.generationId);
        _requireDeadline(request.deadline);

        IOwnershipCore ownership = IOwnershipCore(bindings.ownership);
        IStakeLedger stake = IStakeLedger(bindings.stake);
        bytes32 idHash_ = ownership.idHash(request.id);
        _reconcileStaleListing(bindings.ownership, idHash_);
        NG.Listing storage listing = _listings[idHash_];
        if (!listing.active) revert InvalidListing();
        if (request.listingId != listing.listingId
            || request.expectedSeller != listing.seller
            || request.expectedPriceWei != listing.priceWei
            || request.expectedOwnershipNonce != listing.ownershipNonce) {
            revert ListingMismatch();
        }
        if (msg.sender == listing.seller) revert OwnerMismatch();
        if (msg.value != listing.priceWei) revert IncorrectValue();
        if (listing.feeWei > listing.priceWei) revert FeeBounds();

        NG.Record memory record = ownership.getRecord(idHash_);
        if (record.owner != listing.seller
            || record.status != NG.Lifecycle.LISTED
            || record.ownershipNonce != listing.ownershipNonce) {
            revert ListingMismatch();
        }

        address settlementFeeRecipient = IGovernanceConfig(_config).feeRecipient();
        if (settlementFeeRecipient == address(0)) revert ZeroAddress();
        _ensureSolventAfterCredit(listing.feeWei);

        stake.creditOldStake(idHash_, listing.seller, listing.ownershipNonce);
        uint256 nextNonce = ownership.settleToFreeLock(
            idHash_,
            listing.seller,
            listing.ownershipNonce,
            msg.sender,
            listing.freeLockDuration
        );
        NG.Record memory transferredRecord = ownership.getRecord(idHash_);
        if (transferredRecord.owner != msg.sender
            || transferredRecord.status != NG.Lifecycle.FREE_LOCK
            || transferredRecord.ownershipNonce != nextNonce) {
            revert InvalidLifecycle();
        }

        listing.active = false;
        _creditProtocolFee(settlementFeeRecipient, listing.feeWei);
        uint256 sellerNetWei = listing.priceWei - listing.feeWei;
        if (sellerNetWei != 0) _sendNative(listing.seller, sellerNetWei);

        emit Purchased(
            idHash_,
            listing.listingId,
            msg.sender,
            listing.seller,
            listing.priceWei,
            listing.feeWei,
            sellerNetWei,
            settlementFeeRecipient
        );
    }

    function directTransfer(NG.DirectRequest calldata request)
        external
        payable
        override
        nonReentrant
    {
        NG.CoreBindings memory bindings = _requireSealedCore();
        DirectQuote memory quote = _directQuote(bindings, request);
        if (msg.value < quote.feeWei) revert IncorrectValue();
        _ensureSolventAfterCredit(quote.feeWei);
        (uint256 nextNonce, uint256 refundWei) = _executeDirect(bindings, request, quote);

        emit DirectTransferred(
            quote.idHash,
            msg.sender,
            request.receiver,
            quote.feeWei,
            refundWei,
            nextNonce,
            quote.oracleVersion
        );
    }

    function _directQuote(NG.CoreBindings memory bindings, NG.DirectRequest calldata request)
        internal
        view
        returns (DirectQuote memory quote)
    {
        _requireGeneration(request.generationId);
        _requireDeadline(request.deadline);
        if (request.receiver == address(0) || request.receiver == msg.sender) {
            revert InvalidReceiver();
        }

        IOwnershipCore ownership = IOwnershipCore(bindings.ownership);
        quote.idHash = ownership.idHash(request.id);
        NG.Listing memory listing = _listings[quote.idHash];
        if (listing.active && _listingIsCurrent(bindings.ownership, quote.idHash, listing)) {
            revert InvalidLifecycle();
        }

        NG.Record memory record = ownership.getRecord(quote.idHash);
        if (record.owner != msg.sender) revert OwnerMismatch();
        if (record.status != NG.Lifecycle.NORMAL) revert InvalidLifecycle();
        if (record.ownershipNonce != request.expectedOwnershipNonce) {
            revert NonceMismatch();
        }

        quote.policy = IGovernanceConfig(_config).policy();
        if (quote.policy.directFreeLock == 0) revert InvalidConfiguration();
        NG.EthObservation memory observation;
        (quote.oracleVersion, observation) = _readCurrentEthUsd(
            _oracleState(),
            quote.policy
        );
        if (quote.oracleVersion != request.expectedOracleVersion) revert VersionMismatch();
        quote.feeWei = _minimumFeeWei(quote.policy.minimumFeeUsd6, observation.ethUsd.price);
        if (quote.feeWei > request.maxFeeWei) revert FeeBounds();

        quote.feeRecipient = IGovernanceConfig(_config).feeRecipient();
        if (quote.feeRecipient == address(0)) revert ZeroAddress();
    }

    function _executeDirect(
        NG.CoreBindings memory bindings,
        NG.DirectRequest calldata request,
        DirectQuote memory quote
    ) internal returns (uint256 nextNonce, uint256 refundWei) {
        IStakeLedger stake = IStakeLedger(bindings.stake);
        NG.StakeRecord memory oldStake = stake.stakeOf(quote.idHash);
        if (oldStake.active) {
            if (oldStake.owner != msg.sender) revert OwnerMismatch();
            stake.creditOldStake(quote.idHash, msg.sender, request.expectedOwnershipNonce);
        }
        nextNonce = IOwnershipCore(bindings.ownership).settleToFreeLock(
            quote.idHash,
            msg.sender,
            request.expectedOwnershipNonce,
            request.receiver,
            quote.policy.directFreeLock
        );
        NG.Record memory transferredRecord = IOwnershipCore(bindings.ownership).getRecord(quote.idHash);
        if (transferredRecord.owner != request.receiver
            || transferredRecord.status != NG.Lifecycle.FREE_LOCK
            || transferredRecord.ownershipNonce != nextNonce) {
            revert InvalidLifecycle();
        }

        refundWei = msg.value - quote.feeWei;
        _creditProtocolFee(quote.feeRecipient, quote.feeWei);
        if (refundWei != 0) _sendNative(msg.sender, refundWei);
    }

    function protocolFeeClaimable(address beneficiary) external view override returns (uint256) {
        return _protocolFeeCredits[beneficiary];
    }

    function totalProtocolFeeLiability() external view override returns (uint256) {
        return _totalProtocolFeeLiability;
    }

    function claimProtocolFees(address to) external override nonReentrant {
        if (to == address(0) || to == address(this)) revert InvalidReceiver();
        uint256 amount = _protocolFeeCredits[msg.sender];
        if (amount == 0) revert Unauthorized();
        if (_totalProtocolFeeLiability < amount || address(this).balance < amount) {
            revert Insolvent();
        }

        _protocolFeeCredits[msg.sender] = 0;
        _totalProtocolFeeLiability -= amount;
        _sendNative(to, amount);
        emit ProtocolFeeClaimed(msg.sender, to, amount);
    }

    function _saleQuote(uint256 priceWei) internal view returns (SaleQuote memory quote) {
        if (priceWei == 0) revert FeeBounds();
        quote.policy = IGovernanceConfig(_config).policy();
        if (quote.policy.marketFreeLock == 0) revert InvalidConfiguration();
        NG.OracleState memory oracle = _oracleState();
        (quote.oracleVersion, quote.observation) = _readCurrentEthUsd(oracle, quote.policy);
        quote.minimumFeeWei = _minimumFeeWei(
            quote.policy.minimumFeeUsd6,
            quote.observation.ethUsd.price
        );
        if (quote.minimumFeeWei > priceWei) revert FeeBounds();

        address module;
        bytes32 codeHash;
        (module, codeHash, quote.marketVersion) = IGovernanceConfig(_config)
            .moduleState(NG.ModuleKind.MARKET_BUSINESS);
        _assertModule(module, codeHash, quote.marketVersion);
        NG.FeeContext memory context = NG.FeeContext({
            priceWei: priceWei,
            feeBps: quote.policy.marketFeeBps,
            minimumFeeWei: quote.minimumFeeWei
        });
        quote.feeWei = _callMarketFee(module, context);
        uint256 expectedFee = _formalMarketFee(priceWei, quote.policy.marketFeeBps, quote.minimumFeeWei);
        if (quote.feeWei != expectedFee) revert FeeBounds();
    }

    function _callMarketFee(address module, NG.FeeContext memory context)
        internal
        view
        returns (uint256 feeWei)
    {
        (bool ok, bytes memory returndata) = BoundedStaticCall.callView(
            module,
            abi.encodeWithSelector(IMarketBusiness.calculateSaleFee.selector, context),
            MARKET_MODULE_GAS,
            32
        );
        if (!ok || returndata.length != 32) revert InvalidConfiguration();
        feeWei = abi.decode(returndata, (uint256));
    }

    function _formalMarketFee(uint256 priceWei, uint16 feeBps, uint256 minimumFeeWei)
        internal
        pure
        returns (uint256 feeWei)
    {
        if (priceWei == 0 || feeBps > 10_000 || minimumFeeWei > priceWei) revert FeeBounds();
        uint256 percentage = priceWei / 10_000 * feeBps + (priceWei % 10_000) * feeBps / 10_000;
        feeWei = percentage > minimumFeeWei ? percentage : minimumFeeWei;
        if (feeWei > priceWei) revert FeeBounds();
    }

    function _readCurrentEthUsd(NG.OracleState memory oracle, NG.BusinessPolicy memory policy)
        internal
        view
        returns (uint256 oracleVersion, NG.EthObservation memory observation)
    {
        if (oracle.version == 0 || oracle.directory == address(0)
            || oracle.directoryCodeHash == bytes32(0)
            || oracle.directory.codehash != oracle.directoryCodeHash
            || oracle.sourceSetHash == bytes32(0)) {
            revert OracleInvalid();
        }
        _assertIdentity(oracle.directory, _role("OracleDirectory"));

        (bool primaryOk, NG.EthObservation memory primary) = _readEthUsd(oracle.directory, false);
        if (primaryOk && _validEthObservation(primary, oracle, policy, false)) {
            return (oracle.version, primary);
        }

        if (oracle.sources.backupEnabled) {
            (bool backupOk, NG.EthObservation memory backup) = _readEthUsd(oracle.directory, true);
            if (backupOk && _validEthObservation(backup, oracle, policy, true)) {
                return (oracle.version, backup);
            }
        }
        revert OracleInvalid();
    }

    function _readEthUsd(address directory, bool useBackup)
        internal
        view
        returns (bool ok, NG.EthObservation memory observation)
    {
        bytes memory returndata;
        (ok, returndata) = BoundedStaticCall.callView(
            directory,
            abi.encodeWithSelector(IOracleDirectory.readEthUsd.selector, useBackup),
            ORACLE_READ_GAS,
            256
        );
        if (!ok || returndata.length != 256) return (false, observation);
        observation = abi.decode(returndata, (NG.EthObservation));
    }

    function _reconcileStaleListing(address ownership, bytes32 idHash_) internal {
        NG.Listing storage listing = _listings[idHash_];
        if (!listing.active) return;

        NG.Listing memory snapshot = listing;
        if (!_listingIsCurrent(ownership, idHash_, snapshot)) {
            listing.active = false;
        }
    }

    function _listingIsCurrent(address ownership, bytes32 idHash_, NG.Listing memory listing)
        internal
        view
        returns (bool)
    {
        NG.Record memory record = IOwnershipCore(ownership).getRecord(idHash_);
        if (
            record.owner != listing.seller
                || record.status != NG.Lifecycle.LISTED
                || record.ownershipNonce != listing.ownershipNonce
                || record.platformOrigin != listing.platformOrigin
        ) return false;

        if (listing.platformOrigin
            && (record.originPlatform != listing.originPlatform
                || record.createdGeneration != listing.createdGeneration)) {
            return false;
        }
        return true;
    }

    function _validEthObservation(
        NG.EthObservation memory observation,
        NG.OracleState memory oracle,
        NG.BusinessPolicy memory policy,
        bool expectedBackup
    ) internal view returns (bool) {
        NG.PriceQuote memory quote = observation.ethUsd;
        NG.SourceRoute memory route = expectedBackup ? oracle.sources.backup : oracle.sources.primary;
        if (expectedBackup && !oracle.sources.backupEnabled) return false;
        NG.PriceQuote memory canonical;
        try IGovernanceConfig(_config).validateEthUsdSource(
            expectedBackup, route.ethUsd, route.ethUsdCodeHash, route.ethUsdRevision, route.ethUsdRootId
        ) returns (NG.PriceQuote memory quote_) {
            canonical = quote_;
        } catch {
            return false;
        }
        if (
            !canonical.valid || canonical.price == 0 || canonical.decimals != 18
                || canonical.observedAt == 0 || canonical.sourceRevision != route.ethUsdRevision
        ) return false;
        if (!quote.valid || quote.price == 0 || quote.decimals != 18
            || observation.sourceVersion != oracle.version
            || observation.sourceSetHash != oracle.sourceSetHash
            || observation.usedBackup != expectedBackup
            || quote.sourceRevision != route.ethUsdRevision
            || quote.observedAt == 0 || quote.observedAt > block.timestamp
            || policy.ethUsdMaxAge == 0
            || block.timestamp - quote.observedAt > policy.ethUsdMaxAge
            || quote.price != canonical.price
            || quote.decimals != canonical.decimals
            || quote.valid != canonical.valid
            || quote.observedAt != canonical.observedAt
            || quote.sourceRevision != canonical.sourceRevision
        ) {
            return false;
        }
        return true;
    }

    function _minimumFeeWei(uint256 minimumFeeUsd6, uint256 ethUsdPrice18)
        internal
        pure
        returns (uint256)
    {
        if (minimumFeeUsd6 == 0 || ethUsdPrice18 == 0) revert FeeBounds();
        if (minimumFeeUsd6 > type(uint256).max / USD6_TO_WEI_SCALE) {
            revert FeeBounds();
        }
        uint256 numerator = minimumFeeUsd6 * USD6_TO_WEI_SCALE;
        if (ethUsdPrice18 > 1 && numerator > type(uint256).max - (ethUsdPrice18 - 1)) {
            revert FeeBounds();
        }
        return (numerator + ethUsdPrice18 - 1) / ethUsdPrice18;
    }

    function _oracleState() internal view returns (NG.OracleState memory) {
        return IGovernanceConfig(_config).oracleState();
    }

    function _requireSealedCore() internal view returns (NG.CoreBindings memory bindings) {
        IGovernanceConfig configContract = IGovernanceConfig(_config);
        if (!configContract.coreSealed()) revert CoreNotSealed();
        bindings = configContract.coreBindings();
        if (bindings.settlement != address(this)) revert InvalidConfiguration();

        _assertIdentity(_config, _role("Config"));
        _assertIdentity(bindings.ownership, _role("Ownership"));
        _assertIdentity(bindings.stake, _role("Stake"));
        _assertIdentity(bindings.settlement, _role("Settlement"));
        _assertIdentity(bindings.platformAccounting, _role("Platform"));
    }

    function _assertModule(address module, bytes32 codeHash, uint256 version) internal view {
        if (module == address(0) || module.codehash != codeHash || codeHash == bytes32(0) || version == 0) {
            revert InvalidConfiguration();
        }
        _assertIdentity(module, _role("MarketBusiness"));
    }

    function _assertIdentity(address peer, bytes32 expectedRole) internal view {
        (bool chainOk, bytes32 chainWord) = _readIdentityWord(peer, IGenerationIdentity.chainId.selector);
        if (!chainOk) revert InvalidConfiguration();
        if (uint256(chainWord) != _chainId) revert WrongChain();

        (bool generationOk, bytes32 generationWord) =
            _readIdentityWord(peer, IGenerationIdentity.generationId.selector);
        if (!generationOk) revert InvalidConfiguration();
        if (generationWord != _generationId) {
            revert WrongGeneration();
        }

        (bool configOk, bytes32 configWord) = _readIdentityWord(peer, IGenerationIdentity.config.selector);
        if (!configOk || uint256(configWord) >> 160 != 0 || address(uint160(uint256(configWord))) != _config) {
            revert InvalidConfiguration();
        }

        (bool roleOk, bytes32 roleWord) = _readIdentityWord(peer, IGenerationIdentity.roleId.selector);
        if (!roleOk || roleWord != expectedRole) {
            revert InvalidConfiguration();
        }
    }

    function _readIdentityWord(address target, bytes4 selector)
        internal
        view
        returns (bool ok, bytes32 word)
    {
        bytes memory data;
        (ok, data) = BoundedStaticCall.callView(
            target,
            abi.encodeWithSelector(selector),
            IDENTITY_READ_GAS,
            32
        );
        if (!ok || data.length != 32) return (false, bytes32(0));
        assembly {
            word := mload(add(data, 0x20))
        }
    }

    function _role(string memory alias_) internal pure returns (bytes32) {
        return keccak256(bytes.concat(bytes("B6PW_NEXTGEN_V1:"), bytes(alias_)));
    }

    function _requireGeneration(bytes32 requestGeneration) internal view {
        if (requestGeneration != _generationId) revert WrongGeneration();
    }

    function _requireDeadline(uint256 deadline) internal view {
        if (deadline == 0 || block.timestamp > deadline) revert DeadlineExpired();
    }

    function _ensureSolventAfterCredit(uint256 amount) internal view {
        if (_totalProtocolFeeLiability > type(uint256).max - amount
            || address(this).balance < _totalProtocolFeeLiability + amount) {
            revert Insolvent();
        }
    }

    function _creditProtocolFee(address beneficiary, uint256 amount) internal {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (_protocolFeeCredits[beneficiary] > type(uint256).max - amount
            || _totalProtocolFeeLiability > type(uint256).max - amount) {
            revert Insolvent();
        }
        _protocolFeeCredits[beneficiary] += amount;
        _totalProtocolFeeLiability += amount;
        emit ProtocolFeeCredited(beneficiary, amount);
    }

    function _sendNative(address to, uint256 amount) internal {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert NativeTransferFailed();
    }

    receive() external payable {
        revert UnexpectedNativeSender();
    }
}
