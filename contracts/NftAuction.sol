// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

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
        uint256 lastBidPrice;
        address lastBidder;
        Status status;
    }

    event NftTransferError(address destAddr, uint256 tokenId);
    event EthTransferError(address destAddr, uint256 tokenAmount);

    Auction[] public auctions;

    //startPrice in wei, startDelay/duration in second
    function newAuction(IERC721 token, uint256 tokenId, uint256 startPrice, uint256 minBidDiff, 
      uint256 startDelay, uint256 duration) public nonReentrant returns (uint256) {
        token.safeTransferFrom(msg.sender, address(this), tokenId);
        auctions.push(Auction(msg.sender, token, tokenId, startPrice, minBidDiff, block.timestamp + startDelay, 
          block.timestamp + startDelay + duration, 0, address(0), Status.Active));
        return auctions.length - 1;
    }

    function cancelAuction(uint256 auctionId) public nonReentrant {
        require(auctionId < auctions.length, "wrong auctionId!");
        Auction memory auc = auctions[auctionId];
        require(msg.sender == auc.seller, "only seller can cancel auction!");
        require(auc.status == Status.Active, "only active auction can be cancelled!");
        require(block.timestamp <= auc.endTime, "auction time is over, can not cancel!");

        auctions[auctionId].status = Status.Canceled;
        //transfer nft to seller
        try auc.token.safeTransferFrom{gas: 5000}(address(this), auc.seller, auc.tokenId) {            
        } catch {
            emit NftTransferError(auc.seller, auc.tokenId);
        }
        //transfer ether to last bidder
        if(auc.lastBidder != address(0)) {
            (bool success, ) = auc.lastBidder.call{gas: 5000, value: auc.lastBidPrice}("");
            if(!success) {
                emit EthTransferError(auc.lastBidder, auc.lastBidPrice);
            }
        }
    }

    function endAuction(uint256 auctionId) public nonReentrant {
        require(auctionId < auctions.length, "wrong auctionId!");
        Auction memory auc = auctions[auctionId];
        require(auc.status == Status.Active, "only active auction can be ended!");
        require(block.timestamp > auc.endTime, "auction is not over yet!");

        auctions[auctionId].status = Status.Ended;
        if(auc.lastBidder != address(0)) {
            //transfer nft to last bidder
            try auc.token.safeTransferFrom{gas: 5000}(address(this), auc.lastBidder, auc.tokenId) {
            } catch {
                emit NftTransferError(auc.lastBidder, auc.tokenId);
            }
            //transfer ether to seller
            (bool success, ) = auc.seller.call{gas: 5000, value: auc.lastBidPrice}("");
            if(!success) {
                emit EthTransferError(auc.seller, auc.lastBidPrice);
            }
        } else {
            //no bidder, transfer nft to seller
            try auc.token.safeTransferFrom{gas: 5000}(address(this), auc.seller, auc.tokenId) {
            } catch {
                emit NftTransferError(auc.seller, auc.tokenId);
            }
        }
    }

    //bidPrice in wei
    function bid(uint256 auctionId, uint256 bidPrice) public payable nonReentrant {
        require(bidPrice == msg.value, "bid price not same as msg.value!");
        require(auctionId < auctions.length, "wrong auctionId!");
        Auction memory auc = auctions[auctionId];
        require(auc.status == Status.Active, "can only bid on active auction!");
        require(block.timestamp >= auc.startTime && block.timestamp <= auc.endTime, "can only bid during auction time!");

        if(auc.lastBidder != address(0)) {
            require(msg.value >= auc.lastBidPrice + auc.minBidDiff, "bid price must be greater than (last bid price)+(min bid diff)!");
            //send last bid price to last bidder
            (bool success, ) = auc.lastBidder.call{gas: 5000, value: auc.lastBidPrice}("");
            if(!success) {
                emit EthTransferError(auc.lastBidder, auc.lastBidPrice);
            }
        } else {
            require(msg.value >= auc.startPrice, "bid price must be greater than start price!");
        }
        auctions[auctionId].lastBidder = msg.sender;
        auctions[auctionId].lastBidPrice = msg.value;
    }
}
