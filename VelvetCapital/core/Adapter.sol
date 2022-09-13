// SPDX-License-Identifier: MIT

/**
 * @title IndexManager for a particular Index
 * @author Velvet.Capital
 * @notice This contract is used for transferring funds form vault to contract and vice versa 
           and swap tokens to and fro from BNB
 * @dev This contract includes functionalities:
 *      1. Deposit tokens to vault
 *      2. Withdraw tokens from vault
 *      3. Swap BNB for tokens
 *      4. Swap tokens for BNB
 */

pragma solidity ^0.8.6;

import "@uniswap/lib/contracts/libraries/TransferHelper.sol";

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../interfaces/IIndexSwap.sol";
import "../interfaces/IUniswapV2Router02.sol";
import "../interfaces/IWETH.sol";

import "../core/IndexSwapLibrary.sol";

import "../access/AccessController.sol";
import "../interfaces/IVelvetSafeModule.sol";

// import "../vault/VelvetSafeModule.sol";
import "../venus/VBep20Interface.sol";
import "../venus/IVBNB.sol";
import "../venus/TokenMetadata.sol";

contract Adapter is Initializable {
    IUniswapV2Router02 public pancakeSwapRouter;
    AccessController public accessController;
    IVelvetSafeModule internal gnosisSafe;
    TokenMetadata public tokenMetadata;

    constructor() {}

    using SafeMath for uint256;
    uint256 public constant divisor_int = 10_000;

    function init(
        address _accessController,
        address _pancakeSwapAddress,
        address _velvetSafeModule,
        address _tokenMetadata
    ) external initializer {
        pancakeSwapRouter = IUniswapV2Router02(_pancakeSwapAddress);
        accessController = AccessController(_accessController);
        gnosisSafe = IVelvetSafeModule(_velvetSafeModule);
        tokenMetadata = TokenMetadata(_tokenMetadata);
    }

    /**
     * @return Returns the address of the base token (WETH, WBNB, ...)
     */
    function getETH() public view returns (address) {
        return pancakeSwapRouter.WETH();
    }

    modifier onlyIndexManager() {
        require(
            accessController.isIndexManager(msg.sender),
            "Caller is not an Index Manager"
        );
        _;
    }

    /**
     * @notice Transfer tokens from vault to a specific address
     */
    function _pullFromVault(
        IIndexSwap _index,
        address t,
        uint256 amount,
        address to
    ) public onlyIndexManager {
        if (tokenMetadata.vTokens(t) != address(0)) {
            if (address(gnosisSafe) != address(0)) {
                gnosisSafe.executeTransactionOther(
                    to,
                    amount,
                    tokenMetadata.vTokens(t)
                );
            } else {
                TransferHelper.safeTransferFrom(t, _index.vault(), to, amount);
            }
        } else {
            if (address(gnosisSafe) != address(0)) {
                gnosisSafe.executeTransactionOther(to, amount, t);
            } else {
                TransferHelper.safeTransferFrom(t, _index.vault(), to, amount);
            }
        }
    }

    /**
     * @notice The function swaps ETH to a specific token
     * @param t The token being swapped to the specific token
     * @param swapAmount The amount being swapped
     * @param to The address where the token is being send to after swapping
     * @return swapResult The outcome amount of the specific token afer swapping
     */
    function _swapETHToToken(
        address t,
        uint256 swapAmount,
        address to,
        uint256 _slippage
    ) public payable onlyIndexManager returns (uint256 swapResult) {
        if (t == getETH()) {
            if (tokenMetadata.vTokens(t) != address(0)) {
                swapResult = swapAmount;
                lendBNB(t, tokenMetadata.vTokens(t), swapResult, to);
            } else {
                IWETH(t).deposit{value: swapAmount}();
                swapResult = swapAmount;

                if (to != address(this)) {
                    IWETH(t).transfer(to, swapAmount);
                }
            }
        } else {
            if (tokenMetadata.vTokens(t) != address(0)) {
                swapResult = pancakeSwapRouter.swapExactETHForTokens{
                    value: swapAmount
                }(
                    getSlippage(swapAmount, _slippage, getPathForETH(t)),
                    getPathForETH(t),
                    address(this),
                    block.timestamp // using 'now' for convenience, for mainnet pass deadline from frontend!
                )[1];
                lendToken(t, tokenMetadata.vTokens(t), swapResult, to);
            } else {
                swapResult = pancakeSwapRouter.swapExactETHForTokens{
                    value: swapAmount
                }(
                    getSlippage(swapAmount, _slippage, getPathForETH(t)),
                    getPathForETH(t),
                    to,
                    block.timestamp // using 'now' for convenience, for mainnet pass deadline from frontend!
                )[1];
            }
        }
    }

    /**
     * @notice The function swaps a specific token to ETH
     * @dev Requires the tokens to be send to this contract address before swapping
     * @param t The token being swapped to ETH
     * @param swapAmount The amount being swapped
     * @param to The address where ETH is being send to after swapping
     * @return swapResult The outcome amount in ETH afer swapping
     */
    function _swapTokenToETH(
        address t,
        uint256 swapAmount,
        address to,
        uint256 _slippage
    ) public onlyIndexManager returns (uint256 swapResult) {
        if (tokenMetadata.vTokens(t) != address(0)) {
            if (t == getETH()) {
                redeemBNB(tokenMetadata.vTokens(t), swapAmount, address(this));
                swapResult = address(this).balance;

                (bool success, ) = payable(to).call{value: swapResult}("");
                require(success, "Transfer failed.");
            } else {
                redeemToken(
                    tokenMetadata.vTokens(t),
                    t,
                    swapAmount,
                    address(this)
                );
                IERC20 token = IERC20(t);
                uint256 amount = token.balanceOf(address(this));
                require(amount > 0, "zero balance amount");

                TransferHelper.safeApprove(
                    t,
                    address(pancakeSwapRouter),
                    amount
                );
                swapResult = pancakeSwapRouter.swapExactTokensForETH(
                    amount,
                    getSlippage(amount, _slippage, getPathForToken(t)),
                    getPathForToken(t),
                    to,
                    block.timestamp
                )[1];
            }
        } else {
            TransferHelper.safeApprove(
                t,
                address(pancakeSwapRouter),
                swapAmount
            );
            if (t == getETH()) {
                IWETH(t).withdraw(swapAmount);
                (bool success, ) = payable(to).call{value: swapAmount}("");
                require(success, "Transfer failed.");
                swapResult = swapAmount;
            } else {
                swapResult = pancakeSwapRouter.swapExactTokensForETH(
                    swapAmount,
                    getSlippage(swapAmount, _slippage, getPathForToken(t)),
                    getPathForToken(t),
                    to,
                    block.timestamp
                )[1];
            }
        }
    }

    // VENUS
    function lendToken(
        address _underlyingAsset,
        address _vAsset,
        uint256 _amount,
        address _to
    ) internal {
        IERC20 underlyingToken = IERC20(_underlyingAsset);
        VBep20Interface vToken = VBep20Interface(_vAsset);

        TransferHelper.safeApprove(
            address(underlyingToken),
            address(vToken),
            _amount
        );
        assert(vToken.mint(_amount) == 0);
        uint256 vBalance = vToken.balanceOf(address(this));
        TransferHelper.safeTransfer(_vAsset, _to, vBalance);
    }

    function lendBNB(
        address _underlyingAsset,
        address _vAsset,
        uint256 _amount,
        address _to
    ) internal {
        IERC20 underlyingToken = IERC20(_underlyingAsset);
        IVBNB vToken = IVBNB(_vAsset);

        TransferHelper.safeApprove(
            address(underlyingToken),
            address(vToken),
            _amount
        );
        vToken.mint{value: _amount}();
        uint256 vBalance = vToken.balanceOf(address(this));
        TransferHelper.safeTransfer(_vAsset, _to, vBalance);
    }

    function redeemToken(
        address _vAsset,
        address _underlying,
        uint256 _amount,
        address _to
    ) public onlyIndexManager {
        VBep20Interface vToken = VBep20Interface(_vAsset);
        require(
            _amount <= vToken.balanceOf(address(this)),
            "not enough balance in venus protocol"
        );
        require(vToken.redeem(_amount) == 0, "redeeming vToken failed");

        if (_to != address(this)) {
            IERC20 token = IERC20(_underlying);
            uint256 tokenAmount = token.balanceOf(address(this));
            TransferHelper.safeTransfer(_underlying, _to, tokenAmount);
        }
    }

    function redeemBNB(
        address _vAsset,
        uint256 _amount,
        address _to
    ) public onlyIndexManager returns (uint256 bal) {
        IVBNB vToken = IVBNB(_vAsset);
        require(
            _amount <= vToken.balanceOf(address(this)),
            "not enough balance in venus protocol"
        );
        require(vToken.redeem(_amount) == 0, "redeeming vToken failed");
        bal = address(this).balance;

        if (_to != address(this)) {
            (bool success, ) = payable(_to).call{value: address(this).balance}(
                ""
            );
            require(success, "Transfer failed.");
        }
    }

    /**
     * @notice The function sets the path (ETH, token) for a token
     * @return Path for (ETH, token)
     */
    function getPathForETH(address crypto)
        public
        view
        returns (address[] memory)
    {
        address[] memory path = new address[](2);
        path[0] = getETH();
        path[1] = crypto;

        return path;
    }

    /**
     * @notice The function sets the path (token, ETH) for a token
     * @return Path for (token, ETH)
     */
    function getPathForToken(address token)
        public
        view
        returns (address[] memory)
    {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = getETH();

        return path;
    }

    function getSlippage(
        uint256 _amount,
        uint256 _slippage,
        address[] memory path
    ) internal view returns (uint256 minAmount) {
        require(
            _slippage < divisor_int,
            "Slippage cannot be greater than 100%!"
        );
        uint256 currentAmount = pancakeSwapRouter.getAmountsOut(_amount, path)[
            1
        ];
        minAmount = currentAmount.mul(divisor_int.sub(_slippage)).div(
            divisor_int
        );
    }

    // // important to receive ETH
    receive() external payable {}
}
