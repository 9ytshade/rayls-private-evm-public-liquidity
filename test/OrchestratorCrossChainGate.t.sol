// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {OrchestratorCrossChainGate} from "../contracts/OrchestratorCrossChainGate.sol";
import {IOrchestratorCrossChainGate} from "../contracts/interfaces/IOrchestratorCrossChainGate.sol";

contract OrchestratorCrossChainGateTest is Test {
    OrchestratorCrossChainGate public gate;

    bytes32 public constant INITIAL_ROOT = keccak256("INITIAL_GENESIS_ROOT");
    bytes32 public constant SCOPE_DREX = keccak256("BRAZIL_BACEN_DREX");
    bytes32 public constant SCOPE_MICA = keccak256("EU_ESMA_MICA");

    address public bankA;
    address public bankB;
    address public bankC;
    address public centralBankRegulator;
    address public unauthorizedObserver;

    function setUp() public {
        gate = new OrchestratorCrossChainGate(INITIAL_ROOT);
        bankA = makeAddr("bankA");
        bankB = makeAddr("bankB");
        bankC = makeAddr("bankC");
        centralBankRegulator = makeAddr("BACEN_Supervisor");
        unauthorizedObserver = makeAddr("unauthorizedObserver");

        vm.label(bankA, "Tier1Bank_A");
        vm.label(bankB, "Tier1Bank_B");
        vm.label(bankC, "CentralBank_C");
        vm.label(centralBankRegulator, "BACEN_Supervisor");
    }

    // Helper to generate valid simulated ZK proof matching the commitment
    function _generateValidZKProof(bytes32 targetHash) internal pure returns (bytes memory) {
        bytes memory proof = new bytes(64);
        assembly {
            mstore(add(proof, 32), targetHash)
            mstore(add(proof, 64), 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef)
        }
        return proof;
    }

    // =========================================================================
    // 1. COMMITMENT SUBMISSION TESTS
    // =========================================================================

    function test_SubmitValidCommitment_Success() public {
        bytes32 commitmentHash = keccak256("SUBMISSION_TX_001");
        bytes memory proof = _generateValidZKProof(commitmentHash);

        IOrchestratorCrossChainGate.ZKCommitment memory commitment = IOrchestratorCrossChainGate.ZKCommitment({
            commitmentHash: commitmentHash,
            encryptedPayload: hex"1234567890abcdef",
            ephemeralPublicKey: hex"02aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            zkProof: proof
        });

        vm.prank(bankA);
        bool success = gate.submitCommitment(commitment);
        assertTrue(success, "Commitment submission should succeed");
        assertTrue(gate.processedCommitments(commitmentHash), "Commitment should be marked processed");
    }

    function test_RevertIf_CommitmentReplayed() public {
        bytes32 commitmentHash = keccak256("REPLAY_TX");
        bytes memory proof = _generateValidZKProof(commitmentHash);

        IOrchestratorCrossChainGate.ZKCommitment memory commitment = IOrchestratorCrossChainGate.ZKCommitment({
            commitmentHash: commitmentHash,
            encryptedPayload: hex"12345678",
            ephemeralPublicKey: hex"02aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            zkProof: proof
        });

        vm.prank(bankA);
        gate.submitCommitment(commitment);

        // Attempt second submission with same commitment hash
        vm.prank(bankA);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrchestratorCrossChainGate.CommitmentAlreadyProcessed.selector,
                commitmentHash
            )
        );
        gate.submitCommitment(commitment);
    }

    function test_RevertIf_ZKProofInvalid() public {
        bytes32 commitmentHash = keccak256("TAMPERED_TX");
        bytes32 wrongTag = keccak256("WRONG_TAG");
        bytes memory badProof = _generateValidZKProof(wrongTag);

        IOrchestratorCrossChainGate.ZKCommitment memory commitment = IOrchestratorCrossChainGate.ZKCommitment({
            commitmentHash: commitmentHash,
            encryptedPayload: hex"12345678",
            ephemeralPublicKey: hex"02aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            zkProof: badProof
        });

        vm.prank(bankA);
        vm.expectRevert(IOrchestratorCrossChainGate.InvalidProofSignature.selector);
        gate.submitCommitment(commitment);
    }

    // =========================================================================
    // 2. MULTILATERAL HOMOMORPHIC NETTING TESTS
    // =========================================================================

    function test_SettleNettingEpoch_Success() public {
        uint256 epochId = 1;
        bytes32 prevRoot = INITIAL_ROOT;

        bytes32[] memory participants = new bytes32[](3);
        participants[0] = bytes32(uint256(uint160(bankA)));
        participants[1] = bytes32(uint256(uint160(bankB)));
        participants[2] = bytes32(uint256(uint160(bankC)));

        // Netting residual conservation: +50M, -20M, -30M => Sum = 0
        int256[] memory residuals = new int256[](3);
        residuals[0] = 50_000_000 * 1e18;
        residuals[1] = -20_000_000 * 1e18;
        residuals[2] = -30_000_000 * 1e18;

        bytes32 expectedNewRoot = keccak256(
            abi.encode(prevRoot, epochId, participants, residuals)
        );
        bytes memory batchProof = _generateValidZKProof(expectedNewRoot);

        IOrchestratorCrossChainGate.NettingBatch memory batch = IOrchestratorCrossChainGate.NettingBatch({
            epochId: epochId,
            previousNettingRoot: prevRoot,
            newNettingRoot: expectedNewRoot,
            participantSubnets: participants,
            netResidualBalances: residuals,
            zkBatchProof: batchProof
        });

        bool success = gate.settleNettingEpoch(batch);
        assertTrue(success, "Batch netting settlement should succeed");
        assertEq(gate.currentNettingRoot(), expectedNewRoot, "Root should update to expected root");
        assertEq(gate.currentEpochId(), epochId, "Epoch ID should advance");
        assertTrue(gate.settledEpochs(epochId), "Epoch should be marked settled");
    }

    function test_RevertIf_NettingBatchImbalanced() public {
        uint256 epochId = 1;
        bytes32 prevRoot = INITIAL_ROOT;

        bytes32[] memory participants = new bytes32[](2);
        participants[0] = bytes32(uint256(uint160(bankA)));
        participants[1] = bytes32(uint256(uint160(bankB)));

        // Imbalanced residuals: +50M, -40M => Sum = +10M (Violates Liquidity Conservation)
        int256[] memory residuals = new int256[](2);
        residuals[0] = 50_000_000 * 1e18;
        residuals[1] = -40_000_000 * 1e18;
        int256 expectedSum = 10_000_000 * 1e18;

        bytes32 expectedNewRoot = keccak256(
            abi.encode(prevRoot, epochId, participants, residuals)
        );
        bytes memory batchProof = _generateValidZKProof(expectedNewRoot);

        IOrchestratorCrossChainGate.NettingBatch memory batch = IOrchestratorCrossChainGate.NettingBatch({
            epochId: epochId,
            previousNettingRoot: prevRoot,
            newNettingRoot: expectedNewRoot,
            participantSubnets: participants,
            netResidualBalances: residuals,
            zkBatchProof: batchProof
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IOrchestratorCrossChainGate.NettingBatchImbalanced.selector,
                expectedSum
            )
        );
        gate.settleNettingEpoch(batch);
    }

    function test_RevertIf_NettingRootMismatch() public {
        uint256 epochId = 1;
        bytes32 prevRoot = INITIAL_ROOT;

        bytes32[] memory participants = new bytes32[](2);
        participants[0] = bytes32(uint256(uint160(bankA)));
        participants[1] = bytes32(uint256(uint160(bankB)));

        int256[] memory residuals = new int256[](2);
        residuals[0] = 10_000_000 * 1e18;
        residuals[1] = -10_000_000 * 1e18;

        bytes32 forgedRoot = keccak256("FORGED_UNVERIFIED_ROOT");
        bytes memory batchProof = _generateValidZKProof(forgedRoot);

        IOrchestratorCrossChainGate.NettingBatch memory batch = IOrchestratorCrossChainGate.NettingBatch({
            epochId: epochId,
            previousNettingRoot: prevRoot,
            newNettingRoot: forgedRoot,
            participantSubnets: participants,
            netResidualBalances: residuals,
            zkBatchProof: batchProof
        });

        // Contract computes genuine hash and detects mismatch
        bytes32 genuineComputedRoot = keccak256(
            abi.encode(prevRoot, epochId, participants, residuals)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IOrchestratorCrossChainGate.NettingRootMismatch.selector,
                genuineComputedRoot,
                forgedRoot
            )
        );
        gate.settleNettingEpoch(batch);
    }

    // =========================================================================
    // 3. REGULATORY VIEWING KEY AUDITABILITY TESTS
    // =========================================================================

    function test_ViewingAuthorityDelegationAndVerification() public {
        uint256 duration = 30 days;

        // Bank A delegates viewing authority to Central Bank regulator
        vm.prank(bankA);
        gate.delegateViewingAuthority(centralBankRegulator, SCOPE_DREX, duration);

        // Verification query for regulator should be TRUE
        bool hasAccess = gate.verifyViewingKeyAccess(bankA, centralBankRegulator, SCOPE_DREX);
        assertTrue(hasAccess, "Central bank regulator should have verified viewing access");

        // Unauthorized observer query should be FALSE
        bool unauthorizedAccess = gate.verifyViewingKeyAccess(bankA, unauthorizedObserver, SCOPE_DREX);
        assertFalse(unauthorizedAccess, "Unauthorized observer must be denied viewing access");

        // Query with different jurisdiction scope should be FALSE
        bool micaAccess = gate.verifyViewingKeyAccess(bankA, centralBankRegulator, SCOPE_MICA);
        assertFalse(micaAccess, "Regulator without MiCA delegation must be denied");
    }

    function test_ViewingAuthorityExpiration() public {
        uint256 duration = 7 days;

        vm.prank(bankA);
        gate.delegateViewingAuthority(centralBankRegulator, SCOPE_DREX, duration);

        // Advance block timestamp past expiration
        vm.warp(block.timestamp + 8 days);

        bool expiredAccess = gate.verifyViewingKeyAccess(bankA, centralBankRegulator, SCOPE_DREX);
        assertFalse(expiredAccess, "Expired viewing authority must return false");
    }

    function test_ViewingAuthorityRevocation() public {
        uint256 duration = 30 days;

        vm.prank(bankA);
        gate.delegateViewingAuthority(centralBankRegulator, SCOPE_DREX, duration);
        assertTrue(gate.verifyViewingKeyAccess(bankA, centralBankRegulator, SCOPE_DREX));

        // Bank A explicitly revokes authority
        vm.prank(bankA);
        gate.revokeViewingAuthority(centralBankRegulator, SCOPE_DREX);

        assertFalse(gate.verifyViewingKeyAccess(bankA, centralBankRegulator, SCOPE_DREX), "Revoked authority must return false");
    }
}
