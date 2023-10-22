// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@uma/core/contracts/optimistic-oracle-v3/implementation/ClaimData.sol";
import "@uma/core/contracts/optimistic-oracle-v3/interfaces/OptimisticOracleV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


contract Newsreward {
    using SafeERC20 for IERC20;
    IERC20 public immutable defaultCurrency;
    OptimisticOracleV3Interface public immutable oo;
    uint64 public constant assertionLiveness = 7200;
    bytes32 public immutable defaultIdentifier;

    struct Post {
        uint256 rewardAmount;
        address payoutAddress;
        bytes descriptionPost;
        bool settled;
    }

    mapping(bytes32 => bytes32) public assertedPosts;

    mapping(bytes32 => Post) public posts;

    event PostIssued(
        bytes32 indexed postId,
        bytes descriptionPost,
        uint256 rewardAmount,
        address indexed payoutAddress
    );

    event PostPayoutRequested(bytes32 indexed postId, bytes32 indexed assertionId);

    event PostPayoutSettled(bytes32 indexed postId, bytes32 indexed assertionId);

    constructor(address _defaultCurrency, address _optimisticOracleV3) {
        defaultCurrency = IERC20(_defaultCurrency);
        oo = OptimisticOracleV3Interface(_optimisticOracleV3);
        defaultIdentifier = oo.defaultIdentifier();
    }

    function issuePost(
        uint256 rewardAmount,
        address payoutAddress,
        bytes memory descriptionPost
    ) public returns (bytes32 postId) {
        postId = keccak256(abi.encode(descriptionPost, payoutAddress));
        require(posts[postId].payoutAddress == address(0), "post already exists");
        posts[postId] = Post({
            rewardAmount: rewardAmount,
            payoutAddress: payoutAddress,
            descriptionPost: descriptionPost,
            settled: false
        });
        defaultCurrency.safeTransferFrom(msg.sender, address(this), rewardAmount);
        emit PostIssued(postId, descriptionPost, rewardAmount, payoutAddress);
    }

    function requestPayout(bytes32 postId) public returns (bytes32 assertionId) {
        require(posts[postId].payoutAddress != address(0), "post does not exist");
        uint256 bond = oo.getMinimumBond(address(defaultCurrency));
        defaultCurrency.safeTransferFrom(msg.sender, address(this), bond);
        defaultCurrency.safeApprove(address(oo), bond);
        assertionId = oo.assertTruth(
            abi.encodePacked(
                "Insurance contract is claiming that insurance event ",
                posts[postId].descriptionPost,
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
        assertedPosts[assertionId] = postId;
        emit PostPayoutRequested(postId, assertionId);
    }

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) public {
        require(msg.sender == address(oo));
        // If the assertion was true, then the post is settled.
        if (assertedTruthfully) {
            _settlePayout(assertionId);
        }
    }

    function assertionDisputedCallback(bytes32 assertionId) public {}

    function _settlePayout(bytes32 assertionId) internal {
        // If already settled, do nothing. We don't revert because this function is called by the
        // OptimisticOracleV3, which may block the assertion resolution.
        bytes32 postId = assertedPosts[assertionId];
        Post storage post = posts[postId];
        if (post.settled) return;
        post.settled = true;
        defaultCurrency.safeTransfer(post.payoutAddress, post.rewardAmount);
        emit PostPayoutSettled(postId, assertionId);
    }
}
