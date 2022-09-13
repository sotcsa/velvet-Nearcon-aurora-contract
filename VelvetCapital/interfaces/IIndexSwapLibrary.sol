// SPDX-License-Identifier: MIT

/**
 * @title IIndexSwapLibrary for a particular Index
 * @author Velvet.Capital
 * @notice This contract is used for all the calculations and also get token balance in vault
 * @dev This contract includes functionalities:
 *      1. Get tokens balance in the vault
 *      2. Calculate the swap amount needed while performing different operation
 */
pragma solidity ^0.8.6;
import "./IIndexSwap.sol";

interface IIndexSwapLibrary {
    // TokenMetadata public tokenMetadata;

    /**
     * @notice The function calculates the balance of each token in the vault and converts them to USD and 
               the sum of those values which represents the total vault value in USD
     * @return tokenXBalance A list of the value of each token in the portfolio in USD
     * @return vaultValue The total vault value in USD
     */
    function getTokenAndVaultBalance(IIndexSwap _index)
        external
        returns (uint256[] memory tokenXBalance, uint256 vaultValue);

    /**
     * @notice The function calculates the balance of a specific token in the vault
     * @return tokenBalance of the specific token
     */
    function getTokenBalance(
        IIndexSwap _index,
        address t,
        bool weth
    ) external view returns (uint256 tokenBalance);

    /**
     * @notice The function calculates the amount in BNB to swap from BNB to each token
     * @dev The amount for each token has to be calculated to ensure the ratio (weight in the portfolio) stays constant
     * @param tokenAmount The amount a user invests into the portfolio
     * @param tokenBalanceInUSD The balanace of each token in the portfolio converted to USD
     * @param vaultBalance The total vault value of all tokens converted to USD
     * @return A list of amounts that are being swapped into the portfolio tokens
     */
    function calculateSwapAmounts(
        IIndexSwap _index,
        uint256 tokenAmount,
        uint256[] memory tokenBalanceInUSD,
        uint256 vaultBalance
    ) external view returns (uint256[] memory);

    /**
     * @notice The function converts the given token amount into USD
     * @param t The base token being converted to USD
     * @param amount The amount to convert to USD
     * @return amountInUSD The converted USD amount
     */
    function _getTokenAmountInUSD(address t, uint256 amount)
        external
        view
        returns (uint256 amountInUSD);

    function _getTokenPriceUSDETH(uint256 amount)
        external
        view
        returns (uint256 amountInBNB);
}
