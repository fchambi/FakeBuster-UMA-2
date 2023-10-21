// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@uma/core/contracts/optimistic-oracle-v3/implementation/ClaimData.sol";
import "@uma/core/contracts/optimistic-oracle-v3/interfaces/OptimisticOracleV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// This Isurance contract enables for the issuance of a single unlimited time policy per event/payout recipient There is
// no limit to the number of payout requests that can be made of the same policy; however, only the first asserted
// request will settle the insurance payment, whereas OOv3 will settle bonds for all requestors.
contract Publisher {


    address public owner;

    using SafeERC20 for IERC20;
    IERC20 public immutable defaultCurrency;
    OptimisticOracleV3Interface public immutable oo;
    uint64 public constant assertionLiveness = 100;
    bytes32 public immutable defaultIdentifier;

    uint256 public rewardCount;
    uint256 public postCount;

    mapping(uint256 => Reward) public rewards;
    mapping(uint256 => Post) public posts;

    
    event PostPublished(address indexed publisher, uint256 postNumber);
    event RewardClaimed(address indexed publisher, uint256 rewardAmount);

    struct Post {
        address author;
        bytes postContent;
        uint256 rewardId;
    }

    struct Reward {
        uint256 rewardAmount;
        uint256 remainingPosts;
    }

    struct Policy {
        uint256 insuranceAmount;
        address payoutAddress;
        bytes insuredEvent;
        bool settled;
    }

    mapping(bytes32 => bytes32) public assertedPolicies;
    mapping(bytes32 => Policy) public policies;

    event InsuranceIssued(
        bytes32 indexed policyId,
        bytes insuredEvent,
        uint256 insuranceAmount,
        address indexed payoutAddress
    );

    event InsurancePayoutRequested(bytes32 indexed policyId, bytes32 indexed assertionId);

    event InsurancePayoutSettled(bytes32 indexed policyId, bytes32 indexed assertionId);

    constructor(address _defaultCurrency, address _optimisticOracleV3) {
        defaultCurrency = IERC20(_defaultCurrency);
        oo = OptimisticOracleV3Interface(_optimisticOracleV3);
        defaultIdentifier = oo.defaultIdentifier();
        owner=msg.sender;
    }

    function createReward(uint256 _rewardAmount, uint256 _remainingPosts) external {
        require(msg.sender == owner, "Only the owner can create rewards.");
        rewardCount++;
        rewards[rewardCount] = Reward(_rewardAmount, _remainingPosts);
    }

    function publishPost(bytes memory postContent) external {
        require(rewardCount > 0, "No rewards available.");
        uint256 rewardId = rewardCount;
        Reward storage reward = rewards[rewardId];
        require(reward.remainingPosts > 0, "No remaining posts for this reward.");

        postCount++;
        reward.remainingPosts--;

        posts[postCount] = Post({
            author: msg.sender,
            postContent: postContent,
            rewardId: rewardId
        });

        bytes32 policyId = keccak256(postContent);
        uint256 bond = oo.getMinimumBond(address(token));
        token.safeTransferFrom(msg.sender, address(this), bond);
        token.safeApprove(address(oo), bond);
        bytes32 assertionId = oo.assertTruth(
            abi.encodePacked(
                "Publisher is claiming the following post: ",
                postContent
            ),
            msg.sender,
            address(this),
            address(0), // No sovereign security.
            assertionLiveness,
            token,
            bond,
            defaultIdentifier,
            bytes32(0) // No domain.
        );

        emit PostPublished(msg.sender, postCount);
    }

     function claimReward(uint256 postId) external {
        Post storage post = posts[postId];
        require(post.author == msg.sender, "You are not the author of this post.");
        uint256 rewardId = post.rewardId;
        Reward storage reward = rewards[rewardId];
        require(reward.rewardAmount > 0, "No reward available for this post.");

        uint256 rewardAmount = reward.rewardAmount;
        reward.rewardAmount = 0; // Mark reward as claimed
        token.safeTransfer(msg.sender, rewardAmount);

        emit RewardClaimed(msg.sender, rewardAmount);
    }

    function ownerWithdrawTokens() external {
        require(msg.sender == owner, "Only the owner can withdraw tokens.");
        token.safeTransfer(owner, token.balanceOf(address(this)));
    }



    function issueInsurance(
        uint256 insuranceAmount,
        address payoutAddress,
        bytes memory insuredEvent
    ) public returns (bytes32 policyId) {
        policyId = keccak256(abi.encode(insuredEvent, payoutAddress));
        require(policies[policyId].payoutAddress == address(0), "Policy already exists");
        policies[policyId] = Policy({
            insuranceAmount: insuranceAmount,
            payoutAddress: payoutAddress,
            insuredEvent: insuredEvent,
            settled: false
        });
        defaultCurrency.safeTransferFrom(msg.sender, address(this), insuranceAmount);
        emit InsuranceIssued(policyId, insuredEvent, insuranceAmount, payoutAddress);
    }

    function requestPayout(bytes32 policyId) public returns (bytes32 assertionId) {
        require(policies[policyId].payoutAddress != address(0), "Policy does not exist");
        uint256 bond = oo.getMinimumBond(address(defaultCurrency));
        defaultCurrency.safeTransferFrom(msg.sender, address(this), bond);
        defaultCurrency.safeApprove(address(oo), bond);
        assertionId = oo.assertTruth(
            abi.encodePacked(
                "Insurance contract is claiming that insurance event ",
                policies[policyId].insuredEvent,
                " had occurred as of ",
                ClaimData.toUtf8BytesUint(block.timestamp),
                "."
            ),
            msg.sender,
            address(this),
            address(0), // No sovereign security.
            assertionLiveness,
            defaultCurrency,
            bond,
            defaultIdentifier,
            bytes32(0) // No domain.
        );
        assertedPolicies[assertionId] = policyId;
        emit InsurancePayoutRequested(policyId, assertionId);
    }

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) public {
        require(msg.sender == address(oo));
        // If the assertion was true, then the policy is settled.
        if (assertedTruthfully) {
            _settlePayout(assertionId);
        }
    }

    function assertionDisputedCallback(bytes32 assertionId) public {}

    function _settlePayout(bytes32 assertionId) internal {
        // If already settled, do nothing. We don't revert because this function is called by the
        // OptimisticOracleV3, which may block the assertion resolution.
        bytes32 policyId = assertedPolicies[assertionId];
        Policy storage policy = policies[policyId];
        if (policy.settled) return;
        policy.settled = true;
        defaultCurrency.safeTransfer(policy.payoutAddress, policy.insuranceAmount);
        emit InsurancePayoutSettled(policyId, assertionId);
    }
}
