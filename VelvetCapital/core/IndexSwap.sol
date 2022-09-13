// SPDX-License-Identifier: MIT

/**
 * @title IndexSwap for the Index
 * @author Velvet.Capital
 * @notice This contract is used by the user to invest and withdraw from the index
 * @dev This contract includes functionalities:
 *      1. Invest in the particular fund
 *      2. Withdraw from the fund
 */

pragma solidity ^0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../interfaces/IWETH.sol";
import "../interfaces/IIndexSwap.sol";

import "../interfaces/IIndexSwapLibrary.sol";
import "../interfaces/IAdapter.sol";
import "../interfaces/IAccessController.sol";
import "../venus/IVBNB.sol";
import "../venus/VBep20Interface.sol";
import "../venus/TokenMetadata.sol";

contract TokenBase is ERC20Burnable, Ownable, ReentrancyGuard {
    constructor(string memory _name, string memory _symbol)
        ERC20(_name, _symbol)
    {}
}

contract IndexSwap is TokenBase {
    // IERC20 public token;
    using SafeMath for uint256;

    uint256 public indexPrice;

    address public vault;

    bool public paused;

    /**
     * @dev Token record data structure
     * @param lastDenormUpdate timestamp of last denorm change
     * @param denorm denormalized weight
     * @param index index of address in tokens array
     */
    struct Record {
        uint40 lastDenormUpdate;
        uint96 denorm;
        uint8 index;
    }
    // Array of underlying tokens in the pool.
    address[] internal _tokens;

    // Internal records of the pool's underlying tokens
    mapping(address => Record) internal _records;

    // Total denormalized weight of the pool.
    uint256 public constant TOTAL_WEIGHT = 10_000;

    // Total denormalized weight of the pool.
    uint256 internal MAX_INVESTMENTAMOUNT;


    address public outAsset;
    IIndexSwapLibrary public indexSwapLibrary;
    IAdapter public adapter;
    IAccessController public accessController;
    TokenMetadata public tokenMetadata;

    uint256 public feePointBasis;
    address public treasury;

    //events
    event InvestInFund(uint256 time, address user,uint256 investedAmount ,uint256 tokenAmount);
    event WithdrawFromFundInBNB(uint256 time, address user, uint256 tokenAmount, uint256 bnbAmount);
    event WithdrawFromFundInToken(uint256 time, address user, uint256[] tokenAmount);

    // constructor() { }

    constructor(
        string memory _name,
        string memory _symbol,
        address _outAsset,
        address _vault,
        uint256 _maxInvestmentAmount,
        address _indexSwapLibrary,
        address _adapter,
        address _accessController,
        address _tokenMetadata,
        uint256 _feePointBasis,
        address _treasury
    ) TokenBase(_name, _symbol) {
        vault = _vault;
        outAsset = _outAsset; //As now we are tacking busd
        MAX_INVESTMENTAMOUNT = _maxInvestmentAmount;
        indexSwapLibrary = IIndexSwapLibrary(_indexSwapLibrary);
        adapter = IAdapter(_adapter);
        accessController = IAccessController(_accessController);
        tokenMetadata = TokenMetadata(_tokenMetadata);
        paused = false;

        feePointBasis = _feePointBasis;
        treasury = payable(_treasury);
    }

    /** @dev Emitted when public trades are enabled. */
    event LOG_PUBLIC_SWAP_ENABLED();

    /**
     * @dev Sets up the initial assets for the pool.
     * @param tokens Underlying tokens to initialize the pool with
     * @param denorms Initial denormalized weights for the tokens
     */
    function initToken(address[] calldata tokens, uint96[] calldata denorms)
        external
        onlyOwner
    {
        require(tokens.length == denorms.length, "INVALID_INIT_INPUT");
        require(_tokens.length == 0, "INITIALIZED");
        uint256 len = tokens.length;
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < len; i++) {
            _records[tokens[i]] = Record({
                lastDenormUpdate: uint40(block.timestamp),
                denorm: denorms[i],
                index: uint8(i)
            });
            _tokens.push(tokens[i]);

            totalWeight = totalWeight.add(denorms[i]);
        }
        require(totalWeight == TOTAL_WEIGHT, "INVALID_WEIGHTS");

        emit LOG_PUBLIC_SWAP_ENABLED();
    }

    /**
     * @notice The function calculates the amount of index tokens the user can buy/mint with the invested amount.
     * @param _amount The invested amount after swapping ETH into portfolio tokens converted to BNB to avoid 
                      slippage errors
     * @param sumPrice The total value in the vault converted to BNB
     * @return Returns the amount of index tokens to be minted.
     */
    function _mintShareAmount(uint256 _amount, uint256 sumPrice)
        internal
        view
        returns (uint256)
    {
        uint256 indexTokenSupply = totalSupply();

        return _amount.mul(indexTokenSupply).div(sumPrice);
    }

    /**
     * @notice The function swaps BNB into the portfolio tokens after a user makes an investment
     * @dev The output of the swap is converted into BNB to get the actual amount after slippage to calculate 
            the index token amount to mint
     * @dev (tokenBalanceInBNB, vaultBalance) has to be calculated before swapping for the _mintShareAmount function 
            because during the swap the amount will change but the index token balance is still the same 
            (before minting)
     */
    function investInFund(uint256 _slippage) public payable nonReentrant {
        require(!paused, "The contract is paused !");
        uint256 tokenAmount = msg.value;
        require(_tokens.length != 0, "NOT INITIALIZED");
        require(
            tokenAmount <= MAX_INVESTMENTAMOUNT,
            "Amount exceeds maximum investment amount!"
        );
        uint256 investedAmountAfterSlippage = 0;
        uint256 vaultBalance = 0;
        uint256 len = _tokens.length;
        uint256[] memory amount = new uint256[](len);
        uint256[] memory tokenBalanceInBNB = new uint256[](len);

        (tokenBalanceInBNB, vaultBalance) = indexSwapLibrary
            .getTokenAndVaultBalance(IIndexSwap(address(this)));

        amount = indexSwapLibrary.calculateSwapAmounts(
            IIndexSwap(address(this)),
            tokenAmount,
            tokenBalanceInBNB,
            vaultBalance
        );

        investedAmountAfterSlippage = _swapETHToTokens(
            tokenAmount,
            amount,
            _slippage
        );

        uint256 investedAmountAfterSlippageBNB = indexSwapLibrary
            ._getTokenPriceUSDETH(investedAmountAfterSlippage);

        uint256 vaultBalanceBNB = indexSwapLibrary._getTokenPriceUSDETH(
            vaultBalance
        );


        if (totalSupply() > 0) {
            tokenAmount = _mintShareAmount(
                investedAmountAfterSlippageBNB,
                vaultBalanceBNB
            );
        } else {
            tokenAmount = investedAmountAfterSlippageBNB;
        }

        _mint(msg.sender, tokenAmount);

        emit InvestInFund(block.timestamp, msg.sender,msg.value,tokenAmount);

        // refund leftover ETH to user
        (bool success, ) = payable(msg.sender).call{
            value: address(this).balance
        }("");
        require(success, "refund failed");
    }

    /**
     * @notice The function swaps the amount of portfolio tokens represented by the amount of index token back to 
               BNB and returns it to the user and burns the amount of index token being withdrawn
     * @param tokenAmount The index token amount the user wants to withdraw from the fund
     */
    function withdrawFund(uint256 tokenAmount, uint256 _slippage, bool isMultiAsset)
        public
        nonReentrant
    {
        require(!paused, "The contract is paused !");
        require(
            tokenAmount <= balanceOf(msg.sender),
            "caller is not holding given token amount"
        );

        uint256 sumBalance=0;
        uint256[] memory arrayOfTokenAmount = new uint256[](_tokens.length);
        uint256 totalSupplyIndex = totalSupply();

        _burn(msg.sender, tokenAmount);

        for (uint256 i = 0; i < _tokens.length; i++) {
            uint256 tokenBalance = indexSwapLibrary.getTokenBalance(
                IIndexSwap(address(this)),
                _tokens[i],
                adapter.getETH() == _tokens[i]
            );

            uint256 amount = tokenBalance.mul(tokenAmount).div(
                totalSupplyIndex
            );

            if(!isMultiAsset){
            if (_tokens[i] == adapter.getETH()) {
                if (tokenMetadata.vTokens(_tokens[i]) != address(0)) {
                    adapter._pullFromVault(
                        IIndexSwap(address(this)),
                        _tokens[i],
                        amount,
                        address(adapter)
                    );

                    uint256 bal = adapter.redeemBNB(
                        tokenMetadata.vTokens(_tokens[i]),
                        amount,
                        msg.sender
                    );
                    sumBalance = sumBalance + bal;

                } else {
                    adapter._pullFromVault(
                        IIndexSwap(address(this)),
                        _tokens[i],
                        amount,
                        address(this)
                    );

                    IWETH(_tokens[i]).withdraw(amount);

                    sumBalance = sumBalance + amount;
                    (bool success, ) = payable(msg.sender).call{value: amount}(
                        ""
                    );
                    require(success, "Transfer failed.");
                }
            } else {
                adapter._pullFromVault(
                    IIndexSwap(address(this)),
                    _tokens[i],
                    amount,
                    address(adapter)
                );
                uint sw = adapter._swapTokenToETH(
                    _tokens[i],
                    amount,
                    msg.sender,
                    _slippage
                );

                sumBalance = sumBalance + sw;
            }
        } else {
             adapter._pullFromVault(
                    IIndexSwap(address(this)),
                    _tokens[i],
                    amount,
                    msg.sender
                );
            arrayOfTokenAmount[i]= amount;
            }
        }
        if(!isMultiAsset){
            emit WithdrawFromFundInBNB(block.timestamp, msg.sender, tokenAmount,sumBalance);
        }else{
            emit WithdrawFromFundInToken(block.timestamp, msg.sender, arrayOfTokenAmount);
        }
    }

    /**
     * @notice The function swaps ETH to the portfolio tokens
     * @param tokenAmount The amount being used to calculate the amount to swap for the first investment
     * @param amount A list of amounts specifying the amount of ETH to be swapped to each token in the portfolio
     * @return investedAmountAfterSlippage
     */
    function _swapETHToTokens(
        uint256 tokenAmount,
        uint256[] memory amount,
        uint256 _slippage
    ) internal returns (uint256 investedAmountAfterSlippage) {
        for (uint256 i = 0; i < _tokens.length; i++) {
            address t = _tokens[i];
            Record memory record = _records[t];
            uint256 swapAmount;
            if (totalSupply() == 0) {
                swapAmount = tokenAmount.mul(record.denorm).div(TOTAL_WEIGHT);
            } else {
                swapAmount = amount[i];
            }

            require(address(this).balance >= swapAmount, "not enough bnb");

            uint256 swapResult = adapter._swapETHToToken{value: swapAmount}(
                t,
                swapAmount,
                vault,
                _slippage
            );

            investedAmountAfterSlippage = investedAmountAfterSlippage.add(
                indexSwapLibrary._getTokenAmountInUSD(t, swapResult)
            );
        }
    }

    modifier onlyRebalancerContract() {
        require(
            accessController.isRebalancerContract(msg.sender),
            "Caller is not an Rebalancer Contract"
        );
        _;
    }

    /**
    @notice The function will pause the InvestInFund() and Withdrawal() called by the rebalancing contract.
    @param _state The state is bool value which needs to input by the Index Manager.
    */
    function setPaused(bool _state) public onlyRebalancerContract {
        paused = _state;
    }

    /**
     * @notice The function updates the record struct including the denorm information
     * @dev The token list is passed so the function can be called with current or updated token list
     * @param tokens The updated token list of the portfolio
     * @param denorms The new weights for for the portfolio
     */
    function updateRecords(address[] memory tokens, uint96[] memory denorms)
        public
        onlyRebalancerContract
    {
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            _records[tokens[i]] = Record({
                lastDenormUpdate: uint40(block.timestamp),
                denorm: denorms[i],
                index: uint8(i)
            });
            totalWeight = totalWeight.add(denorms[i]);
        }

        require(totalWeight == TOTAL_WEIGHT, "INVALID_WEIGHTS");
    }

    function getTokens() public view returns (address[] memory) {
        return _tokens;
    }

    function getRecord(address _token) public view returns (Record memory) {
        return _records[_token];
    }

    function updateTokenList(address[] memory tokens)
        public
        onlyRebalancerContract
    {
        _tokens = tokens;
    }

    function deleteRecord(address t) public onlyRebalancerContract {
        delete _records[t];
    }

    function updateTreasury(address _newTreasury)
        public
        onlyRebalancerContract
    {
        treasury = _newTreasury;
    }

    // important to receive ETH
    receive() external payable {}
}
