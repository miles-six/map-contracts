// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./interface/IWToken.sol";
import "./interface/IMAPToken.sol";
import "./interface/IFeeCenter.sol";
import "./utils/Role.sol";
import "./interface/IFeeCenter.sol";
import "./utils/TransferHelper.sol";
import "./interface/IMCS.sol";
import "./interface/ILightNode.sol";
import "./utils/RLPReader.sol";


contract MapCrossChainService is ReentrancyGuard, Role, Initializable, Pausable, IMCS {
    using SafeMath for uint;
    using RLPReader for bytes;
    using RLPReader for RLPReader.RLPItem;

    uint public nonce;

    IERC20 public mapToken;
    ILightNode public lightNode;
    address public wToken;          // native wrapped token

    uint public selfChainId;

    mapping(bytes32 => address) public tokenRegister;
    //Gas transfer fee charged by the target chain
    mapping(uint => uint) public chainGasFee;
    mapping(bytes32 => bool) orderList;

    uint public chainGasFees;

    mapping(address => bool) public authToken;

    struct txLog {
        address addr;
        bytes[] topics;
        bytes data;
    }


    event mapTransferOut(address indexed token, address indexed from, bytes32 indexed orderId,
        uint fromChain, uint toChain, bytes to, uint amount, bytes toChainToken);
    event mapTransferIn(address indexed token, bytes indexed from, bytes32 indexed orderId,
        uint fromChain, uint toChain, address to, uint amount);

    event mapTransferOutData(bytes indexed toContract, address indexed from, bytes32 indexed orderId,
        uint fromChain, uint toChain, bytes data);
    event mapTransferInData(bytes indexed toContract, address indexed from, bytes32 indexed orderId,
        uint fromChain, uint toChain, bytes data);

    event mapTokenRegister(bytes32 tokenID, address token);
    event mapDepositOut(address indexed token, address indexed from, bytes indexed to,
        bytes32 orderId, uint amount);


    bytes32 mapTransferOutTopic = keccak256(bytes('mapTransferOut(address,address,bytes32,uint,uint,bytes,uint,bytes)'));
    //    bytes mapTransferInTopic = keccak256(bytes('mapTransferIn(address,address,bytes32,uint,uint,bytes,uint,bytes)'));

    function initialize(address _wToken, address _mapToken) public initializer {
        uint _chainId;
        assembly {_chainId := chainid()}
        selfChainId = _chainId;
        wToken = _wToken;
        mapToken = IERC20(_mapToken);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MANAGER_ROLE, msg.sender);
    }

    receive() external payable {
        require(msg.sender == wToken, "only wToken");
    }


    modifier checkOrder(bytes32 orderId) {
        require(!orderList[orderId], "order exist");
        orderList[orderId] = true;
        _;
    }

    function setPause() external onlyManager {
        _pause();
    }

    function setUnpause() external onlyManager {
        _unpause();
    }

    function getOrderID(address token, address from, bytes memory to, uint amount, uint toChainID) public returns (bytes32){
        return keccak256(abi.encodePacked(nonce++, from, to, token, amount, selfChainId, toChainID));
    }

    function addAuthToken(address[] memory token) external onlyManager {
        for (uint i = 0; i < token.length; i++) {
            authToken[token[i]] = true;
        }
    }

    function removeAuthToken(address[] memory token) external onlyManager {
        for (uint i = 0; i < token.length; i++) {
            authToken[token[i]] = false;
        }
    }

    function checkAuthToken(address token) public view returns (bool) {
        return authToken[token];
    }


    function transferIn(uint, bytes memory receiptProof) external override nonReentrant whenNotPaused {
        (bool sucess,string memory message,bytes memory logArray) = lightNode.verifyProofData(receiptProof);
        require(sucess, message);
        txLog[] memory logs = decodeTxLog(logArray);

        for (uint i = 0; i < logs.length; i++) {
            txLog memory log = logs[i];
            bytes32 topic = abi.decode(log.topics[0], (bytes32));
            if (topic == mapTransferOutTopic) {
//                address token = abi.decode(log.topics[1], (address));
                address from = abi.decode(log.topics[2], (address));
                bytes32 orderId = abi.decode(log.topics[3], (bytes32));
                (uint fromChain, uint toChain, bytes memory to, uint amount, bytes memory toChainToken)
                = abi.decode(log.data, (uint, uint, bytes, uint, bytes));
                address token = _bytesToAddress(toChainToken);
                address payable toAddress = payable(_bytesToAddress(to));
                _transferIn(token, _addressToBytes(from), toAddress, amount, orderId, fromChain, toChain);
            }
        }
    }

    function transferOut(address toContract, uint toChain, bytes memory data) external override whenNotPaused {

    }

    function transferOutToken(address token, bytes memory toAddress, uint amount, uint toChain) external override whenNotPaused {
        bytes32 orderId = getOrderID(token, msg.sender, toAddress, amount, toChain);
        require(IERC20(token).balanceOf(msg.sender) >= amount, "balance too low");
        if (checkAuthToken(token)) {
            IMAPToken(token).burnFrom(msg.sender, amount);
        } else {
            TransferHelper.safeTransferFrom(token, msg.sender, address(this), amount);
        }
        emit mapTransferOut(token, msg.sender, orderId, selfChainId, toChain, toAddress, amount, _addressToBytes(address(0)));
    }

    function transferOutNative(bytes memory toAddress, uint toChain) external override payable whenNotPaused {
        uint amount = msg.value;
        require(amount > 0, "balance is zero");
        bytes32 orderId = getOrderID(address(0), msg.sender, toAddress, amount, toChain);
        IWToken(wToken).deposit{value : amount}();
        emit mapTransferOut(address(0), msg.sender, orderId, selfChainId, toChain, toAddress, amount, _addressToBytes(address(0)));
    }


    function depositOutToken(address token, address from, bytes memory to, uint amount) external override payable whenNotPaused {
        bytes32 orderId = getOrderID(token, msg.sender, to, amount, 22776);
        require(IERC20(token).balanceOf(msg.sender) >= amount, "balance too low");
        TransferHelper.safeTransferFrom(token, from, address(this), amount);
        emit mapDepositOut(token, from, to, orderId, amount);
    }

    function depositOutNative(address from, bytes memory to) external override payable whenNotPaused {
        uint amount = msg.value;
        bytes32 orderId = getOrderID(address(0), msg.sender, to, amount, 22776);
        require(msg.value >= amount, "balance too low");
        emit mapDepositOut(address(0), from, to, orderId, amount);
    }

    function transferInVault(address token, bytes memory from, address payable to, uint amount, bytes32 orderId, uint fromChain, uint toChain)
    external checkOrder(orderId) nonReentrant whenNotPaused {
        if (token == address(0)) {
            TransferHelper.safeWithdraw(wToken, amount);
            TransferHelper.safeTransferETH(to, amount);
        } else if (checkAuthToken(token)) {
            IMAPToken(token).mint(to, amount);
        } else {
            TransferHelper.safeTransfer(token, to, amount);
        }
        emit mapTransferIn(address(0), from, orderId, fromChain, toChain, to, amount);
    }


    function _transferIn(address token, bytes memory from, address payable to, uint amount, bytes32 orderId, uint fromChain, uint toChain)
    internal checkOrder(orderId) {
        if (token == address(0)) {
            TransferHelper.safeWithdraw(wToken, amount);
            TransferHelper.safeTransferETH(to, amount);
        } else if (checkAuthToken(token)) {
            IMAPToken(token).mint(to, amount);
        } else {
            TransferHelper.safeTransfer(token, to, amount);
        }
        emit mapTransferIn(address(0), from, orderId, fromChain, toChain, to, amount);
    }


    function withdraw(address token, address payable receiver, uint256 amount) public onlyManager {
        if (token == address(0)) {
            IWToken(wToken).withdraw(amount);
            receiver.transfer(amount);
        } else {
            IERC20(token).transfer(receiver, amount);
        }
    }

    function _bytesToAddress(bytes memory bys) internal pure returns (address addr){
        assembly {
            addr := mload(add(bys, 20))
        }
    }

    function _addressToBytes(address a) internal pure returns (bytes memory b) {
        assembly {
            let m := mload(0x40)
            a := and(a, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            mstore(
            add(m, 20),
            xor(0x140000000000000000000000000000000000000000, a)
            )
            mstore(0x40, add(m, 52))
            b := m
        }
    }

    function decodeTxLog(bytes memory logsHash)
    internal
    pure
    returns (txLog[] memory _txLogs){
        RLPReader.RLPItem[] memory ls = logsHash.toRlpItem().toList();
        _txLogs = new txLog[](ls.length);
        for (uint256 i = 0; i < ls.length; i++) {
            bytes[] memory topic = new bytes[](ls[i].toList()[1].toList().length);
            for (uint256 j = 0; j < ls[i].toList()[1].toList().length; j++) {
                topic[j] = ls[i].toList()[1].toList()[j].toBytes();
            }
            _txLogs[i] = txLog({
            addr : ls[i].toList()[0].toAddress(),
            topics : topic,
            data : ls[i].toList()[2].toBytes()
            });
        }
    }

}