// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";

import "hardhat/console.sol";

contract NFTMarketplaceUpgradeable is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC1155HolderUpgradeable
{
    using CountersUpgradeable for CountersUpgradeable.Counter;
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeMathUpgradeable for uint256;

    CountersUpgradeable.Counter private _itemIds; // Id for each individual item
    CountersUpgradeable.Counter private _itemsSold; // Number of items sold
    CountersUpgradeable.Counter private _itemsUnlist; // Number of items delisted

    uint256 private _fee; // This is made for owner of the file to be comissioned (percent)

    IERC20Upgradeable private _currency;
    uint256 private constant FEE_DENOMINATOR = 10**10;

    function initialize(IERC20Upgradeable currency, uint256 listingFee)
        public
        initializer
    {
        _currency = currency;
        _fee = listingFee;
        __Ownable_init();
        __ERC1155Holder_init();
        __ReentrancyGuard_init();
    }

    struct MarketItem {
        uint256 itemId;
        address nftContract;
        uint256 tokenId;
        address seller;
        address owner;
        uint256 price;
        uint256 amount;
        bool isSold;
        bool isUnlisted;
    }

    mapping(uint256 => MarketItem) private idToMarketItem;

    // Event is an inhertable contract that can be used to emit events
    event MarketItemCreated(
        uint256 indexed itemId,
        address indexed nftContract,
        uint256 indexed tokenId,
        address seller,
        address owner,
        uint256 price,
        uint256 amount,
        bool isSold,
        bool isUnlisted
    );

    event MarketItemUnlisted(
        uint256 indexed itemId,
        address indexed nftContract,
        uint256 indexed tokenId,
        address seller,
        address owner,
        uint256 price,
        uint256 amount,
        bool isSold,
        bool isUnlisted
    );

    event MarketItemSold(
        uint256 indexed itemId,
        address indexed nftContract,
        uint256 indexed tokenId,
        address seller,
        address owner,
        uint256 price,
        uint256 amount,
        bool isSold,
        bool isUnlisted
    );

    event MarketItemSetPrice(
        uint256 indexed itemId,
        address indexed nftContract,
        uint256 indexed tokenId,
        address seller,
        address owner,
        uint256 price,
        uint256 amount,
        bool isSold,
        bool isUnlisted
    );

    event SetFee(uint256 fee);

    event SetCurrency(address currency);

    function getFee() public view returns (uint256) {
        return _fee;
    }

    function setFee(uint256 fee) public onlyOwner {
        _fee = fee;
        emit SetFee(fee);
    }

    function getCurrency() public view returns (IERC20Upgradeable) {
        return _currency;
    }

    function setCurrency(address currency) public onlyOwner {
        _currency = IERC20Upgradeable(currency);
        emit SetCurrency(currency);
    }

    function createMarketItem(
        address nftContract,
        uint256 tokenId,
        uint256 price,
        uint256 amount
    ) public nonReentrant {
        require(price > 0, "No item for free here");
        require(amount > 0, "Amount must > 0");

        _itemIds.increment();
        uint256 itemId = _itemIds.current();
        idToMarketItem[itemId] = MarketItem(
            itemId,
            nftContract,
            tokenId,
            msg.sender,
            address(0), // No owner for the item
            price,
            amount,
            false,
            false
        );
        // Transfer NFT
        IERC1155Upgradeable(nftContract).safeTransferFrom(
            msg.sender,
            address(this),
            tokenId,
            amount,
            "0x0"
        );

        emit MarketItemCreated(
            itemId,
            nftContract,
            tokenId,
            msg.sender,
            address(0),
            price,
            amount,
            false,
            false
        );
    }

    function buyMarketItem(
        address nftContract,
        uint256 itemId,
        uint256 amount
    ) public nonReentrant {
        uint256 price = idToMarketItem[itemId].price;
        uint256 tokenId = idToMarketItem[itemId].tokenId;
        uint256 fee = calculateFee(amount, price);

        require(amount > 0, "Amount must > 0");
        require(
            idToMarketItem[itemId].amount >= amount,
            "Insufficient market item amount"
        );
        require(idToMarketItem[itemId].isSold != true, "This item is sold");
        require(
            idToMarketItem[itemId].isUnlisted != true,
            "This item is unlisted"
        );

        uint256 cost = idToMarketItem[itemId].price.mul(amount).sub(fee);
        require(
            _currency.balanceOf(msg.sender) >= cost,
            "Insufficient currency"
        );

        // Transfer currency to contract owner
        _currency.transferFrom(msg.sender, idToMarketItem[itemId].seller, cost);

        IERC1155Upgradeable(nftContract).safeTransferFrom(
            address(this),
            msg.sender,
            tokenId,
            amount,
            "0x0"
        );

        idToMarketItem[itemId].owner = msg.sender;

        // Transfer fee to contract owner
        _currency.transferFrom(msg.sender, owner(), fee);

        bool sold = idToMarketItem[itemId].amount == amount;
        if (sold) {
            idToMarketItem[itemId].isSold = true;
            _itemsSold.increment();
        }

        emit MarketItemSold(
            itemId,
            nftContract,
            idToMarketItem[itemId].tokenId,
            idToMarketItem[itemId].seller,
            idToMarketItem[itemId].owner,
            idToMarketItem[itemId].price,
            amount,
            sold,
            false
        );
    }

    function unlistMarketItem(address nftContract, uint256 itemId)
        public
        nonReentrant
    {
        require(idToMarketItem[itemId].isSold != true, "This item is sold");
        require(
            idToMarketItem[itemId].isUnlisted != true,
            "This item is unlisted"
        );
        require(
            msg.sender == address(idToMarketItem[itemId].seller),
            "You're not seller of this item"
        );

        IERC1155Upgradeable(nftContract).safeTransferFrom(
            address(this),
            msg.sender,
            idToMarketItem[itemId].tokenId,
            idToMarketItem[itemId].amount,
            "0x0"
        );
        
        idToMarketItem[itemId].amount = 0;
        idToMarketItem[itemId].isUnlisted = true;

        _itemsUnlist.increment();

        emit MarketItemUnlisted(
            itemId,
            nftContract,
            idToMarketItem[itemId].tokenId,
            idToMarketItem[itemId].seller,
            idToMarketItem[itemId].owner,
            idToMarketItem[itemId].price,
            idToMarketItem[itemId].amount,
            idToMarketItem[itemId].isSold,
            true
        );
    }

    function setMarketItemPrice(uint256 itemId, uint256 price)
        public
        nonReentrant
    {
        require(price > 0, "No item for free here");
        require(idToMarketItem[itemId].isSold != true, "This item is sold");
        require(
            idToMarketItem[itemId].isUnlisted != true,
            "This item is unlisted"
        );
        require(
            msg.sender == address(idToMarketItem[itemId].seller),
            "You're not seller of this item"
        );

        idToMarketItem[itemId].price = price;

        emit MarketItemSetPrice(
            itemId,
            idToMarketItem[itemId].nftContract,
            idToMarketItem[itemId].tokenId,
            idToMarketItem[itemId].seller,
            idToMarketItem[itemId].owner,
            idToMarketItem[itemId].price,
            idToMarketItem[itemId].amount,
            idToMarketItem[itemId].isSold,
            false
        );
    }

    function calculateFee(uint256 amount, uint256 price)
        public
        view
        returns (uint256 fee)
    {
        return price.mul(amount).mul(_fee).div(FEE_DENOMINATOR);
    }

    function getMarketItems() public view returns (MarketItem[] memory) {
        uint256 itemCount = _itemIds.current();
        uint256 unsoldItemCount = _itemIds.current() - _itemsSold.current();
        uint256 currentIndex = 0;

        MarketItem[] memory marketItems = new MarketItem[](unsoldItemCount);
        for (uint256 i = 0; i < itemCount; i++) {
            if (idToMarketItem[i + 1].owner == address(0)) {
                uint256 currentId = idToMarketItem[i + 1].itemId;
                MarketItem storage currentItem = idToMarketItem[currentId];
                marketItems[currentIndex] = currentItem;
                currentIndex += 1;
            }
        }
        return marketItems;
    }

    function getMarketItem(uint256 itemId)
        public
        view
        returns (MarketItem memory)
    {
        return idToMarketItem[itemId];
    }

    function fetchPurchasedNFTs() public view returns (MarketItem[] memory) {
        uint256 totalItemCount = _itemIds.current();
        uint256 itemCount = 0;
        uint256 currentIndex = 0;

        for (uint256 i = 0; i < totalItemCount; i++) {
            if (idToMarketItem[i + 1].owner == msg.sender) {
                itemCount += 1;
            }
        }

        MarketItem[] memory marketItems = new MarketItem[](itemCount);
        for (uint256 i = 0; i < totalItemCount; i++) {
            if (idToMarketItem[i + 1].owner == msg.sender) {
                uint256 currentId = idToMarketItem[i + 1].itemId;
                MarketItem storage currentItem = idToMarketItem[currentId];
                marketItems[currentIndex] = currentItem;
                currentIndex += 1;
            }
        }
        return marketItems;
    }

    function fetchCreateNFTs() public view returns (MarketItem[] memory) {
        uint256 totalItemCount = _itemIds.current();
        uint256 itemCount = 0;
        uint256 currentIndex = 0;

        for (uint256 i = 0; i < totalItemCount; i++) {
            if (idToMarketItem[i + 1].seller == msg.sender) {
                itemCount += 1; // No dynamic length. Predefined length has to be made
            }
        }

        MarketItem[] memory marketItems = new MarketItem[](itemCount);
        for (uint256 i = 0; i < totalItemCount; i++) {
            if (idToMarketItem[i + 1].seller == msg.sender) {
                uint256 currentId = idToMarketItem[i + 1].itemId;
                MarketItem storage currentItem = idToMarketItem[currentId];
                marketItems[currentIndex] = currentItem;
                currentIndex += 1;
            }
        }
        return marketItems;
    }
}
