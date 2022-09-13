// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV2V3Interface.sol";
import "@chainlink/contracts/src/v0.8/Denominations.sol";

contract PriceOracle is Ownable {
    using SafeMath for uint256;

    struct AggregatorInfo {
        mapping(address => AggregatorV2V3Interface) aggregatorInterfaces;
    }

    mapping(address => AggregatorInfo) internal aggregatorAddresses;

    function getAggregatorInterface() public {}

    /**
     * @notice Retrieve the aggregator of an base / quote pair in the current phase
     * @param base base asset address
     * @param quote quote asset address
     * @return aggregator
     */
    function _getFeed(address base, address quote)
        internal
        view
        returns (AggregatorV2V3Interface aggregator)
    {
        aggregator = aggregatorAddresses[base].aggregatorInterfaces[quote];
    }

    /**
     * @notice Add a new aggregator of an base / quote pair
     * @param base base asset address
     * @param quote quote asset address
     * @param aggregator aggregator
     */
    function _addFeed(
        address base,
        address quote,
        AggregatorV2V3Interface aggregator
    ) public onlyOwner {
        require(
            aggregatorAddresses[base].aggregatorInterfaces[quote] ==
                AggregatorInterface(address(0)),
            "Aggregator already exists"
        );
        aggregatorAddresses[base].aggregatorInterfaces[quote] = aggregator;
    }

    /**
     * @notice Updatee an existing feed
     * @param base base asset address
     * @param quote quote asset address
     * @param aggregator aggregator
     */
    function _updateFeed(
        address base,
        address quote,
        AggregatorV2V3Interface aggregator
    ) public onlyOwner {
        aggregatorAddresses[base].aggregatorInterfaces[quote] = aggregator;
    }

    /**
     * @notice Returns the decimals of a token pair price feed
     * @param base base asset address
     * @param quote quote asset address
     * @return Decimals of the token pair
     */
    function decimals(address base, address quote) public view returns (uint8) {
        AggregatorV2V3Interface aggregator = _getFeed(base, quote);
        require(address(aggregator) != address(0), "Feed not found");
        return aggregator.decimals();
    }

    /**
     * @notice Returns the latest price
     * @param base base asset address
     * @param quote quote asset address
     * @return The latest token price of the pair
     */
    function latestRoundData(address base, address quote)
        internal
        view
        returns (int256)
    {
        (
            ,
            /*uint80 roundID*/
            int256 price, /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
            ,
            ,

        ) = aggregatorAddresses[base]
                .aggregatorInterfaces[quote]
                .latestRoundData();
        return price;
    }

    /**
     * @notice Returns the latest ETH price for a specific token and amount
     * @param amountIn The amount of base tokens to be converted to ETH
     * @return amountOut The latest ETH token price of the base token
     */
    function getUsdEthPrice(uint256 amountIn)
        public
        view
        returns (uint256 amountOut)
    {
        uint256 price = uint256(
            latestRoundData(Denominations.ETH, Denominations.USD)
        );

        uint256 decimal = decimals(Denominations.ETH, Denominations.USD);
        amountOut = amountIn.mul(10**decimal).div(price);
    }

    /**
     * @notice Returns the latest price
     * @param base base asset address
     * @param quote quote asset address
     * @return The latest token price of the pair
     */
    function getPrice(address base, address quote)
        public
        view
        returns (int256)
    {
        int256 price = latestRoundData(base, quote);
        return price;
    }

    /**
     * @notice Returns the latest USD price for a specific token and amount
     * @param _base base asset address
     * @param amountIn The amount of base tokens to be converted to USD
     * @return amountOut The latest USD token price of the base token
     */
    function getPriceTokenUSD(address _base, uint256 amountIn)
        public
        view
        returns (uint256 amountOut)
    {
        uint256 output = uint256(getPrice(_base, Denominations.USD));
        uint256 decimal = decimals(_base, Denominations.USD);
        amountOut = output.mul(amountIn).div(10**decimal);
    }
}
