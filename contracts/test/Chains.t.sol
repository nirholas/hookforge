// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Chains} from "src/libraries/Chains.sol";

/// @dev `Chains` is an internal library, so its reverts need an external call frame for `expectRevert` to catch.
contract ChainsHarness {
    function poolManager(uint256 chainId) external pure returns (address) {
        return address(Chains.poolManager(chainId));
    }
}

contract ChainsTest is Test {
    ChainsHarness internal harness = new ChainsHarness();

    /// @dev Every chain id the library names must resolve to a manager and a slug, so the two tables cannot drift.
    function test_everyNamedChainResolves() public pure {
        uint256[18] memory ids = [
            Chains.ETHEREUM,
            Chains.OPTIMISM,
            Chains.BNB,
            Chains.UNICHAIN,
            Chains.POLYGON,
            Chains.MONAD,
            Chains.XLAYER,
            Chains.WORLDCHAIN,
            Chains.SONEIUM,
            Chains.TEMPO,
            Chains.MEGAETH,
            Chains.ROBINHOOD,
            Chains.BASE,
            Chains.ARBITRUM,
            Chains.AVALANCHE,
            Chains.CELO,
            Chains.INK,
            Chains.ZORA
        ];

        for (uint256 i = 0; i < ids.length; i++) {
            assertTrue(address(Chains.poolManager(ids[i])) != address(0));
            assertGt(bytes(Chains.slug(ids[i])).length, 0);
        }
    }

    function test_unsupportedChain_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Chains.UnsupportedChain.selector, uint256(999999)));
        harness.poolManager(999999);
    }

    function test_targetChains() public pure {
        assertEq(address(Chains.poolManager(Chains.BASE)), 0x498581fF718922c3f8e6A244956aF099B2652b2b);
        assertEq(address(Chains.poolManager(Chains.ARBITRUM)), 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32);
        assertEq(address(Chains.poolManager(Chains.UNICHAIN)), 0x1F98400000000000000000000000000000000004);
        assertEq(address(Chains.poolManager(Chains.ROBINHOOD)), 0x8366a39CC670B4001A1121B8F6A443A643e40951);
    }
}
