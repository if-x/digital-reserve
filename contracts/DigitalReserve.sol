// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./Interfaces/Uniswap/IUniswapV2Router02.sol";
import "./Interfaces/IDigitalReserve.sol";

/**
 * @dev Implementation of Digital Reserve contract.
 * Digital Reserve contract converts user's DRC into a set of SoV assets using the Uniswap router, 
 * and hold these assets for it's users. 
 * When users initiate a withdrawal action, the contract converts a share of the vault, 
 * that the user is requesting, to DRC and sends it back to their wallet.
 */
contract DigitalReserve is IDigitalReserve, ERC20, Ownable {
    using SafeMath for uint256;

    /**
     * @dev Set Uniswap router address, DRC token address, DR name.
     */
    constructor(
        address _router,
        address _drcAddress,
        string memory _name
    ) public ERC20(_name, "DR-POD") {
        drcAddress = _drcAddress;
        router = _router;
        uniswapRouter = IUniswapV2Router02(_router);
    }

    uint8 private _strategyTokenCount;
    address[] private _strategyTokens;
    mapping(address => uint8) private _tokenPercentage;
    uint8 private _feePercentage = 1;
    uint8 private _priceDecimals = 18;

    address private router;
    address private drcAddress;

    bool private depositEnabled = false;
    bool private withdrawalEnabled = true;

    IUniswapV2Router02 private uniswapRouter;

    /**
     * @dev See {IDigitalReserve-strategyTokenCount}.
     */
    function strategyTokenCount() external view override returns (uint8) {
        return _strategyTokenCount;
    }

    /**
     * @dev See {IDigitalReserve-strategyTokens}.
     */
    function strategyTokens(uint8 index) external view override returns (address) {
        return _strategyTokens[index];
    }

    /**
     * @dev See {IDigitalReserve-tokenPercentage}.
     */
    function tokenPercentage(address tokenAddress) external view override returns (uint8) {
        return _tokenPercentage[tokenAddress];
    }

    /**
     * @dev See {IDigitalReserve-feePercentage}.
     */
    function feePercentage() external view override returns (uint8) {
        return _feePercentage;
    }

    /**
     * @dev See {IDigitalReserve-priceDecimals}.
     */
    function priceDecimals() external view override returns (uint8) {
        return _priceDecimals;
    }

    /**
     * @dev See {IDigitalReserve-totalTokenStored}.
     */
    function totalTokenStored() public view override returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](_strategyTokenCount);
        for (uint8 i = 0; i < _strategyTokenCount; i++) {
            amounts[i] = IERC20(_strategyTokens[i]).balanceOf(address(this));
        }
        return amounts;
    }

    /**
     * @dev See {IDigitalReserve-getUserVaultInDrc}.
     */
    function getUserVaultInDrc(address user) public view override returns (uint256, uint256, uint256) {
        uint256 userVaultWorthInEth = balanceOf(user).mul(getProofOfDepositPrice()).div(1e18);

        uint256 fees = userVaultWorthInEth.mul(_feePercentage).div(100);
        uint256 drcAmount = _getTokenAmountByEthAmount(userVaultWorthInEth, drcAddress);
        uint256 drcAmountExcludeFees = _getTokenAmountByEthAmount(userVaultWorthInEth.sub(fees), drcAddress);

        return (drcAmount, drcAmountExcludeFees, fees);
    }

    /**
     * @dev See {IDigitalReserve-getProofOfDepositPrice}.
     */
    function getProofOfDepositPrice() public view override returns (uint256) {
        uint256 proofOfDepositPrice;
        if (totalSupply() > 0) {
            proofOfDepositPrice = _getEthAmountByStrategyTokensAmount(totalTokenStored()).mul(1e18).div(totalSupply());
        }
        return proofOfDepositPrice;
    }

    /**
     * @dev See {IDigitalReserve-depositDrc}.
     */
    function depositDrc(uint256 drcAmount, uint32 deadline) external override {
        require(depositEnabled, "Deposit is disabled.");
        require(IERC20(drcAddress).allowance(msg.sender, address(this)) >= drcAmount, "Contract is not allowed to spend user's DRC.");
        require(IERC20(drcAddress).balanceOf(msg.sender) >= drcAmount, "Attempted to deposit more than balance.");

        SafeERC20.safeTransferFrom(IERC20(drcAddress), msg.sender, address(this), drcAmount);

        // Get current unit price before adding tokens to vault
        uint256 currentPodUnitPrice = getProofOfDepositPrice();

        uint256 ethConverted = _convertTokenToEth(drcAmount, drcAddress, deadline);
        _convertEthToStrategyTokens(ethConverted, deadline);

        uint256 podToMint = 0;
        if (totalSupply() == 0) {
            podToMint = drcAmount.mul(1e15);
        } else {
            uint256 vaultTotalInEth = _getEthAmountByStrategyTokensAmount(totalTokenStored());
            uint256 newPodTotal = vaultTotalInEth.mul(1e18).div(currentPodUnitPrice);
            podToMint = newPodTotal.sub(totalSupply());
        }

        _mint(msg.sender, podToMint);

        emit Deposit(msg.sender, drcAmount, podToMint, totalSupply());
    }

    /**
     * @dev See {IDigitalReserve-withdrawDrc}.
     */
    function withdrawDrc(uint256 drcAmount, uint32 deadline) external override {
        require(withdrawalEnabled, "Withdraw is disabled.");

        (, uint256 userVaultInDrc, ) = getUserVaultInDrc(msg.sender);
        require(userVaultInDrc >= drcAmount, "Attempt to withdraw more than user's holding.");

        uint256 amountFraction = drcAmount.mul(1e10).div(userVaultInDrc);
        uint256 podToBurn = balanceOf(msg.sender).mul(amountFraction).div(1e10);
        _withdrawProofOfDeposit(podToBurn, deadline);
    }

    /**
     * @dev See {IDigitalReserve-withdrawPercentage}.
     */
    function withdrawPercentage(uint8 percentage, uint32 deadline) external override {
        require(withdrawalEnabled, "Withdraw is disabled.");
        require(percentage <= 100, "Attempt to withdraw more than 100% of the asset");

        uint256 podToBurn = balanceOf(msg.sender).mul(percentage).div(100);
        _withdrawProofOfDeposit(podToBurn, deadline);
    }

    /**
     * @dev Enable or disable deposit.
     * Disable deposit if it is to protect users' fund if there's any security issue or assist DR upgrade.
     */
    function changeDepositStatus(bool _status) external onlyOwner {
        depositEnabled = _status;
    }

    /**
     * @dev Enable or disable withdrawal.
     * Disable withdrawal if it is to protect users' fund if there's any security issue.
     */
    function changeWithdrawalStatus(bool _status) external onlyOwner {
        withdrawalEnabled = _status;
    }

    /**
     * @dev Change withdrawal fee percentage.
     */
    function changeFee(uint8 feePercentage_) external onlyOwner {
        require(feePercentage_ <= 100, "Fee percentage exceeded 100.");
        _feePercentage = feePercentage_;
    }

    /**
     * @dev Set or change DR strategy tokens and allocations.
     * @param strategyTokens_ Array of strategy tokens.
     * @param tokenPercentage_ Array of strategy tokens' percentage allocations.
     * @param strategyTokenCount_ Number of strategy tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function changeStrategy(
        address[] calldata strategyTokens_,
        uint8[] calldata tokenPercentage_,
        uint8 strategyTokenCount_,
        uint32 deadline
    ) external onlyOwner {
        require(strategyTokenCount_ >= 1, "Setting strategy to 0 tokens.");
        require(strategyTokens_.length == strategyTokenCount_, "Token count doesn't match tokens length");
        require(tokenPercentage_.length == strategyTokenCount_, "Token count doesn't match token percentages length");

        uint8 totalPercentage = 0;
        for (uint8 i = 0; i < strategyTokenCount_; i++) {
            totalPercentage += tokenPercentage_[i];
        }
        require(totalPercentage == 100, "Total token percentage exceeded 100%.");

        uint8[] memory oldPercentage = new uint8[](_strategyTokenCount);
        for (uint8 i = 0; i < _strategyTokenCount; i++) {
            oldPercentage[i] = _tokenPercentage[_strategyTokens[i]];
            delete _tokenPercentage[_strategyTokens[i]];
        }

        emit StrategyChange(_strategyTokens, oldPercentage, strategyTokens_, tokenPercentage_);

        // Before mutate strategyTokens, convert current strategy tokens to ETH
        uint256 ethConverted = _convertStrategyTokensToEth(totalTokenStored(), deadline);

        _strategyTokens = strategyTokens_;
        _strategyTokenCount = strategyTokenCount_;
        for (uint8 i = 0; i < _strategyTokenCount; i++) {
            _tokenPercentage[_strategyTokens[i]] = tokenPercentage_[i];
        }

        _convertEthToStrategyTokens(ethConverted, deadline);
    }

    /**
     * @dev Realigning the weighting of a portfolio of assets to the strategy allocation that is defined.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function rebalance(uint32 deadline) external onlyOwner {
        require(_strategyTokenCount > 0, "Strategy hasn't been set");

        uint8[] memory percentageArray = new uint8[](_strategyTokenCount);
        for (uint8 i = 0; i < _strategyTokenCount; i++) {
            percentageArray[i] += _tokenPercentage[_strategyTokens[i]];
        }

        emit Rebalance(_strategyTokens, percentageArray);

        uint256 ethConverted = _convertStrategyTokensToEth(totalTokenStored(), deadline);
        _convertEthToStrategyTokens(ethConverted, deadline);
    }

    /**
     * @dev Withdraw DRC by DR-POD amount to burn.
     * @param podToBurn Amount of DR-POD to burn in exchange for DRC.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function _withdrawProofOfDeposit(uint256 podToBurn, uint32 deadline) private {
        uint256[] memory strategyTokensToWithdraw = _getStrateTokensByPodAmount(podToBurn);

        _burn(msg.sender, podToBurn);

        uint256 ethConverted = _convertStrategyTokensToEth(strategyTokensToWithdraw, deadline);
        uint256 fees = ethConverted.mul(_feePercentage).div(100);

        uint256 drcAmount = _convertEthToToken(ethConverted.sub(fees), drcAddress, deadline);
        SafeERC20.safeTransfer(IERC20(drcAddress), msg.sender, drcAmount);
        SafeERC20.safeTransfer(IERC20(uniswapRouter.WETH()), owner(), fees);
        emit Withdraw(msg.sender, drcAmount, fees, podToBurn, totalSupply());
    }

    /**
     * @dev Get the worth in a token of a certain amount of ETH.
     * @param _amount Amount of ETH to convert.
     * @param _tokenAddress Address of the token to convert to.
     */
    function _getTokenAmountByEthAmount(uint256 _amount, address _tokenAddress) private view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = uniswapRouter.WETH();
        path[1] = _tokenAddress;

        if (path[0] == path[1] || _amount == 0) {
            return _amount;
        }
        return uniswapRouter.getAmountsOut(_amount, path)[1];
    }

    /**
     * @dev Get ETH worth of a certain amount of a token.
     * @param _amount Amount of token to convert.
     * @param _tokenAddress Address of token to convert from.
     */
    function _getEthAmountByTokenAmount(uint256 _amount, address _tokenAddress) private view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = _tokenAddress;
        path[1] = uniswapRouter.WETH();

        if (path[0] == path[1] || _amount == 0) {
            return _amount;
        }
        return uniswapRouter.getAmountsOut(_amount, path)[1];
    }

    /**
     * @dev Get ETH worth of an array of strategy tokens.
     * @param strategyTokensBalance_ Array amounts of strategy tokens to convert.
     */
    function _getEthAmountByStrategyTokensAmount(uint256[] memory strategyTokensBalance_) private view returns (uint256) {
        uint256 amountOut;
        address[] memory path = new address[](2);
        path[1] = uniswapRouter.WETH();

        for (uint8 i = 0; i < _strategyTokenCount; i++) {
            address tokenAddress = _strategyTokens[i];
            path[0] = tokenAddress;
            uint256 tokenAmount = strategyTokensBalance_[i];
            uint256 tokenAmountInEth = _getEthAmountByTokenAmount(tokenAmount, tokenAddress);

            amountOut = amountOut.add(tokenAmountInEth);
        }
        return amountOut;
    }

    /**
     * @dev Get DR-POD worth in an array of strategy tokens.
     * @param _amount Amount of DR-POD to convert.
     */
    function _getStrateTokensByPodAmount(uint256 _amount) private view returns (uint256[] memory) {
        uint256[] memory strategyTokenAmount = new uint256[](_strategyTokenCount);

        uint256 podFraction = _amount.mul(1e10).div(totalSupply());
        for (uint8 i = 0; i < _strategyTokenCount; i++) {
            strategyTokenAmount[i] = IERC20(_strategyTokens[i]).balanceOf(address(this)).mul(podFraction).div(1e10);
        }
        return strategyTokenAmount;
    }

    /**
     * @dev Convert a token to WETH via the Uniswap router.
     * @param _amount Amount of tokens to swap.
     * @param _tokenAddress Address of token to swap.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function _convertTokenToEth(
        uint256 _amount,
        address _tokenAddress,
        uint32 deadline
    ) private returns (uint256) {
        if (_tokenAddress == uniswapRouter.WETH() || _amount == 0) {
            return _amount;
        }
        address[] memory path = new address[](2);
        path[0] = _tokenAddress;
        path[1] = uniswapRouter.WETH();
        SafeERC20.safeApprove(IERC20(path[0]), router, _amount);
        uint256 amountOut = uniswapRouter.getAmountsOut(_amount, path)[1];
        uniswapRouter.swapExactTokensForTokens(_amount, amountOut, path, address(this), deadline);
        return amountOut;
    }

    /**
     * @dev Convert ETH to another token via the Uniswap router.
     * @param _amount Amount of WETH to swap.
     * @param _tokenAddress Address of token to swap to.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function _convertEthToToken(
        uint256 _amount,
        address _tokenAddress,
        uint32 deadline
    ) private returns (uint256) {
        if (_tokenAddress == uniswapRouter.WETH() || _amount == 0) {
            return _amount;
        }
        address[] memory path = new address[](2);
        path[0] = uniswapRouter.WETH();
        path[1] = _tokenAddress;
        SafeERC20.safeApprove(IERC20(path[0]), router, _amount);
        uint256 amountOut = uniswapRouter.getAmountsOut(_amount, path)[1];
        uniswapRouter.swapExactTokensForTokens(_amount, amountOut, path, address(this), deadline);
        return amountOut;
    }

    /**
     * @dev Convert ETH to strategy tokens of DR in their allocation percentage.
     * @param amount Amount of WETH to swap.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function _convertEthToStrategyTokens(uint256 amount, uint32 deadline) private returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](_strategyTokenCount);
        for (uint8 i = 0; i < _strategyTokenCount; i++) {
            uint256 amountToConvert = amount.mul(_tokenPercentage[_strategyTokens[i]]).div(100);
            amounts[i] = _convertEthToToken(amountToConvert, _strategyTokens[i], deadline);
        }
        return amounts;
    }

    /**
     * @dev Convert strategy tokens to WETH.
     * @param amountToConvert Array of the amounts of strategy tokens to swap.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function _convertStrategyTokensToEth(uint256[] memory amountToConvert, uint32 deadline) private returns (uint256) {
        uint256 ethConverted;
        for (uint8 i = 0; i < _strategyTokenCount; i++) {
            uint256 amountConverted = _convertTokenToEth(amountToConvert[i], _strategyTokens[i], deadline);
            ethConverted = ethConverted.add(amountConverted);
        }
        return ethConverted;
    }
}
