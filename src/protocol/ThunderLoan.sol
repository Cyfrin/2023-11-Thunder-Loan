// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AssetToken} from "./AssetToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OracleUpgradeable} from "./OracleUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

contract ThunderLoan is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    OracleUpgradeable
{
    using SafeERC20 for IERC20;
    using Address for address;

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/
    error ThunderLoan__NotAllowedToken(IERC20 token);
    error ThunderLoan__CantBeZero();
    error ThunderLoan__NotPaidBack(
        uint256 expectedEndingBalance,
        uint256 endingBalance
    );
    error ThunderLoan__NotEnoughTokenBalance(
        uint256 startingBalance,
        uint256 amount
    );
    error ThunderLoan__CallerIsNotContract();
    error ThunderLoan__AlreadyAllowed();
    error ThunderLoan__ExhangeRateCanOnlyIncrease();
    error ThunderLoan__NotCurrentlyFlashLoaning();
    error ThunderLoan__BadNewFee();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    mapping(IERC20 => AssetToken) public s_tokenToAssetToken;

    // Precision for fees (1e18)
    uint256 private s_feePrecision;

    // Flash loan fee, e.g., 0.3% = 3e15 (0.003 * 1e18)
    uint256 private s_flashLoanFee;

    // Track tokens currently under flash loan process to prevent reentrancy/multiple flash loans on same token
    mapping(IERC20 token => bool currentlyFlashLoaning)
        private s_currentlyFlashLoaning;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event Deposit(
        address indexed account,
        IERC20 indexed token,
        uint256 amount
    );
    event AllowedTokenSet(
        IERC20 indexed token,
        AssetToken indexed asset,
        bool allowed
    );
    event Redeemed(
        address indexed account,
        IERC20 indexed token,
        uint256 amountOfAssetToken,
        uint256 amountOfUnderlying
    );
    event FlashLoan(
        address indexed receiverAddress,
        IERC20 indexed token,
        uint256 amount,
        uint256 fee,
        bytes params
    );

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier revertIfZero(uint256 amount) {
        if (amount == 0) {
            revert ThunderLoan__CantBeZero();
        }
        _;
    }

    modifier revertIfNotAllowedToken(IERC20 token) {
        if (!isAllowedToken(token)) {
            revert ThunderLoan__NotAllowedToken(token);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address tswapAddress) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __Oracle_init(tswapAddress);
        s_feePrecision = 1e18;
        s_flashLoanFee = 3e15; // 0.3%
    }

    /*//////////////////////////////////////////////////////////////
                               VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function isAllowedToken(IERC20 token) public view returns (bool) {
        return address(s_tokenToAssetToken[token]) != address(0);
    }

    function getFlashLoanFee() external view returns (uint256) {
        return s_flashLoanFee;
    }

    function getExchangeRate(
        IERC20 token
    ) external view revertIfNotAllowedToken(token) returns (uint256) {
        return s_tokenToAssetToken[token].getExchangeRate();
    }

    /// @notice Calculates the fee in the token's own units for a given amount borrowed
    function getCalculatedFee(
        IERC20 token,
        uint256 amount
    ) public view returns (uint256 fee) {
        // Calculate value of borrowed token in WETH terms (or base price)
        uint256 valueOfBorrowedToken = (amount *
            getPriceInWeth(address(token))) / s_feePrecision;
        // Fee = valueOfBorrowedToken * s_flashLoanFee / s_feePrecision (fee is based on value in WETH)
        fee = (valueOfBorrowedToken * s_flashLoanFee) / s_feePrecision;
    }

    /*//////////////////////////////////////////////////////////////
                              EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function deposit(
        IERC20 token,
        uint256 amount
    ) external revertIfZero(amount) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 exchangeRate = assetToken.getExchangeRate();

        // Calculate amount of asset tokens to mint based on exchange rate
        uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) /
            exchangeRate;

        emit Deposit(msg.sender, token, amount);

        assetToken.mint(msg.sender, mintAmount);

        uint256 calculatedFee = getCalculatedFee(token, amount);
        assetToken.updateExchangeRate(calculatedFee);

        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }

    /// @notice Withdraw underlying tokens by burning asset tokens
    /// @param token Underlying token
    /// @param amountOfAssetToken Amount of asset tokens to redeem (max uint256 to redeem all)
    function redeem(
        IERC20 token,
        uint256 amountOfAssetToken
    ) external revertIfZero(amountOfAssetToken) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 exchangeRate = assetToken.getExchangeRate();

        if (amountOfAssetToken == type(uint256).max) {
            amountOfAssetToken = assetToken.balanceOf(msg.sender);
        }

        uint256 amountUnderlying = (amountOfAssetToken * exchangeRate) /
            assetToken.EXCHANGE_RATE_PRECISION();

        emit Redeemed(msg.sender, token, amountOfAssetToken, amountUnderlying);

        assetToken.burn(msg.sender, amountOfAssetToken);
        assetToken.transferUnderlyingTo(msg.sender, amountUnderlying);
    }

    /// @notice Flashloan function: loans token to receiverAddress which must implement `executeOperation`
    /// @param receiverAddress The contract that receives the flashloan and implements executeOperation
    /// @param token The token to borrow
    /// @param amount The amount to borrow
    /// @param params Additional parameters forwarded to executeOperation
    function flashloan(
        address receiverAddress,
        IERC20 token,
        uint256 amount,
        bytes calldata params
    ) external revertIfZero(amount) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 startingBalance = token.balanceOf(address(assetToken));

        if (amount > startingBalance) {
            revert ThunderLoan__NotEnoughTokenBalance(startingBalance, amount);
        }

        if (!receiverAddress.isContract()) {
            revert ThunderLoan__CallerIsNotContract();
        }

        uint256 fee = getCalculatedFee(token, amount);

        // Update exchange rate with fee before loaning out
        assetToken.updateExchangeRate(fee);

        emit FlashLoan(receiverAddress, token, amount, fee, params);

        s_currentlyFlashLoaning[token] = true;

        assetToken.transferUnderlyingTo(receiverAddress, amount);

        // Call the receiver's executeOperation method with the flash loan params
        receiverAddress.functionCall(
            abi.encodeWithSignature(
                "executeOperation(address,uint256,uint256,address,bytes)",
                address(token),
                amount,
                fee,
                msg.sender,
                params
            )
        );

        uint256 endingBalance = token.balanceOf(address(assetToken));
        if (endingBalance < startingBalance + fee) {
            revert ThunderLoan__NotPaidBack(
                startingBalance + fee,
                endingBalance
            );
        }

        s_currentlyFlashLoaning[token] = false;
    }

    /// @notice Called by flashloan borrower to repay the loan during flashloan operation
    function repay(
        IERC20 token,
        uint256 amount
    ) public revertIfNotAllowedToken(token) {
        if (!s_currentlyFlashLoaning[token]) {
            revert ThunderLoan__NotCurrentlyFlashLoaning();
        }
        AssetToken assetToken = s_tokenToAssetToken[token];
        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }

    /// @notice Owner-only function to allow or disallow tokens for lending
    /// @param token Token to set
    /// @param allowed Whether token is allowed
    /// @return The AssetToken created or removed
    function setAllowedToken(
        IERC20 token,
        bool allowed
    ) external onlyOwner returns (AssetToken) {
        if (allowed) {
            if (address(s_tokenToAssetToken[token]) != address(0)) {
                revert ThunderLoan__AlreadyAllowed();
            }
            AssetToken assetToken = new AssetToken(token);
            s_tokenToAssetToken[token] = assetToken;
            emit AllowedTokenSet(token, assetToken, true);
            return assetToken;
        } else {
            if (address(s_tokenToAssetToken[token]) == address(0)) {
                revert ThunderLoan__NotAllowedToken(token);
            }
            delete s_tokenToAssetToken[token];
            emit AllowedTokenSet(token, AssetToken(address(0)), false);
            return AssetToken(address(0));
        }
    }

    /// @notice Update flashloan fee - only owner
    /// @param newFee New fee with 1e18 precision
    function setFlashLoanFee(uint256 newFee) external onlyOwner {
        if (newFee > s_flashLoanFee) {
            revert ThunderLoan__ExhangeRateCanOnlyIncrease();
        }
        s_flashLoanFee = newFee;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
