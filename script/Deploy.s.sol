// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ProofQuest} from "../src/ProofQuest.sol";
import {MockAgentID} from "../src/mocks/MockAgentID.sol";

/// @title DeployScript
/// @notice Deploy ProofQuest to BSC testnet (chain 97) or BSC mainnet (chain 56).
/// @dev Reads PRIVATE_KEY from the environment. This script does **not**
///      generate keys, fund accounts, or broadcast unless you invoke it
///      with `forge script ... --broadcast`.
///
/// Testnet (deploys MockAgentID when AGENT_ID_REGISTRY is unset or zero):
///   PRIVATE_KEY=0x... BSC_TESTNET_RPC_URL=https://... \
///     forge script script/Deploy.s.sol:DeployScript \
///       --rpc-url $BSC_TESTNET_RPC_URL --broadcast --verify --chain 97
///
/// Mainnet (uses the official Agent ID registry by default):
///   PRIVATE_KEY=0x... BSC_RPC_URL=https://... BSCSCAN_API_KEY=... \
///     forge script script/Deploy.s.sol:DeployScript \
///       --rpc-url $BSC_RPC_URL --broadcast --verify --chain 56
contract DeployScript is Script {
    address public constant MAINNET_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address public constant BSC_USDT = 0x55d398326f99059FF77548524633006e1A0d54ee;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        uint256 chainId = block.chainid;

        address registry = vm.envOr("AGENT_ID_REGISTRY", address(0));
        address owner_ = vm.envOr("OWNER", deployer);

        console.log("Deployer:", deployer);
        console.log("Chain id:", chainId);
        console.log("Intended owner:", owner_);

        vm.startBroadcast(pk);

        if (registry == address(0)) {
            if (chainId == 56) {
                registry = MAINNET_REGISTRY;
            } else {
                // Testnet / local: the official registry may not be deployed.
                MockAgentID mock = new MockAgentID();
                registry = address(mock);
                console.log("Deployed MockAgentID (test/dev only):", registry);
            }
        }

        address[] memory tokens;
        if (chainId == 56) {
            tokens = new address[](1);
            tokens[0] = BSC_USDT;
        } else {
            address testToken = vm.envOr("TEST_PRIZE_TOKEN", address(0));
            if (testToken != address(0)) {
                tokens = new address[](1);
                tokens[0] = testToken;
            } else {
                tokens = new address[](0);
            }
        }

        ProofQuest pq = new ProofQuest(registry, owner_, tokens);
        vm.stopBroadcast();

        console.log("ProofQuest:", address(pq));
        console.log("Agent ID registry:", registry);
        console.log("Owner:", owner_);
        if (chainId == 56) {
            console.log("Whitelisted ERC-20 (BSC-USD):", BSC_USDT);
        }
    }
}
