// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

//oz libaries
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./IUniswapV2Router02.sol";
import "./IUniswapV2Factory.sol";


contract DLOS is ERC20, Ownable {
    using Address for address;
    
    //Mainnet router
    IUniswapV2Router02 public router;
    address public pair;
    
    bool private _liquidityMutex = false;
    uint256 public _tokenLiquidityThreshold = 50000000e18;
    bool public ProvidingLiquidity = false;
   
    uint16 public feeliq = 50;
    uint16 public feeburn = 30;
    uint16 public feedev = 10;
    uint16 public feeres = 10;
    uint16 constant internal DIV = 1000;
    
    uint16 public feesum = feeliq + feeburn + feedev + feeres;
    uint16 public feesum_ex = feeliq + feedev;
    
    address payable public devwallet = payable(0x78731D3Ca6b7E34aC0F824c42a7cC18A495cabaB);

    uint256 public transferlimit = 50000000e18;

    mapping (address => bool) public exemptTransferlimit;    
    mapping (address => bool) public exemptFee; 
    
    event LiquidityProvided(uint256 tokenAmount, uint256 nativeAmount, uint256 exchangeAmount);
    event LiquidityProvisionStateChanged(bool newState);
    event LiquidityThresholdUpdated(uint256 newThreshold);
    
    
    modifier mutexLock() {
        if (!_liquidityMutex) {
            _liquidityMutex = true;
            _;
            _liquidityMutex = false;
        }
    }
    
    constructor() ERC20("The Crocodile Token", "Crox") {
        _mint(msg.sender, 1e12 * 10 ** decimals());      
        exemptTransferlimit[msg.sender] = true;
        exemptFee[msg.sender] = true;

        exemptTransferlimit[devwallet] = true;
        exemptFee[devwallet] = true;

        exemptTransferlimit[address(this)] = true;
        exemptFee[address(this)] = true;
    }
   
    
    function _transfer(address sender, address recipient, uint256 amount) internal override {        

        //check transferlimit
        require(amount <= transferlimit || exemptTransferlimit[sender] || exemptTransferlimit[recipient] , "you can't transfer that much");

        //calculate fee        
        uint256 fee_ex = amount * feesum_ex / DIV; // DIV = 1000
        uint256 fee_burn = amount * feeburn / DIV;

        uint256 fee = fee_ex + fee_burn;
        
        //set fee to zero if fees in contract are handled or exempted
        if (_liquidityMutex || exemptFee[sender] || exemptFee[recipient]) fee = 0;

        //send fees if threshhold has been reached
        //don't do this on buys, breaks swap
        //also only do it on transfers that deduct fees
        if (ProvidingLiquidity && sender != pair && fee > 0) handleFees();      
        
        //rest to recipient
        super._transfer(sender, recipient, amount - fee);
        
        //send the fee to the contract
        if (fee > 0) {
            super._transfer(sender, address(this), fee_ex);   
            _burn(sender, fee_burn);
        }      
    }
    
    /**
     * @dev Destroys `amount` tokens from the caller.
     *
     * See {ERC20-_burn}.
     */
    function burn(uint256 amount) public virtual {
        _burn(_msgSender(), amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, deducting from the caller's
     * allowance.
     *
     * See {ERC20-_burn} and {ERC20-allowance}.
     *
     * Requirements:
     *
     * - the caller must have allowance for ``accounts``'s tokens of at least
     * `amount`.
     */
    function burnFrom(address account, uint256 amount) public virtual {
        uint256 currentAllowance = allowance(account, _msgSender());
        require(currentAllowance >= amount, "ERC20: burn amount exceeds allowance");
        _approve(account, _msgSender(), currentAllowance - amount);
        _burn(account, amount);
    }
    
    
    function handleFees() private mutexLock {
        uint256 contractBalance = balanceOf(address(this));
        if (contractBalance >= _tokenLiquidityThreshold) {
            contractBalance = _tokenLiquidityThreshold;
            
            //calculate how many tokens we need to exchange
            uint256 exchangeAmount = contractBalance * feeliq / feesum_ex / 2;
            exchangeAmount += contractBalance * feedev / feesum_ex;
            uint256 exchangeAmountOtherHalf = contractBalance - exchangeAmount;

            //exchange to CRO
            exchangeTokenToNativeCurrency(exchangeAmount);
            uint256 CRO = address(this).balance;
            
            uint256 CRO_dev = CRO * feedev / (feeliq / 2 + feedev);
            
            //send CRO to dev
            sendCROToDev(CRO_dev);
            
            //add liquidity
            addToLiquidityPool(exchangeAmountOtherHalf, CRO - CRO_dev);
            
        }
    }

    function exchangeTokenToNativeCurrency(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        _approve(address(this), address(router), tokenAmount);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(tokenAmount, 0, path, address(this), block.timestamp);
    }

    function addToLiquidityPool(uint256 tokenAmount, uint256 nativeAmount) private {
        _approve(address(this), address(router), tokenAmount);
        //provide liquidity and send lP tokens to zero
        router.addLiquidityETH{value: nativeAmount}(address(this), tokenAmount, 0, 0, address(this), block.timestamp);
    }    
    
    function setRouterAddress(address newRouter) external onlyOwner {
        //give the option to change the router down the line 
        IUniswapV2Router02 _newRouter = IUniswapV2Router02(newRouter);
        address get_pair = IUniswapV2Factory(_newRouter.factory()).getPair(address(this), _newRouter.WETH());
        //checks if pair already exists
        if (get_pair == address(0)) {
            pair = IUniswapV2Factory(_newRouter.factory()).createPair(address(this), _newRouter.WETH());
        }
        else {
            pair = get_pair;
        }
        router = _newRouter;
    }    
    
    function sendCROToDev(uint256 amount) private {
        devwallet.transfer(amount);
    }
    
    function changeLiquidityProvide(bool state) external onlyOwner {
        //change liquidity providing state
        ProvidingLiquidity = state;
        emit LiquidityProvisionStateChanged(state);
    }
    
    function changeLiquidityTreshhold(uint256 new_amount) external onlyOwner {
        //change the treshhold
        _tokenLiquidityThreshold = new_amount;
        emit LiquidityThresholdUpdated(new_amount);
    }   
    
    function changeFees(uint16 _feeliq, uint16 _feeburn, uint16 _feedev) external onlyOwner returns (bool){
        feeliq = _feeliq;
        feeburn = _feeburn;
        feedev = _feedev;
        feesum = feeliq + feeburn + feedev;
        feesum_ex = feeliq + feedev;
        require(feesum <= 100, "exceeds hardcap");
        return true;
    }

    function changeTransferlimit(uint256 _transferlimit) external onlyOwner returns (bool) {
        require(_transferlimit >= 5e6 * 10 ** decimals(), "Transfer limit to low");
        transferlimit = _transferlimit;
        return true;
    }

    function updateExemptTransferLimit(address _address, bool state) external onlyOwner returns (bool) {
        exemptTransferlimit[_address] = state;
        return true;
    }

    function updateExemptFee(address _address, bool state) external onlyOwner returns (bool) {
        exemptFee[_address] = state;
        return true;
    }

    function updateDevwallet(address _address) external onlyOwner returns (bool) {
        devwallet = payable(_address);
        exemptTransferlimit[devwallet] = true;
        exemptFee[devwallet] = true;
        return true;
    }
    
    // fallbacks
    receive() external payable {}
    
}
