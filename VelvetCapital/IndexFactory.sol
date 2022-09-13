// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./access/AccessController.sol";
import "./interfaces/IAdapter.sol";
import "./interfaces/IIndexSwap.sol";
import "./interfaces/IRebalancing.sol";
import "./core/IndexSwap.sol";

contract IndexFactory is Ownable {
    address public treasury;
    address public uniswapRouter;
    address public outAsset;
    address public indexSwapLibrary;
    address public tokenMetadata;
    address private baseAdapterAddress;
    address private baseRebalancingAddress;
    address private noVtokenMetadata;

    struct IndexSwaplInfo {
        address indexSwap;
        address rebalancing;
        address owner;
    }

    IndexSwaplInfo[] public IndexSwapInfolList;

    event IndexCreation(
        address index,
        string _name,
        string _symbol,
        address _outAsset,
        address _vault,
        uint256 _maxInvestmentAmount,
        address _adapter,
        address _accessController
    );

    event RebalanceCreation(address _rebalancing);

    constructor(
        address _uniswapRouter,
        address _outAsset,
        address _treasury,
        address _indexSwapLibrary,
        address _tokenMetadata,
        address _baseAdapterAddress,
        address _baseRebalancingAddres
    ) {
        require(_outAsset != address(0), "Invalid Out Asset");
        uniswapRouter = _uniswapRouter;
        outAsset = _outAsset;
        treasury = _treasury;
        indexSwapLibrary = _indexSwapLibrary;
        tokenMetadata = _tokenMetadata;
        noVtokenMetadata = Clones.clone(tokenMetadata);

        baseRebalancingAddress = _baseRebalancingAddres;
        baseAdapterAddress = _baseAdapterAddress;
    }

    function createIndex(
        string memory _name,
        string memory _symbol,
        address _vault,
        address _velvetSafeModule,
        uint256 _maxInvestmentAmount,
        uint256 _feePointBasis,
        bool baseToken
    ) public onlyOwner returns (address) {
        require(_vault != address(0), "Invalid Vault");
        require(address(_velvetSafeModule) != address(0), "Invalid Module");

        // Access Controller
        AccessController accessController = new AccessController();
        IAdapter _adapter = IAdapter(Clones.clone(baseAdapterAddress));
        address tokenMetaDataInit = baseToken
            ? noVtokenMetadata
            : tokenMetadata;

        // Index Manager
        _adapter.init(
            address(accessController),
            uniswapRouter,
            _velvetSafeModule,
            tokenMetaDataInit
        );

        IndexSwap indexSwap = new IndexSwap(
            _name,
            _symbol,
            outAsset,
            _vault,
            _maxInvestmentAmount,
            indexSwapLibrary,
            address(_adapter),
            address(accessController),
            tokenMetaDataInit,
            _feePointBasis,
            treasury
        );

        emit IndexCreation(
            address(indexSwap),
            _name,
            _symbol,
            outAsset,
            _vault,
            _maxInvestmentAmount,
            address(_adapter),
            address(accessController)
        );

        IRebalancing rebalancing = IRebalancing(
            Clones.clone(baseRebalancingAddress)
        );

        rebalancing.init(
            IIndexSwap(address(indexSwap)),
            indexSwapLibrary,
            address(_adapter),
            address(accessController),
            tokenMetaDataInit
        );

        IndexSwapInfolList.push(
            IndexSwaplInfo(address(indexSwap), address(rebalancing), owner())
        );

        emit RebalanceCreation(address(rebalancing));
        emit IndexCreation(
            address(indexSwap),
            _name,
            _symbol,
            outAsset,
            _vault,
            _maxInvestmentAmount,
            address(_adapter),
            address(accessController)
        );

        // Access Control
        accessController.setupRole(
            keccak256("INDEX_MANAGER_ROLE"),
            address(indexSwap)
        );

        accessController.setupRole(keccak256("ASSET_MANAGER_ADMIN"), owner());
        accessController.setupRole(keccak256("ASSET_MANAGER_ROLE"), owner());

        accessController.setupRole(
            keccak256("INDEX_MANAGER_ROLE"),
            address(rebalancing)
        );
        accessController.setupRole(
            keccak256("REBALANCER_CONTRACT"),
            address(rebalancing)
        );

        return address(indexSwap);
    }

    function validIndexId(uint256 indexfundId) public view returns (bool) {
        if (indexfundId >= 0 && indexfundId <= IndexSwapInfolList.length - 1)
            return true;
        return false;
    }

    function getIndexList(uint256 indexfundId) external view returns (address) {
        return address(IndexSwapInfolList[indexfundId].indexSwap);
    }

    function initializeTokens(
        uint256 indexfundId,
        address[] calldata _tokens,
        uint96[] calldata _denorms
    ) public onlyOwner {
        require(validIndexId(indexfundId), "Not a valid Id");
        IIndexSwap(IndexSwapInfolList[indexfundId].indexSwap).initToken(
            _tokens,
            _denorms
        );
    }

    function setIndexSwapLibrary(address _indexSwapLibrary) public onlyOwner {
        require(_indexSwapLibrary != address(0), "Invalid Out Asset");
        indexSwapLibrary = _indexSwapLibrary;
    }

    function setOutAsset(address _outAsset) public onlyOwner {
        require(outAsset != address(0), "Invalid Out Asset");
        outAsset = _outAsset;
    }
}
