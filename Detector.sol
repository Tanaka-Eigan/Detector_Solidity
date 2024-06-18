// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.24;

import "./utils/IUniswapV2Router02.sol";
import "./utils/IERC20.sol";
import "./utils/IUniswapV2Pair.sol";
import "./utils/IUniswapV2Factory.sol";

contract Detector {
    // Authorized   
    address internal immutable user;

    IUniswapV2Router02 public immutable uniswapRouter;
    address public immutable WETH;
    address public factory;

    event LogBuyFee(uint256 msgValue, address[] path, uint256[] amounts, uint256 tokenAmountAfterBuy, uint256 startBalance, uint256 finalBalance);
    event LogSellFee(uint256 msgValue, uint256 amounts, uint256 tokenBalance, uint256 whatBalance, uint256 startBalance, uint256 finalBalance);
    event Log(string message, uint256 value);
    event LogAddress(string message, address addr);

    constructor() {
        user = msg.sender;
        uniswapRouter = IUniswapV2Router02(0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008);
        WETH = uniswapRouter.WETH();
        factory = 0x7E0987E5b3a30e3f2828572Bb659A548460a3003;
    }

    function checkTransferDelay(address token, uint256 buyCount) external payable returns (bool) {
        // Swap ETH for tokens
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = token;
       
        uint256 unit = msg.value / buyCount;

        uint256 balance0 = IERC20(token).balanceOf(address(this));
     
        uniswapRouter.swapExactETHForTokens{ value: unit }(
            0, // Accept any amount of tokens
            path,
            address(this),
            block.timestamp + 15
        );

        uint256 balance1 = IERC20(token).balanceOf(address(this));

        for (uint256 i = 1; i < buyCount; i ++) {
            uniswapRouter.swapExactETHForTokens{ value: unit }(
                0, // Accept any amount of tokens
                path,
                address(this),
                block.timestamp + 15
            );
        }

        uint256 finalBalance = IERC20(token).balanceOf(address(this));
       
        // Calculate transfer delay condition
        uint256 deviation = (balance1 - balance0) * 5 * buyCount * (buyCount - 1) / 2 / 100;
        int delta = int((balance1 - balance0) * buyCount - (finalBalance - balance0));
        delta = delta <= 0 ? -delta : delta;

        emit Log("deviation", uint256(deviation));
        emit Log("delta", uint256(delta));

        if (uint256(delta) <= deviation) {
            // No transfer delay
            return false;
        } else {
            // Transfer delay detected
            return true;
        }
    }

    function detectBuyFee(address token) external payable returns (uint256, uint256) {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = token;

        uint256 startBalance = IERC20(token).balanceOf(address(this));

        uint256[] memory amounts = uniswapRouter.swapExactETHForTokens{ value: msg.value }(
            0, // Accept any amount of tokens
            path,
            address(this),
            block.timestamp + 15
        );

        uint256 finalBalance = IERC20(token).balanceOf(address(this));

        emit LogBuyFee(msg.value, path, amounts, amounts[1], startBalance, finalBalance);

        return (amounts[1], finalBalance - startBalance);
    }

    function detectSellFee(address token) external payable returns (uint256, uint256) {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = token;

        uniswapRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{ value: msg.value }(
            0, // Accept any amount of tokens
            path,
            address(this),
            block.timestamp + 15
        );

        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        require(tokenBalance > 0, "Contract has insufficient token balance");
      
        bool approved = IERC20(token).approve(address(uniswapRouter), tokenBalance);
        require(approved, "Token approval failed");
       
        uint256 allowance = IERC20(token).allowance(address(this), address(uniswapRouter));
        require(allowance >= tokenBalance, "Token allowance is insufficient");
        
        uint256 ethBalance = address(this).balance;    
       
        path[0] = token;
        path[1] = WETH;
        
        uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenBalance,
            0, // Accept any amount of ETH
            path,
            address(this),
            block.timestamp + 15
        );
     
        ethBalance = address(this).balance - ethBalance;

        // get expect amount out
        address pairAddress = IUniswapV2Factory(factory).getPair(token, WETH);
        require(pairAddress != address(0), "Pair does not exist");

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pairAddress).getReserves();

        // Adjust the order of reserves based on the token order in the pair
        (uint256 reserveToken, uint256 reserveWETH) = token < WETH ? (reserve0, reserve1) : (reserve1, reserve0);

        uint amountInWithFee = tokenBalance * 997;
        uint numerator = amountInWithFee * reserveWETH;
        uint denominator = reserveToken * 1000 + amountInWithFee;
        uint expectAmountOut = numerator / denominator;

        emit Log("expectAmountOut:", expectAmountOut);
        emit Log("ethBalance:", ethBalance);

        return (expectAmountOut, ethBalance); 
    }

    function detectTransferFee(address token) external payable returns (uint256, uint256) {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = token;

        uniswapRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{ value: msg.value }(
            0, // Accept any amount of tokens
            path,
            address(this),
            block.timestamp + 15
        );

        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        require(tokenBalance > 0, "Contract has insufficient token balance");

         // Get the starting balance of the recipient
        address randomAddress = 0xaD0BcE670cdBcBe83a434604F497952FB79166D4;
        uint256 startBalance = IERC20(token).balanceOf(randomAddress);

        // Transfer tokens to the randomAddress
        bool success = IERC20(token).transfer(randomAddress, tokenBalance);
        require(success, "Token transfer failed");

        // Get the final balance of the recipient
        uint256 finalBalance = IERC20(token).balanceOf(randomAddress);

        emit Log("expectTransferAmount:", tokenBalance);
        emit Log("realTransferAmount:", finalBalance - startBalance);

        // Return the token balance and the amount transferred
        return (tokenBalance, finalBalance - startBalance);
    }

    // *** Receive profits from contract *** //
    function recoverERC20(address token) public {
        require(msg.sender == user, "Only the owner can recover tokens");
        IERC20(token).transfer(msg.sender, IERC20(token).balanceOf(address(this)));
    }

    receive() external payable {}
}
