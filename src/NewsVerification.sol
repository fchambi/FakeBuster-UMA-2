// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@uma/core/contracts/optimistic-oracle-v3/implementation/ClaimData.sol";
import "@uma/core/contracts/optimistic-oracle-v3/interfaces/OptimisticOracleV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract NewsVerification{
    

    uint256 public counter;
    using SafeERC20 for IERC20;
    IERC20 public immutable defaultCurrency;
    OptimisticOracleV3Interface public immutable oo;
    uint64 public constant assertionLiveness = 7200;
    bytes32 public immutable defaultIdentifier;

    struct NewsArticle {
        uint256 reward;
        address verifierAddress;
        bytes newsContent;
        bool verified;
    }

    mapping(bytes32 => bytes32) public assertedNews;

    mapping(bytes32 => NewsArticle) public newsArticles;

    event NewsVerified(
        bytes32 indexed articleId,
        bytes newsContent,
        uint256 reward,
        address indexed verifierAddress
    );

    event RewardPayoutRequested(bytes32 indexed articleId, bytes32 indexed assertionId);

    event RewardPayoutSettled(bytes32 indexed articleId, bytes32 indexed assertionId);

    constructor(address _defaultCurrency, address _optimisticOracleV3) {
        defaultCurrency = IERC20(_defaultCurrency);
        oo = OptimisticOracleV3Interface(_optimisticOracleV3);
        defaultIdentifier = oo.defaultIdentifier();
        counter=0;
    }

    function verifyNews(
        uint256 reward,
        bytes memory newsContent
    ) public returns (bytes32 articleId) {

        address verifierAddress = address(0);
        articleId = keccak256(abi.encode(newsContent, verifierAddress,counter));
        newsArticles[articleId] = NewsArticle({
            reward: reward,
            verifierAddress: verifierAddress,
            newsContent: newsContent,
            verified: false
        });
        defaultCurrency.safeTransferFrom(msg.sender, address(this), reward);
        counter += 1;
        emit NewsVerified(articleId, newsContent, reward, verifierAddress);
    }

    function requestPayout(bytes32 articleId) public returns (bytes32 assertionId) {
        require(newsArticles[articleId].verifierAddress == address(0), "NewsArticle does not exist");
        uint256 bond = oo.getMinimumBond(address(defaultCurrency));
        newsArticles[articleId].verifierAddress = msg.sender;
        defaultCurrency.safeTransferFrom(msg.sender, address(this), bond);
        defaultCurrency.safeApprove(address(oo), bond);
        assertionId = oo.assertTruth(
            abi.encodePacked(
                "NewsVerification contract is claiming that insurance event ",
                newsArticles[articleId].newsContent,
                " had occurred as of ",
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
        assertedNews[assertionId] = articleId;
        emit RewardPayoutRequested(articleId, assertionId);
    }

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) public {
        require(msg.sender == address(oo));
        // If the assertion was true, then the article is verified.
        if (assertedTruthfully) {
            _settlePayout(assertionId);
        }
    }

    function assertionDisputedCallback(bytes32 assertionId) public {}

    function _settlePayout(bytes32 assertionId) internal {

        bytes32 articleId = assertedNews[assertionId];
        NewsArticle storage article = newsArticles[articleId];
        if (article.verified) return;
        article.verified = true;
        defaultCurrency.safeTransfer(article.verifierAddress, article.reward);
        emit RewardPayoutSettled(articleId, assertionId);
    }
}
