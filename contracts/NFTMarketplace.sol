// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import "hardhat/console.sol";

contract NFTMarketplace is
  Initializable,
  Ownable,
  ReentrancyGuard,
  ERC1155Holder
{
  using Counters for Counters.Counter;
  using SafeERC20 for IERC20;
  using SafeMath for uint256;

  Counters.Counter private itemIds; // ID for each individual item
  Counters.Counter private itemsSelling; // ID for each individual item

  IERC20 private currency;

  uint256 private fee; // The percentage that game creator will get from each sale
  uint256 private constant FEE_DENOMINATOR = 10**10;
  address private candidateOwner;
  mapping(uint256 => MarketItem) private idToMarketItem;


  struct OwnerInfo {
    address owner;
    uint256 amount;
    uint256 atBlock;
  }

  struct MarketItem {
    uint256 itemId;
    address nftContract;
    uint256 tokenId;
    address seller;
    mapping(uint256 => OwnerInfo) ownerInfo;
    Counters.Counter ownerInfoCount;
    uint256 price;
    uint256 amount;
    bool isSold;
    bool isUnlisted;
  }

  struct MarketItemView {
    uint256 itemId;
    address nftContract;
    uint256 tokenId;
    address seller;
    uint256 price;
    uint256 amount;
    bool isSoldOut;
    bool isUnlisted;
  }

  // Event is an inheritable contract that can be used to emit events
  event MarketItemCreated(
    uint256 indexed itemId,
    address indexed nftContract,
    uint256 indexed tokenId,
    address seller,
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
    OwnerInfo ownerInfo,
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
    OwnerInfo ownerInfo,
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
    uint256 price,
    uint256 amount,
    bool isSold,
    bool isUnlisted
  );

  event SetFee(uint256 fee);

  event SetCurrency(address currency);

  event NewCandidateOwner(address candidateOwner);

  constructor(IERC20 _currency, uint256 _listingFee) {
    uint256 listingFee = _listingFee.mul(100).div(FEE_DENOMINATOR);
    require(address(_currency) != address(0), "Address must not be zero");
    require(listingFee >= 0, "Fee must not be less than 0");
    require(listingFee <= 100, "Fee must not be more than 100");
    currency = _currency;
    fee = _listingFee;
  }

  function renounceOwnership() public view override onlyOwner {
    revert("Renounce ownership not allowed");
  }

  function transferOwnership(address _candidateOwner)
    public
    override
    onlyOwner
  {
    require(_candidateOwner != address(0), "Ownable: No zero address");
    candidateOwner = _candidateOwner;
    emit NewCandidateOwner(_candidateOwner);
  }

  function claimOwnership() external {
    require(candidateOwner == msg.sender, "Ownable: Not the candidate");
    address oldOwner = owner();
    _transferOwnership(candidateOwner);
    candidateOwner = address(0);
    emit OwnershipTransferred(oldOwner, candidateOwner);
  }

  function getFee() public view returns (uint256) {
    return fee;
  }

  function setFee(uint256 _fee) external onlyOwner {
    uint256 listingFee = _fee.mul(100).div(FEE_DENOMINATOR);
    require(listingFee >= 0, "Fee must not be less than 0");
    require(listingFee <= 100, "Fee must not be more than 100");
    fee = _fee;
    emit SetFee(listingFee);
  }

  function getCurrency() public view returns (IERC20) {
    return currency;
  }

  function setCurrency(address _currency) external onlyOwner {
    require(_currency != address(0), "No zero address");
    currency = IERC20(_currency);
    emit SetCurrency(_currency);
  }

  function createMarketItem(
    address nftContract,
    uint256 tokenId,
    uint256 price,
    uint256 amount
  ) external nonReentrant {
    require(price > 0, "Cannot sell item for free");
    require(amount > 0, "Amount must be more than 0");

    itemIds.increment();
    uint256 itemId = itemIds.current();

    MarketItem storage marketItem = idToMarketItem[itemId];
    marketItem.itemId = itemId;
    marketItem.nftContract = nftContract;
    marketItem.tokenId = tokenId;
    marketItem.seller = msg.sender;
    marketItem.price = price;
    marketItem.amount = amount;
    marketItem.isSold = false;
    marketItem.isUnlisted = false;

    itemsSelling.increment();

    // Transfer NFT
    IERC1155(nftContract).safeTransferFrom(
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
  ) external nonReentrant {
    uint256 price = idToMarketItem[itemId].price;
    uint256 tokenId = idToMarketItem[itemId].tokenId;
    uint256 calculatedFee = calculateFee(amount, price);

    require(amount > 0, "Amount must be more than 0");
    require(
      idToMarketItem[itemId].amount >= amount,
      "Insufficient market item amount"
    );
    require(idToMarketItem[itemId].isSold != true, "This item is sold");
    require(idToMarketItem[itemId].isUnlisted != true, "This item is unlisted");

    uint256 cost = price.mul(amount);
    require(currency.balanceOf(msg.sender) >= cost, "Insufficient balance");

    // Transfer currency to seller
    currency.safeTransferFrom(
      msg.sender,
      idToMarketItem[itemId].seller,
      cost.sub(calculatedFee)
    );

    IERC1155(idToMarketItem[itemId].nftContract).safeTransferFrom(
      address(this),
      msg.sender,
      tokenId,
      amount,
      "0x0"
    );

    OwnerInfo memory ownerInfo = OwnerInfo(msg.sender, amount, block.number);
    idToMarketItem[itemId].ownerInfoCount.increment();
    idToMarketItem[itemId].ownerInfo[
      idToMarketItem[itemId].ownerInfoCount.current().sub(1)
    ] = ownerInfo;

    // Transfer fee to contract owner
    currency.safeTransferFrom(msg.sender, owner(), calculatedFee);

    idToMarketItem[itemId].amount = idToMarketItem[itemId].amount.sub(amount);
    bool sold = idToMarketItem[itemId].amount == 0;
    if (sold) {
      idToMarketItem[itemId].isSold = true;
      itemsSelling.decrement();
    }

    emit MarketItemSold(
      itemId,
      nftContract,
      idToMarketItem[itemId].tokenId,
      idToMarketItem[itemId].seller,
      ownerInfo,
      idToMarketItem[itemId].price,
      amount,
      sold,
      false
    );
  }

  function unlistMarketItem(address nftContract, uint256 itemId)
    external
    nonReentrant
  {
    require(idToMarketItem[itemId].isSold != true, "This item is sold");
    require(idToMarketItem[itemId].isUnlisted != true, "This item is unlisted");
    require(
      msg.sender == address(idToMarketItem[itemId].seller),
      "You are not seller of this item"
    );

    IERC1155(idToMarketItem[itemId].nftContract).safeTransferFrom(
      address(this),
      msg.sender,
      idToMarketItem[itemId].tokenId,
      idToMarketItem[itemId].amount,
      "0x0"
    );

    idToMarketItem[itemId].isUnlisted = true;

    itemsSelling.decrement();

    OwnerInfo memory ownerInfo = OwnerInfo(
      msg.sender,
      idToMarketItem[itemId].amount,
      block.number
    );
    idToMarketItem[itemId].ownerInfoCount.increment();
    idToMarketItem[itemId].ownerInfo[
      idToMarketItem[itemId].ownerInfoCount.current().sub(1)
    ] = ownerInfo;

    emit MarketItemUnlisted(
      itemId,
      nftContract,
      idToMarketItem[itemId].tokenId,
      idToMarketItem[itemId].seller,
      ownerInfo,
      idToMarketItem[itemId].price,
      idToMarketItem[itemId].amount,
      idToMarketItem[itemId].isSold,
      true
    );
  }

  function setMarketItemPrice(uint256 itemId, uint256 price)
    external
    nonReentrant
  {
    require(price > 0, "No item for free here");
    require(idToMarketItem[itemId].isSold != true, "This item is sold");
    require(idToMarketItem[itemId].isUnlisted != true, "This item is unlisted");
    require(
      msg.sender == address(idToMarketItem[itemId].seller),
      "You are not seller of this item"
    );

    idToMarketItem[itemId].price = price;

    emit MarketItemSetPrice(
      itemId,
      idToMarketItem[itemId].nftContract,
      idToMarketItem[itemId].tokenId,
      idToMarketItem[itemId].seller,
      idToMarketItem[itemId].price,
      idToMarketItem[itemId].amount,
      idToMarketItem[itemId].isSold,
      false
    );
  }

  function calculateFee(uint256 amount, uint256 price)
    public
    view
    returns (uint256 _fee)
  {
    return price.mul(amount).mul(fee).div(FEE_DENOMINATOR);
  }

  function getMarketItems(uint256 page, uint256 limit)
    public
    view
    returns (MarketItemView[] memory)
  {
    require(page > 0, "Page must be more than 0");
    require(limit > 0, "Limit must be more than 0");
    require(limit <= 100, "Max limit reached");
    uint256 currentIndex = 0;

    MarketItemView[] memory marketItems = new MarketItemView[](
      itemsSelling.current()
    );
    for (uint256 i = limit.mul(page).sub(limit); i < limit.mul(page); i++) {
      if (
        !idToMarketItem[i + 1].isSold &&
        !idToMarketItem[i + 1].isUnlisted &&
        idToMarketItem[i + 1].itemId > 0
      ) {
        uint256 currentId = idToMarketItem[i + 1].itemId;
        MarketItemView memory currentItem = MarketItemView({
          itemId: idToMarketItem[currentId].itemId,
          nftContract: idToMarketItem[currentId].nftContract,
          tokenId: idToMarketItem[currentId].tokenId,
          seller: idToMarketItem[currentId].seller,
          price: idToMarketItem[currentId].price,
          amount: idToMarketItem[currentId].amount,
          isSoldOut: idToMarketItem[currentId].isSold,
          isUnlisted: idToMarketItem[currentId].isUnlisted
        });
        marketItems[currentIndex] = currentItem;
        currentIndex += 1;
      }
    }
    return marketItems;
  }

  function getMarketItem(uint256 itemId)
    public
    view
    returns (MarketItemView memory)
  {
    MarketItemView memory marketItemView = MarketItemView({
      itemId: idToMarketItem[itemId].itemId,
      nftContract: idToMarketItem[itemId].nftContract,
      tokenId: idToMarketItem[itemId].tokenId,
      seller: idToMarketItem[itemId].seller,
      price: idToMarketItem[itemId].price,
      amount: idToMarketItem[itemId].amount,
      isSoldOut: idToMarketItem[itemId].isSold,
      isUnlisted: idToMarketItem[itemId].isUnlisted
    });
    return marketItemView;
  }

  function fetchPurchasedNFTs(uint256 page, uint256 limit)
    public
    view
    returns (MarketItemView[] memory)
  {
    require(page > 0, "Page must more than 0");
    require(limit > 0, "Limit must more than 0");
    require(limit <= 100, "Max limit reached");

    uint256 itemCount = 0;
    uint256 currentIndex = 0;

    for (uint256 i = limit.mul(page).sub(limit); i < limit.mul(page); i++) {
      if (idToMarketItem[i + 1].itemId > 0) {
        for (
          uint256 i2 = 0;
          i2 < idToMarketItem[i + 1].ownerInfoCount.current();
          i2++
        ) {
          if (idToMarketItem[i + 1].ownerInfo[i2].owner == msg.sender) {
            itemCount += 1;
          }
        }
      }
    }

    MarketItemView[] memory marketItems = new MarketItemView[](itemCount);
    for (uint256 i = limit.mul(page).sub(limit); i < limit.mul(page); i++) {
      for (
        uint256 i2 = 0;
        i2 < idToMarketItem[i + 1].ownerInfoCount.current();
        i2++
      ) {
        if (idToMarketItem[i + 1].ownerInfo[i2].owner == msg.sender) {
          uint256 currentId = idToMarketItem[i + 1].itemId;
          MarketItemView memory currentItem = MarketItemView({
            itemId: idToMarketItem[currentId].itemId,
            nftContract: idToMarketItem[currentId].nftContract,
            tokenId: idToMarketItem[currentId].tokenId,
            seller: idToMarketItem[currentId].seller,
            price: idToMarketItem[currentId].price,
            amount: idToMarketItem[i + 1].ownerInfo[i2].amount,
            isSoldOut: idToMarketItem[currentId].isSold,
            isUnlisted: idToMarketItem[currentId].isUnlisted
          });
          marketItems[currentIndex] = currentItem;
          currentIndex += 1;
        }
      }
    }
    return marketItems;
  }

  function fetchCreateNFTs(uint256 page, uint256 limit)
    public
    view
    returns (MarketItemView[] memory)
  {
    require(page > 0, "Page must more than 0");
    require(limit > 0, "Limit must more than 0");
    require(limit <= 100, "Max limit reached");

    uint256 itemCount = 0;
    uint256 currentIndex = 0;

    for (uint256 i = limit.mul(page).sub(limit); i < limit.mul(page); i++) {
      if (idToMarketItem[i + 1].seller == msg.sender) {
        itemCount += 1; // No dynamic length. Predefined length has to be made
      }
    }

    MarketItemView[] memory marketItems = new MarketItemView[](itemCount);
    for (uint256 i = limit.mul(page).sub(limit); i < limit.mul(page); i++) {
      if (idToMarketItem[i + 1].seller == msg.sender) {
        uint256 currentId = idToMarketItem[i + 1].itemId;
        MarketItemView memory currentItem = MarketItemView({
          itemId: idToMarketItem[currentId].itemId,
          nftContract: idToMarketItem[currentId].nftContract,
          tokenId: idToMarketItem[currentId].tokenId,
          seller: idToMarketItem[currentId].seller,
          price: idToMarketItem[currentId].price,
          amount: idToMarketItem[currentId].amount,
          isSoldOut: idToMarketItem[currentId].isSold,
          isUnlisted: idToMarketItem[currentId].isUnlisted
        });
        marketItems[currentIndex] = currentItem;
        currentIndex += 1;
      }
    }
    return marketItems;
  }

  function getOwnerInfo(uint256 marketItemId)
    public
    view
    returns (OwnerInfo[] memory)
  {
    require(marketItemId <= itemIds.current(), "Item ID not found");
    uint256 ownerInfoCount = idToMarketItem[marketItemId]
      .ownerInfoCount
      .current();
    OwnerInfo[] memory ownerInfo = new OwnerInfo[](ownerInfoCount);
    for (uint256 i = 0; i < ownerInfoCount; i++) {
      ownerInfo[i] = idToMarketItem[marketItemId].ownerInfo[i];
    }
    return ownerInfo;
  }
}
