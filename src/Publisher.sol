// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@uma/core/contracts/optimistic-oracle-v3/implementation/ClaimData.sol";
import "@uma/core/contracts/optimistic-oracle-v3/interfaces/OptimisticOracleV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Publisher{

    uint256 public counter;
    using SafeERC20 for IERC20;
    IERC20 public immutable defaultCurrency;
    OptimisticOracleV3Interface public immutable oo;
    uint64 public constant assertionLiveness = 7200;
    bytes32 public immutable defaultIdentifier;

    struct News {
        uint256 rewardAmount;
        address payoutAddress;
        bytes newsEvent;
        bool settled;
    }

    mapping(bytes32 => bytes32) public assertedNews;

    mapping(bytes32 => News) public newsArticles;

    event NewsPublished(
        bytes32 indexed newsId,
        bytes newsEvent,
        uint256 rewardAmount,
        address indexed payoutAddress
    );

    event RewardPayoutRequested(bytes32 indexed newsId, bytes32 indexed assertionId);

    event RewardPayoutSettled(bytes32 indexed newsId, bytes32 indexed assertionId);

    constructor(address _defaultCurrency, address _optimisticOracleV3) {
        defaultCurrency = IERC20(_defaultCurrency);
        oo = OptimisticOracleV3Interface(_optimisticOracleV3);
        defaultIdentifier = oo.defaultIdentifier();
        counter=0;
    }

    function publishNews(
        uint256 rewardAmount
    ) public returns (bytes32 newsId) {
        
        bytes memory newsEvent = "Subir Noticia";
        address payoutAddress = address(0);
        newsId = keccak256(abi.encode(newsEvent,payoutAddress,counter));
        newsArticles[newsId] = News({
            rewardAmount: rewardAmount,
            payoutAddress: payoutAddress,
            newsEvent: newsEvent,
            settled: false
        });
        defaultCurrency.safeTransferFrom(msg.sender, address(this), rewardAmount);
        counter += 1;
        emit NewsPublished(newsId, newsEvent, rewardAmount, payoutAddress);
    }


    function requestPayout(bytes32 newsId,bytes memory newsEvent)public returns (bytes32 assertionId) {
        require(newsArticles[newsId].payoutAddress == address(0), "News does not exist");
        newsArticles[newsId].newsEvent = newsEvent;
        newsArticles[newsId].payoutAddress = msg.sender;
        uint256 bond = oo.getMinimumBond(address(defaultCurrency));
        defaultCurrency.safeTransferFrom(msg.sender, address(this), bond);
        defaultCurrency.safeApprove(address(oo), bond);
        assertionId = oo.assertTruth(
            abi.encodePacked(
                "News publisher is claiming that the news article ",
                newsArticles[newsId].newsEvent,
                " deserves a reward as of  ",
                ClaimData.toUtf8BytesUint(block.timestamp),
                "."
            ),
            msg.sender,
            address(this),
            address(0), 
            assertionLiveness,
            defaultCurrency,
            bond,
            defaultIdentifier,
            bytes32(0) 
        );
        assertedNews[assertionId] = newsId;
        emit RewardPayoutRequested(newsId, assertionId);
    }

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) public {
        require(msg.sender == address(oo));
        if (assertedTruthfully) {
            _settlePayout(assertionId);
        }
    }

    function assertionDisputedCallback(bytes32 assertionId) public {}

    function _settlePayout(bytes32 assertionId) internal {
        bytes32 newsId = assertedNews[assertionId];
        News storage news = newsArticles[newsId];
        if (news.settled) return;
        news.settled = true;
        defaultCurrency.safeTransfer(news.payoutAddress, news.rewardAmount);
        emit RewardPayoutSettled(newsId, assertionId);
    }
}