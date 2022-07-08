// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract ParkingSpace is ERC721, ERC721URIStorage, Ownable {
    using Counters for Counters.Counter;

    Counters.Counter private totalParkings;
    Counters.Counter private blacklistCount;

    // additional time given to renters to close their account with a rented lot
    uint256 additionalTime;

    address payable contractOwner;

    // keeps track of the addresses that has been blacklisted
    mapping(address => bool) public blacklisted;

    uint256 fee; //mintFee
    uint256 maxLotPerWallet;

    // this keeps tracks parking lots each wallet is renting
    mapping(address => uint256) public parkingLotsPerWallet;

    mapping(uint256 => Lot) private parkingLots;
    mapping(uint256 => uint256) public lotPrice;

    enum Listing {
        Sale,
        Rent,
        Rented,
        Unavailable
    }

    // integrate image, name, description to ipfs
    struct Lot {
        address payable lender;
        address payable renter;
        // price is per day
        uint256 price;
        // deposit is a percentage
        uint256 deposit;
        uint256 returnDay;
        uint256 rentTime;
        Listing status;
    }

    constructor() ERC721("ParkingSpace", "PS") {
        // 5 hours additional time for user to end due rent
        additionalTime = 5 hours;
        contractOwner = payable(msg.sender);
        maxLotPerWallet = 10;
        fee = 1 ether;
    }

    // checks if desired lot is available
    modifier isAvailable(uint256 tokenId) {
        require(
            parkingLots[tokenId].status == Listing.Rent,
            "Parking lot is current unavailable!"
        );
        _;
    }

    // this checks if the renting period of a lot is over
    // this modifier also gives a deadline of 2 days to the renter to close his account with the current lot
    modifier rentOver(uint256 tokenId) {
        require(
            block.timestamp > parkingLots[tokenId].returnDay + additionalTime &&
                parkingLots[tokenId].status == Listing.Rent,
            "Someone has already rented this lot!"
        );
        _;
    }

    // checks if current wallet has already reached the limit of lots they can rent
    modifier lotLimit() {
        require(
            parkingLotsPerWallet[msg.sender] <= maxLotPerWallet,
            "You have reached the number of Lots you can rent"
        );
        _;
    }

    // creates a parking lot
    function createLot(string memory uri) public payable lotLimit {
        require(bytes(uri).length > 15, "Uri has to be valid");
        require(msg.value == fee, "You need to pay the mint fee");

        uint256 tokenId = totalParkings.current();
        totalParkings.increment();
        //@notice Lot.renter is initialized in the same way as the lender
        parkingLots[tokenId] = Lot(
            payable(msg.sender),
            payable(msg.sender),
            0, // price initialised as zero
            0, //deposit initialised as zero
            0, //returnDay initialised as zero
            0, //rentTime initialised as zero
            Listing.Unavailable
        );
        parkingLotsPerWallet[msg.sender]++;

        // fee is paid
        (bool success, ) = contractOwner.call{value: msg.value}("");
        require(success, "Payment failed for mint fee");

        _safeMint(msg.sender, tokenId);
        _setTokenURI(tokenId, uri);
    }

    function toggleStatusHelper(uint256 option, uint256 tokenId) private {
        if (ownerOf(tokenId) == address(this) && (option == 1 || option == 2)) {
            _transfer(address(this), msg.sender, tokenId);
            require(
                ownerOf(tokenId) == msg.sender,
                "Safe transfer of NFT failed"
            );
        } else if (ownerOf(tokenId) == msg.sender && option == 0) {
            _transfer(msg.sender, address(this), tokenId);
            require(
                ownerOf(tokenId) == address(this),
                "Safe transfer of NFT failed"
            );
        }
    }

    function toggleStatus(uint256 option, uint256 tokenId)
        public
        returns (uint256)
    {
        Lot storage currentLot = parkingLots[tokenId];
        if (option == 0) {
            currentLot.status = Listing.Sale;
            toggleStatusHelper(option, tokenId);
        }
        if (option == 1) {
            currentLot.status = Listing.Rent;
            _approve(address(this), tokenId);
            toggleStatusHelper(option, tokenId);
        }
        if (option == 2) {
            currentLot.status = Listing.Unavailable;
            toggleStatusHelper(option, tokenId);
        }

        return uint256(currentLot.status);
    }

    function buyLot(uint256 tokenId) public payable {
        Lot storage currentLot = parkingLots[tokenId];
        require(
            msg.value == lotPrice[tokenId],
            "You need to match the selling price"
        );
        require(currentLot.status == Listing.Sale, "Lot isn't on sale");
        require(msg.sender != currentLot.lender, "You can't buy your own Lot");

        address payable lotOwner = currentLot.lender;
        currentLot.lender = payable(msg.sender);
        currentLot.renter = payable(msg.sender);
        lotPrice[tokenId] = 0;
        currentLot.status = Listing.Unavailable;
        _transfer(address(this), msg.sender, tokenId);
        uint256 amount = msg.value;
        (bool success, ) = lotOwner.call{value: amount}("");
        require(success, "Payment to buy lot failed");
    }

    function setLotPrice(uint256 tokenId, uint256 price) public {
        Lot storage currentLot = parkingLots[tokenId];
        require(price > 0, "Enter valid price");
        require(
            msg.sender == currentLot.lender,
            "Only the owner can perform this action"
        );
        lotPrice[tokenId] = price;
    }

    function setRent(
        uint256 tokenId,
        uint256 price,
        uint256 deposit
    ) public {
        Lot storage currentLot = parkingLots[tokenId];
        require(
            price > 0 && deposit <= 100,
            "Enter valid price and depsoit amount"
        );
        require(
            msg.sender == currentLot.lender,
            "Only the owner can perform this action"
        );
        currentLot.price = price;
        currentLot.deposit = deposit;
    }

    // Rents a selected Lot to the caller
    function rentLot(uint256 tokenId, uint256 _time)
        public
        payable
        isAvailable(tokenId)
        rentOver(tokenId)
    {
        require(
            !blacklisted[msg.sender],
            "you are blacklisted from using the platform"
        );
        Lot storage currentLot = parkingLots[tokenId];
        require(
            msg.sender != currentLot.renter,
            "You are currently renting this apartment"
        );
        // _time is in seconds so it is converted into days
        uint256 rentingTime = _time / 3600 / 24;
        // deposit is calculated bv the percentage set by lender multiplied by the total fee
        uint256 amount = (parkingLots[tokenId].deposit / 100) *
            (parkingLots[tokenId].price * rentingTime);
        require(msg.value == amount, "You need to pay to rent lot");
        currentLot.renter = payable(msg.sender);
        currentLot.rentTime = _time;
        currentLot.returnDay = block.timestamp + _time;
        currentLot.status = Listing.Rented;
        _transfer(currentLot.lender, msg.sender, tokenId);
        _approve(address(this), tokenId);
        (bool success, ) = currentLot.lender.call{value: amount}("");
        require(success, "Payment to rent lot failed");
    }

    function endRentHelper(uint256 tokenId) internal {
        Lot storage currentLot = parkingLots[tokenId];
        // Changes is made to the lot to make it available for renting again
        currentLot.returnDay = 0;
        currentLot.rentTime = 0;
        currentLot.renter = payable(currentLot.lender);
        currentLot.status = Listing.Rent;
    }

    // this function is used by the renter to end the rent and pay the remaining fees(if any) to the lender
    function clientEndRent(uint256 tokenId) public payable {
        Lot storage currentLot = parkingLots[tokenId];
        require(
            currentLot.renter == msg.sender,
            "Only the renter can end the rent"
        );
        require(
            block.timestamp <= currentLot.returnDay + additionalTime,
            "You have been blacklisted due to late return of lot"
        );

        // if deposit is 100% then there is no need to pay the lender again
        if (currentLot.deposit < 100) {
            uint256 rentingTime = (block.timestamp - currentLot.returnDay) /
                3600 /
                24;
            uint256 amount = ((100 - parkingLots[tokenId].deposit) / 100) *
                (parkingLots[tokenId].price * rentingTime);
            require(
                msg.value == amount,
                "You need to pay the remaining fees to end rent"
            );
            (bool success, ) = currentLot.lender.call{value: amount}("");
            require(success, "Payment to end rent failed");
        }
        endRentHelper(tokenId);
    }

    // this function is used by the lender in the situation that the renter hasn't return the lot after the deadline and additional time
    function lenderEndRent(uint256 tokenId) public payable {
        Lot storage currentLot = parkingLots[tokenId];
        require(
            currentLot.lender == msg.sender,
            "Only lender can end the rent"
        );
        require(
            block.timestamp > currentLot.returnDay + additionalTime,
            "There is still time left for renter to return the lot!"
        );
        blacklistCount.increment();
        // renter is now blacklisted
        blacklisted[currentLot.renter] = true;
        endRentHelper(tokenId);
    }

    function getLot(uint256 tokenId) public view returns (Lot memory) {
        require(_exists(tokenId));
        return parkingLots[tokenId];
    }

    function getRentPrice(uint256 tokenId, uint256 _time)
        public
        view
        returns (uint256)
    {
        uint256 amount = (parkingLots[tokenId].deposit / 100) *
            (parkingLots[tokenId].price * (_time / 1 days));
        return amount;
    }

    function getParkingLotsLength() public view returns (uint256) {
        return totalParkings.current();
    }

    function getBlacklistCount() public view returns (uint256) {
        return blacklistCount.current();
    }

    function getMaxLotPerWallet() public view returns (uint256) {
        return maxLotPerWallet;
    }

    function getFees() public view returns (uint256) {
        return fee;
    }

    // The following functions are overrides required by Solidity.

    // Changes is made to approve to prevent the renter from stealing the token
    function approve(address to, uint256 _tokenId) public override {
        require(
            msg.sender == parkingLots[_tokenId].lender,
            "Caller has to be owner of NFT"
        );
        super.approve(to, _tokenId);
    }

    /**
     * @dev See {IERC721-transferFrom}.
     * Changes is made to approve to prevent the renter from stealing the token
     */
    function transferFrom(
        address from,
        address to,
        uint256 _tokenId
    ) public override {
        require(
            msg.sender == parkingLots[_tokenId].lender,
            "Caller has to be owner of NFT"
        );
        super.transferFrom(from, to, _tokenId);
    }

    /**
     * @dev See {IERC721-safeTransferFrom}.
     * Changes is made to approve to prevent the renter from stealing the token
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 _tokenId,
        bytes memory data
    ) public override {
        require(
            msg.sender == parkingLots[_tokenId].lender,
            "Caller has to be owner of NFT"
        );
        _safeTransfer(from, to, _tokenId, data);
    }

    function _burn(uint256 tokenId)
        internal
        override(ERC721, ERC721URIStorage)
    {
        super._burn(tokenId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }
}
