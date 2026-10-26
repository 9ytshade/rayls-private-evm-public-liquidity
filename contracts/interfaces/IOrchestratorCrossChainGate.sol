// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IOrchestratorCrossChainGate
 * @notice Interface for the Rayls Orchestrator Privacy Network Cross-Chain Settlement Gate.
 * @dev Coordinates zero-knowledge cross-chain commitments, homomorphic netting epochs,
 *      and dual-authority regulatory viewing key delegation across Sovereign Subnets and Public L1.
 */
interface IOrchestratorCrossChainGate {
    struct ZKCommitment {
        bytes32 commitmentHash;
        bytes encryptedPayload;
        bytes ephemeralPublicKey;
        bytes zkProof;
    }

    struct NettingBatch {
        uint256 epochId;
        bytes32 previousNettingRoot;
        bytes32 newNettingRoot;
        bytes32[] participantSubnets;
        int256[] netResidualBalances;
        bytes zkBatchProof;
    }

    struct ViewingAuthority {
        address regulator;
        bytes32 jurisdictionScope;
        uint256 expirationTimestamp;
        bool isActive;
    }

    // Custom Error Declarations
    error InvalidProofSignature();
    error CommitmentAlreadyProcessed(bytes32 commitmentHash);
    error EpochAlreadySettled(uint256 epochId);
    error NettingBatchImbalanced(int256 totalResidualSum);
    error NettingRootMismatch(bytes32 expectedRoot, bytes32 providedRoot);
    error ViewingKeyUnauthorized(address caller, bytes32 scope);
    error InvalidArrayLength();

    // Events
    event CommitmentQueued(
        bytes32 indexed commitmentHash,
        address indexed sourceSubnet,
        uint256 timestamp
    );

    event NettingSettled(
        uint256 indexed epochId,
        bytes32 indexed newNettingRoot,
        uint256 participantCount,
        uint256 timestamp
    );

    event ViewingAuthorityDelegated(
        address indexed institution,
        address indexed regulator,
        bytes32 indexed jurisdictionScope,
        uint256 expirationTimestamp
    );

    event ViewingAuthorityRevoked(
        address indexed institution,
        address indexed regulator,
        bytes32 indexed jurisdictionScope
    );

    function submitCommitment(ZKCommitment calldata commitment) external returns (bool);
    function settleNettingEpoch(NettingBatch calldata batch) external returns (bool);
    function delegateViewingAuthority(address regulator, bytes32 jurisdictionScope, uint256 validityDuration) external returns (bool);
    function revokeViewingAuthority(address regulator, bytes32 jurisdictionScope) external returns (bool);
    function verifyViewingKeyAccess(address institution, address regulator, bytes32 scope) external view returns (bool);
}
