// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract NftAuction is ReentrancyGuard, ERC721Holder {
    enum Status {
        Active,
        Canceled,
        Ended
    }

    struct Auction {
        address seller;
        IERC721 token;
        uint256 tokenId;
        uint256 startPrice;
        uint256 minBidDiff;
        uint256 startTime;
        uint256 endTime;
        uint256 highestBidId;
        Status status;
        bool nftClaimed;
    }

    struct Bid {
        address bidder;
        uint256 amount;
        bool withdrawed;
    }

    event NewAuction(uint256 indexed auctionId, address indexed seller, IERC721 indexed token, uint256 tokenId, 
    uint256 startPrice, uint256 minBidDiff, uint256 startTime, uint256 endTime);
    event AuctionCanclled(uint256 indexed auctionId);
    event AuctionEnded(uint256 indexed auctionId);
    event NftClaimed(uint256 indexed auctionId, address indexed destAddr, IERC721 indexed token, uint256 tokenId);
    event EthClaimed(uint256 indexed auctionId, address indexed destAddr, uint256 amount);
    event NewBid(uint256 indexed auctionId, uint256 indexed bidId, address indexed bidder, uint256 bidPrice);
    event BidWithdrawed(uint256 indexed auctionId, uint256 indexed bidId);

    Auction[] public auctions;
    mapping(uint256 => Bid[]) public bids;

    //startPrice/minBidDiff in wei, startDelay/duration in second
    function newAuction(
        IERC721 token,
        uint256 tokenId,
        uint256 startPrice,
        uint256 minBidDiff,
        uint256 startDelay,
        uint256 duration
    ) public nonReentrant returns (uint256) {
        token.safeTransferFrom(msg.sender, address(this), tokenId);
        uint256 startTime = block.timestamp + startDelay;
        uint256 endTime = block.timestamp + startDelay + duration;
        auctions.push(
            Auction(
                msg.sender,
                token,
                tokenId,
                startPrice,
                minBidDiff,
                startTime,
                endTime,
                type(uint256).max,
                Status.Active,
                false
            )
        );
        uint256 auctionId = auctions.length - 1;
        emit NewAuction(auctionId, msg.sender, token, tokenId, startPrice, minBidDiff, startTime, endTime);
        return auctionId;
    }

    function cancelAuction(uint256 auctionId) public {
        require(auctionId < auctions.length, "wrong auctionId!");
        Auction memory auc = auctions[auctionId];
        require(msg.sender == auc.seller, "only seller can cancel auction!");
        require(
            auc.status == Status.Active,
            "only active auction can be cancelled!"
        );
        require(
            block.timestamp <= auc.endTime,
            "auction time is over, can not cancel!"
        );

        auctions[auctionId].status = Status.Canceled;
        emit AuctionCanclled(auctionId);
    }

    function endAuction(uint256 auctionId) public {
        require(auctionId < auctions.length, "wrong auctionId!");
        Auction memory auc = auctions[auctionId];
        require(
            auc.status == Status.Active,
            "only active auction can be ended!"
        );
        require(block.timestamp > auc.endTime, "auction is not over yet!");

        auctions[auctionId].status = Status.Ended;
        emit AuctionEnded(auctionId);
    }

    function claimNft(uint256 auctionId) public nonReentrant {
        require(auctionId < auctions.length, "wrong auctionId!");
        Auction memory auc = auctions[auctionId];
        require(
            auc.status != Status.Active,
            "can not claim nft when auction is active!"
        );
        require(!auc.nftClaimed, "nft is already claimed!");

        auctions[auctionId].nftClaimed = true;
        if (
            auc.status == Status.Ended && auc.highestBidId != type(uint256).max
        ) {
            //transfer nft to highest bidder
            address highestBidder = bids[auctionId][auc.highestBidId].bidder;
            auc.token.safeTransferFrom(
                address(this),
                highestBidder,
                auc.tokenId
            );
            emit NftClaimed(auctionId, highestBidder, auc.token, auc.tokenId);
        } else {
            //transfer nft to seller
            auc.token.safeTransferFrom(address(this), auc.seller, auc.tokenId);
            emit NftClaimed(auctionId, auc.seller, auc.token, auc.tokenId);
        }
    }

    function claimEth(uint256 auctionId) public nonReentrant {
        require(auctionId < auctions.length, "wrong auctionId!");
        Auction memory auc = auctions[auctionId];
        require(
            auc.status != Status.Active,
            "can not claim eth when auction is active!"
        );
        require(
            auc.highestBidId != type(uint256).max,
            "can not claim eth since no bid for this auction!"
        );
        Bid memory highestBid = bids[auctionId][auc.highestBidId];
        require(!highestBid.withdrawed, "eth is already withdrawed!");

        bids[auctionId][auc.highestBidId].withdrawed = true;
        if (auc.status == Status.Canceled) {
            //transfer eth to bidder
            Address.sendValue(payable(highestBid.bidder), highestBid.amount);
            emit EthClaimed(auctionId, highestBid.bidder, highestBid.amount);
        } else {
            //transfer eth to seller
            Address.sendValue(payable(auc.seller), highestBid.amount);
            emit EthClaimed(auctionId, auc.seller, highestBid.amount);
        }
    }

    //bidPrice in wei
    function bidAuction(uint256 auctionId, uint256 bidPrice)
        public
        payable
        returns (uint256)
    {
        require(bidPrice == msg.value, "bid price not same as msg.value!");
        require(auctionId < auctions.length, "wrong auctionId!");
        Auction memory auc = auctions[auctionId];
        require(auc.status == Status.Active, "can only bid on active auction!");
        require(
            block.timestamp >= auc.startTime && block.timestamp <= auc.endTime,
            "can only bid during auction time!"
        );

        if (auc.highestBidId != type(uint256).max) {
            Bid memory highestBid = bids[auctionId][auc.highestBidId];
            require(
                msg.value >= highestBid.amount + auc.minBidDiff,
                "bid price must be greater than (last bid price)+(min bid diff)!"
            );
        } else {
            require(
                msg.value >= auc.startPrice,
                "bid price must be greater than start price!"
            );
        }
        bids[auctionId].push(Bid(msg.sender, msg.value, false));
        uint256 bidId = bids[auctionId].length - 1;
        auctions[auctionId].highestBidId = bidId;
        emit NewBid(auctionId, bidId, msg.sender, bidPrice);
        return bidId;
    }

    function withdrawBid(uint256 auctionId, uint256 bidId) public nonReentrant {
        require(auctionId < auctions.length, "wrong auctionId!");
        Auction memory auc = auctions[auctionId];
        require(bidId < bids[auctionId].length, "wrong bid id!");
        require(bidId != auc.highestBidId, "can not withdraw highest bid!");
        Bid memory bid = bids[auctionId][bidId];
        require(!bid.withdrawed, "bid is already withdrawed!");
        require(
            msg.sender == bid.bidder,
            "only bidder can withdraw his/her bid!"
        );

        bids[auctionId][bidId].withdrawed = true;
        //transfer eth to bidder
        Address.sendValue(payable(bid.bidder), bid.amount);
        emit BidWithdrawed(auctionId, bidId);
    }
}
