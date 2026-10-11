pragma solidity 0.8.24;

import {ICustody} from "../interfaces/ICustody.sol";
import {IGenerationIdentity} from "../interfaces/IGenerationIdentity.sol";
import {IGovernanceConfig} from "../interfaces/IGovernanceConfig.sol";
import {IOwnershipCore} from "../interfaces/IOwnershipCore.sol";
import {IPlatformAccounting} from "../interfaces/IPlatformAccounting.sol";
import {ISettlementKernel} from "../interfaces/ISettlementKernel.sol";
import {BoundedStaticCall} from "../libraries/BoundedStaticCall.sol";
import {NG} from "../interfaces/NextGenTypes.sol";
import "../interfaces/NextGenErrors.sol";
import {NextGenEvents} from "../interfaces/NextGenEvents.sol";

contract B6PWOwnershipCoreNG is IOwnershipCore, NextGenEvents {
    uint256 private constant MAX_ID_LENGTH = 12;
    uint256 private constant MAX_DESCRIPTION_BYTES = 1_200;
    uint256 private constant MAX_DESCRIPTION_CODEPOINTS = 300;
    uint256 private constant MAX_RESOLUTION_BYTES = 1_024;
    uint256 private constant PLATFORM_ASSERT_GAS = 100_000;
    uint256 private constant PLATFORM_ASSERT_MAX_RETURN_DATA = 128;

    bytes32 private constant OWNERSHIP_ROLE = keccak256("B6PW_NEXTGEN_V1:Ownership");
    bytes32 private constant STAKE_ROLE = keccak256("B6PW_NEXTGEN_V1:Stake");
    bytes32 private constant SETTLEMENT_ROLE = keccak256("B6PW_NEXTGEN_V1:Settlement");
    bytes32 private constant PLATFORM_ROLE = keccak256("B6PW_NEXTGEN_V1:Platform");

    address private immutable _config;
    uint256 private immutable _chainId;
    bytes32 private immutable _generationId;

    mapping(bytes32 idHash => NG.Record record) private _records;
    mapping(bytes32 idHash => uint256 nextInstanceId) private _nextInstanceId;
    mapping(bytes32 idHash => uint256 nextOwnershipNonce) private _nextOwnershipNonce;

    constructor(address config_) {
        if (config_ == address(0) || config_.code.length == 0) revert InvalidConfiguration();
        uint256 configuredChain = IGovernanceConfig(config_).chainId();
        bytes32 configuredGeneration = IGovernanceConfig(config_).generationId();
        if (configuredChain == 0 || configuredGeneration == bytes32(0)) revert InvalidConfiguration();
        _config = config_;
        _chainId = configuredChain;
        _generationId = configuredGeneration;
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
        return OWNERSHIP_ROLE;
    }

    function normalizeId(string calldata id) external pure override returns (string memory) {
        return _canonicalize(id);
    }

    function idHash(string calldata id) external pure override returns (bytes32) {
        return keccak256(bytes(_canonicalize(id)));
    }

    function isAvailable(string calldata id) external view override returns (bool) {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        bytes32 hash = keccak256(bytes(_canonicalize(id)));
        NG.Record memory record = _effectiveRecord(hash, bindings.platformAccounting);
        return record.status == NG.Lifecycle.RELEASED;
    }

    function getRecord(bytes32 idHash_) external view override returns (NG.Record memory) {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        return _effectiveRecord(idHash_, bindings.platformAccounting);
    }

    function ownerOf(bytes32 idHash_) external view override returns (address) {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        NG.Record memory record = _effectiveRecord(idHash_, bindings.platformAccounting);
        return record.status == NG.Lifecycle.RELEASED ? address(0) : record.owner;
    }

    function ownershipNonceOf(bytes32 idHash_) external view override returns (uint256) {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        NG.Record memory record = _effectiveRecord(idHash_, bindings.platformAccounting);
        return record.ownershipNonce;
    }

    function setDescription(string calldata id, string calldata description) external override {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        _validateDescription(description);
        bytes32 hash = keccak256(bytes(_canonicalize(id)));
        NG.Record storage record = _records[hash];
        _requireOwnerMetadata(record, hash, bindings.platformAccounting);
        record.description = description;
        emit MetadataChanged(hash, record.description, record.resolution);
    }

    function setResolution(string calldata id, string calldata resolution) external override {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        _validateResolution(resolution);
        bytes32 hash = keccak256(bytes(_canonicalize(id)));
        NG.Record storage record = _records[hash];
        _requireOwnerMetadata(record, hash, bindings.platformAccounting);
        record.resolution = resolution;
        emit MetadataChanged(hash, record.description, record.resolution);
    }

    function createOrdinary(string calldata id, address owner, string calldata description, string calldata resolution)
        external
        override
        returns (bytes32 idHash_, uint256 nonce)
    {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        if (msg.sender != bindings.stake) revert Unauthorized();
        if (owner == address(0)) revert ZeroAddress();
        _validateDescription(description);
        _validateResolution(resolution);
        string memory canonical = _canonicalize(id);
        idHash_ = keccak256(bytes(canonical));
        if (!_isAvailableHash(idHash_, bindings.platformAccounting)) revert IdUnavailable();
        (nonce,) = _createRecord(idHash_, owner, description, resolution, false, address(0), 0);
    }

    function createPlatform(string calldata id, address custody, address originPlatform, uint256 createdGeneration)
        external
        override
        returns (bytes32 idHash_, uint256 nonce, uint256 instanceId)
    {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        if (msg.sender != bindings.platformAccounting) revert Unauthorized();
        if (custody == address(0) || custody.code.length == 0 || originPlatform == address(0) || createdGeneration == 0) {
            revert InvalidConfiguration();
        }
        if (ICustody(payable(custody)).config() != _config || ICustody(payable(custody)).generationId() != _generationId) {
            revert CustodyBindingMismatch();
        }
        string memory canonical = _canonicalize(id);
        idHash_ = keccak256(bytes(canonical));
        if (!_isAvailableHash(idHash_, bindings.platformAccounting)) revert IdUnavailable();
        (nonce, instanceId) = _createRecord(idHash_, custody, "", "", true, originPlatform, createdGeneration);
    }

    function markListed(bytes32 idHash_, address expectedOwner, uint256 expectedNonce)
        external
        override
        returns (uint256 listingNonce)
    {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        if (msg.sender != bindings.settlement) revert Unauthorized();
        NG.Record storage record = _records[idHash_];
        _requireLive(record, idHash_, bindings.platformAccounting);
        if (record.status != NG.Lifecycle.NORMAL || record.owner != expectedOwner) revert OwnerMismatch();
        if (record.ownershipNonce != expectedNonce) revert NonceMismatch();
        _assertAttachedOrigin(record, idHash_, bindings.platformAccounting);
        record.status = NG.Lifecycle.LISTED;
        listingNonce = _advanceNonce(idHash_, record);
        emit OwnershipChanged(idHash_, expectedOwner, expectedOwner, record.instanceId, listingNonce, uint8(record.status));
    }

    function cancelListed(bytes32 idHash_, address expectedOwner, uint256 expectedNonce)
        external
        override
        returns (uint256 nextNonce)
    {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        if (msg.sender != bindings.settlement) revert Unauthorized();
        NG.Record storage record = _records[idHash_];
        _requireLive(record, idHash_, bindings.platformAccounting);
        if (record.status != NG.Lifecycle.LISTED || record.owner != expectedOwner) revert OwnerMismatch();
        if (record.ownershipNonce != expectedNonce) revert NonceMismatch();
        _assertAttachedOrigin(record, idHash_, bindings.platformAccounting);
        record.status = NG.Lifecycle.NORMAL;
        nextNonce = _advanceNonce(idHash_, record);
        emit OwnershipChanged(idHash_, expectedOwner, expectedOwner, record.instanceId, nextNonce, uint8(record.status));
    }

    function settleToFreeLock(
        bytes32 idHash_,
        address expectedOwner,
        uint256 expectedNonce,
        address receiver,
        uint64 lockDuration
    ) external override returns (uint256 nextNonce) {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        if (msg.sender != bindings.settlement) revert Unauthorized();
        if (receiver == address(0)) revert InvalidReceiver();
        if (lockDuration == 0) revert InvalidConfiguration();
        NG.Record storage record = _records[idHash_];
        _requireLive(record, idHash_, bindings.platformAccounting);
        if (
            (record.status != NG.Lifecycle.NORMAL && record.status != NG.Lifecycle.LISTED)
                || record.owner != expectedOwner
        ) revert OwnerMismatch();
        if (record.ownershipNonce != expectedNonce) revert NonceMismatch();
        _assertAttachedOrigin(record, idHash_, bindings.platformAccounting);
        uint256 expiry = block.timestamp + uint256(lockDuration);
        if (expiry > type(uint64).max) revert InvalidConfiguration();
        bool wasPlatform = record.platformOrigin;
        address origin = record.originPlatform;
        uint256 createdGeneration = record.createdGeneration;
        uint256 instanceId = record.instanceId;
        if (wasPlatform) {
            IPlatformAccounting(bindings.platformAccounting).detachOrigin(
                idHash_, expectedOwner, expectedNonce, instanceId, createdGeneration
            );
        }
        record.owner = receiver;
        record.status = NG.Lifecycle.FREE_LOCK;
        record.freeLockExpiresAt = expiry;
        record.stakeComplete = false;
        record.platformOrigin = false;
        record.originPlatform = address(0);
        record.createdGeneration = 0;
        nextNonce = _advanceNonce(idHash_, record);
        emit OwnershipChanged(idHash_, expectedOwner, receiver, record.instanceId, nextNonce, uint8(record.status));
        emit FreeLockStarted(idHash_, nextNonce, expiry);
        if (wasPlatform) emit PlatformDetached(idHash_, origin, createdGeneration);
    }

    function completeFreeLock(bytes32 idHash_, address expectedOwner, uint256 expectedNonce)
        external
        override
        returns (uint256 nextNonce)
    {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        if (msg.sender != bindings.stake) revert Unauthorized();
        NG.Record storage record = _records[idHash_];
        _requireLive(record, idHash_, bindings.platformAccounting);
        if (record.status != NG.Lifecycle.FREE_LOCK || record.owner != expectedOwner) revert OwnerMismatch();
        if (record.ownershipNonce != expectedNonce) revert NonceMismatch();
        if (block.timestamp >= record.freeLockExpiresAt) revert FreeLockExpired();
        if (record.stakeComplete) revert InvalidLifecycle();
        record.status = NG.Lifecycle.NORMAL;
        record.freeLockExpiresAt = 0;
        record.stakeComplete = true;
        nextNonce = _advanceNonce(idHash_, record);
        emit OwnershipChanged(idHash_, expectedOwner, expectedOwner, record.instanceId, nextNonce, uint8(record.status));
    }

    function releaseOrdinary(bytes32 idHash_, address expectedOwner, uint256 expectedNonce)
        external
        override
        returns (uint256 nextNonce)
    {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        if (msg.sender != bindings.stake) revert Unauthorized();
        NG.Record storage record = _records[idHash_];
        _requireLive(record, idHash_, bindings.platformAccounting);
        if (
            record.status != NG.Lifecycle.NORMAL
                || record.owner != expectedOwner
                || record.platformOrigin
                || !record.stakeComplete
        ) revert InvalidLifecycle();
        if (record.ownershipNonce != expectedNonce) revert NonceMismatch();
        nextNonce = _releaseRecord(idHash_, record);
    }

    function releaseExpired(string calldata id) external override {
        _requireIdentity();
        NG.CoreBindings memory bindings = _requireSealed();
        bytes32 hash = keccak256(bytes(_canonicalize(id)));
        NG.Record storage record = _records[hash];
        if (record.status == NG.Lifecycle.NORMAL || record.status == NG.Lifecycle.LISTED) {
            (bool invalidated, bool known) = _isPlatformInvalidated(record, hash, bindings.platformAccounting);
            if (!record.platformOrigin || !known || !invalidated) {
                revert InvalidLifecycle();
            }
        } else if (record.status == NG.Lifecycle.FREE_LOCK) {
            if (block.timestamp < record.freeLockExpiresAt) revert FreeLockExpired();
        } else {
            revert InvalidLifecycle();
        }
        _releaseRecord(hash, record);
    }

    function _createRecord(
        bytes32 idHash_,
        address owner,
        string memory description,
        string memory resolution,
        bool platformOrigin,
        address originPlatform,
        uint256 createdGeneration
    ) private returns (uint256 nonce, uint256 instanceId) {
        NG.Record storage existing = _records[idHash_];
        if (existing.owner != address(0) && existing.status != NG.Lifecycle.RELEASED) {
            bool logicallyReleased = existing.status == NG.Lifecycle.FREE_LOCK
                && block.timestamp >= existing.freeLockExpiresAt;
            if (existing.platformOrigin && !logicallyReleased) {
                (bool invalidated, bool known) =
                    _isPlatformInvalidated(existing, idHash_, _requireSealed().platformAccounting);
                if (!known) revert InvalidLifecycle();
                logicallyReleased = invalidated;
            }
            if (logicallyReleased) _releaseRecord(idHash_, existing);
        }
        instanceId = ++_nextInstanceId[idHash_];
        if (instanceId == 0) revert InvalidConfiguration();
        nonce = _nextOwnershipNonce[idHash_];
        if (nonce == 0) nonce = 1;
        _nextOwnershipNonce[idHash_] = nonce + 1;
        _records[idHash_] = NG.Record({
            owner: owner,
            status: NG.Lifecycle.NORMAL,
            ownershipNonce: nonce,
            instanceId: instanceId,
            freeLockExpiresAt: 0,
            stakeComplete: true,
            platformOrigin: platformOrigin,
            originPlatform: originPlatform,
            createdGeneration: createdGeneration,
            description: description,
            resolution: resolution
        });
        emit OwnershipChanged(idHash_, address(0), owner, instanceId, nonce, uint8(NG.Lifecycle.NORMAL));
    }

    function _requireOwnerMetadata(NG.Record storage record, bytes32 idHash_, address platformAccounting) private view {
        if (record.owner == address(0) || record.status == NG.Lifecycle.RELEASED) revert InvalidLifecycle();
        if (record.status == NG.Lifecycle.FREE_LOCK && block.timestamp >= record.freeLockExpiresAt) {
            revert FreeLockExpired();
        }
        if (record.status == NG.Lifecycle.LISTED) revert InvalidLifecycle();
        if (record.platformOrigin) {
            (bool invalidated, bool known) = _isPlatformInvalidated(record, idHash_, platformAccounting);
            if (!known || invalidated) revert InvalidLifecycle();
        }
        if (record.owner != msg.sender) revert OwnerMismatch();
    }

    function _requireLive(NG.Record storage record, bytes32 idHash_, address platformAccounting) private view {
        if (record.owner == address(0) || record.status == NG.Lifecycle.RELEASED) revert InvalidLifecycle();
        if (record.platformOrigin) {
            (bool invalidated, bool known) = _isPlatformInvalidated(record, idHash_, platformAccounting);
            if (!known || invalidated) revert InvalidLifecycle();
        }
    }

    function _assertAttachedOrigin(NG.Record storage record, bytes32 idHash_, address platformAccounting) private view {
        if (record.platformOrigin) {
            (bool invalidated, bool known) = _isPlatformInvalidated(record, idHash_, platformAccounting);
            if (!known || invalidated) revert InvalidLifecycle();
        }
    }

    function _effectiveRecord(bytes32 idHash_, address platformAccounting)
        private
        view
        returns (NG.Record memory record)
    {
        record = _records[idHash_];
        if (record.owner == address(0) || record.status == NG.Lifecycle.RELEASED) {
            return _logicalReleasedRecord(idHash_);
        }
        if (record.status == NG.Lifecycle.FREE_LOCK && block.timestamp >= record.freeLockExpiresAt) {
            return _logicalReleasedRecord(idHash_);
        }
        if (record.platformOrigin) {
            (bool invalidated, bool known) = _isPlatformInvalidated(record, idHash_, platformAccounting);
            if (!known) revert InvalidLifecycle();
            if (invalidated) {
                return _logicalReleasedRecord(idHash_);
            }
        }
    }

    function _logicalReleasedRecord(bytes32 idHash_) private view returns (NG.Record memory record) {
        record.status = NG.Lifecycle.RELEASED;
        uint256 nextNonce = _nextOwnershipNonce[idHash_];
        if (_records[idHash_].owner != address(0) && nextNonce != type(uint256).max) ++nextNonce;
        record.ownershipNonce = nextNonce;
    }

    function _isAvailableHash(bytes32 idHash_, address platformAccounting) private view returns (bool) {
        NG.Record memory record = _effectiveRecord(idHash_, platformAccounting);
        return record.status == NG.Lifecycle.RELEASED;
    }

    function _isPlatformInvalidated(NG.Record memory record, bytes32 idHash_, address platformAccounting)
        private
        view
        returns (bool invalidated, bool known)
    {
        (bool ok, bytes memory data) = BoundedStaticCall.callView(
            platformAccounting,
            abi.encodeWithSelector(
                IPlatformAccounting.assertOriginActive.selector,
                idHash_,
                record.owner,
                record.ownershipNonce,
                record.instanceId,
                record.createdGeneration
            ),
            PLATFORM_ASSERT_GAS,
            PLATFORM_ASSERT_MAX_RETURN_DATA
        );
        if (ok && data.length == 0) return (false, true);
        if (!ok && _isInvalidPlatformGenerationError(data)) return (true, true);
        // Unknown revert data, an out-of-gas call, or malformed success data
        // is not proof that a platform generation was invalidated.
        return (false, false);
    }

    function _isInvalidPlatformGenerationError(bytes memory data) private pure returns (bool) {
        if (data.length < 4) return false;
        bytes4 selector;
        assembly {
            selector := mload(add(data, 32))
        }
        return selector == InvalidPlatformGeneration.selector;
    }

    function _advanceNonce(bytes32 idHash_, NG.Record storage record) private returns (uint256) {
        if (record.ownershipNonce == type(uint256).max) revert InvalidConfiguration();
        uint256 previousNonce = record.ownershipNonce;
        record.ownershipNonce += 1;
        if (record.ownershipNonce == type(uint256).max) revert InvalidConfiguration();
        _nextOwnershipNonce[idHash_] = record.ownershipNonce + 1;
        if (record.platformOrigin) {
            IPlatformAccounting(_requireSealed().platformAccounting).syncOriginNonce(
                idHash_, record.owner, previousNonce, record.ownershipNonce, record.instanceId, record.createdGeneration
            );
        }
        return record.ownershipNonce;
    }

    function _releaseRecord(bytes32 idHash_, NG.Record storage record) private returns (uint256 nextNonce) {
        address previousOwner = record.owner;
        uint256 instanceId = record.instanceId;
        nextNonce = _advanceNonce(idHash_, record);
        delete _records[idHash_];
        emit OwnershipChanged(idHash_, previousOwner, address(0), instanceId, nextNonce, uint8(NG.Lifecycle.RELEASED));
    }

    function _requireIdentity() private view {
        if (block.chainid != _chainId) revert WrongChain();
    }

    function _requireSealed() private view returns (NG.CoreBindings memory bindings) {
        if (!IGovernanceConfig(_config).coreSealed()) revert CoreNotSealed();
        bindings = IGovernanceConfig(_config).coreBindings();
        if (bindings.ownership != address(this)) revert CustodyBindingMismatch();
        _validatePeer(bindings.stake, STAKE_ROLE);
        _validatePeer(bindings.settlement, SETTLEMENT_ROLE);
        _validatePeer(bindings.platformAccounting, PLATFORM_ROLE);
    }

    function _validatePeer(address peer, bytes32 expectedRole) private view {
        if (peer == address(0) || peer.code.length == 0) revert CustodyBindingMismatch();
        if (
            IGenerationIdentity(peer).chainId() != _chainId
                || IGenerationIdentity(peer).generationId() != _generationId
                || IGenerationIdentity(peer).config() != _config
                || IGenerationIdentity(peer).roleId() != expectedRole
        ) revert CustodyBindingMismatch();
    }

    function _canonicalize(string memory id) private pure returns (string memory canonical) {
        bytes memory raw = bytes(id);
        if (raw.length == 0 || raw.length > MAX_ID_LENGTH) revert InvalidId();
        bytes memory normalized = new bytes(raw.length);
        for (uint256 i; i < raw.length; ++i) {
            uint8 value = uint8(raw[i]);
            if (value >= 0x41 && value <= 0x5a) {
                normalized[i] = bytes1(value + 0x20);
            } else if ((value >= 0x61 && value <= 0x7a) || (value >= 0x30 && value <= 0x39)) {
                normalized[i] = raw[i];
            } else {
                revert InvalidId();
            }
        }
        canonical = string(normalized);
    }

    function _validateDescription(string memory description) private pure {
        bytes memory raw = bytes(description);
        if (raw.length > MAX_DESCRIPTION_BYTES) revert InvalidMetadata();
        _validateUtf8(raw, MAX_DESCRIPTION_CODEPOINTS);
    }

    function _validateResolution(string memory resolution) private pure {
        bytes memory raw = bytes(resolution);
        if (raw.length > MAX_RESOLUTION_BYTES) revert InvalidMetadata();
        _validateUtf8(raw, type(uint256).max);
    }

    function _validateUtf8(bytes memory raw, uint256 maxCodepoints) private pure {
        uint256 index = 0;
        uint256 count = 0;
        while (index < raw.length) {
            uint8 first = uint8(raw[index]);
            uint256 codepoint;
            uint256 width;
            if (first <= 0x7f) {
                codepoint = first;
                width = 1;
            } else if (first >= 0xc2 && first <= 0xdf) {
                width = 2;
                if (index + 1 >= raw.length || !_isContinuation(uint8(raw[index + 1]))) revert InvalidMetadata();
                codepoint = (first & 0x1f) * 0x40 + (uint8(raw[index + 1]) & 0x3f);
            } else if (first >= 0xe0 && first <= 0xef) {
                width = 3;
                if (index + 2 >= raw.length || !_isContinuation(uint8(raw[index + 2]))) revert InvalidMetadata();
                uint8 second = uint8(raw[index + 1]);
                if (!_isContinuation(second)) revert InvalidMetadata();
                if ((first == 0xe0 && second < 0xa0) || (first == 0xed && second >= 0xa0)) revert InvalidMetadata();
                codepoint = (first & 0x0f) * 0x1000 + (second & 0x3f) * 0x40 + (uint8(raw[index + 2]) & 0x3f);
            } else if (first >= 0xf0 && first <= 0xf4) {
                width = 4;
                if (index + 3 >= raw.length) revert InvalidMetadata();
                uint8 second = uint8(raw[index + 1]);
                if (!_isContinuation(second) || !_isContinuation(uint8(raw[index + 2])) || !_isContinuation(uint8(raw[index + 3]))) {
                    revert InvalidMetadata();
                }
                if ((first == 0xf0 && second < 0x90) || (first == 0xf4 && second >= 0x90)) revert InvalidMetadata();
                codepoint = (first & 0x07) * 0x40000
                    + (second & 0x3f) * 0x1000
                    + (uint8(raw[index + 2]) & 0x3f) * 0x40
                    + (uint8(raw[index + 3]) & 0x3f);
            } else {
                revert InvalidMetadata();
            }
            if (codepoint > 0x10ffff || (codepoint >= 0xd800 && codepoint <= 0xdfff)) revert InvalidMetadata();
            ++count;
            if (count > maxCodepoints) revert InvalidMetadata();
            index += width;
        }
    }

    function _isContinuation(uint8 value) private pure returns (bool) {
        return value >= 0x80 && value <= 0xbf;
    }
}
