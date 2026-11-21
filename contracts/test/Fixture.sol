// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ComplianceModule} from "../src/ComplianceModule.sol";
import {Council} from "../src/Council.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {PoolToken} from "../src/PoolToken.sol";
import {Refusal} from "../src/Refusal.sol";

/// Deploys through an external call, so a test's expectRevert applies to the deployment
/// alone and the test carries on after it.
contract Deployer {
    function council(address[] memory members, uint256 threshold, uint256 delay) external returns (Council) {
        return new Council(members, threshold, delay);
    }

    function registry(address council_) external returns (IdentityRegistry) {
        return new IdentityRegistry(council_);
    }

    function compliance(address council_, IdentityRegistry registry_, ComplianceModule.Rules memory rules)
        external
        returns (ComplianceModule)
    {
        return new ComplianceModule(council_, registry_, rules);
    }

    function token(uint8 decimals_, address council_, ComplianceModule compliance_) external returns (PoolToken) {
        return new PoolToken("x", "x", decimals_, council_, compliance_);
    }
}

/// A local deployment with synthetic actors only: opaque ids, no personal data.
abstract contract Fixture is Test {
    uint16 internal constant CA = 124;
    uint16 internal constant US = 840;
    uint16 internal constant BLOCKED = 408;
    uint256 internal constant START = 1_700_000_000;
    bytes32 internal constant REASON = keccak256("synthetic-case-record");

    Council internal council;
    IdentityRegistry internal registry;
    ComplianceModule internal compliance;
    PoolToken internal token;
    Deployer internal deployer = new Deployer();

    address internal m1 = makeAddr("member-1");
    address internal m2 = makeAddr("member-2");
    address internal m3 = makeAddr("member-3");
    address internal registrar = makeAddr("registrar");
    address internal agent = makeAddr("agent");
    address internal minter = makeAddr("minter");
    address internal alice = makeAddr("holder-a");
    address internal bob = makeAddr("holder-b");
    address internal carol = makeAddr("holder-c");
    address internal outsider = makeAddr("outsider");

    bytes32 internal constant ALICE_ID = keccak256("investor-a");
    bytes32 internal constant BOB_ID = keccak256("investor-b");
    bytes32 internal constant CAROL_ID = keccak256("investor-c");

    function setUp() public virtual {
        vm.warp(START);
        address[] memory members = new address[](3);
        members[0] = m1;
        members[1] = m2;
        members[2] = m3;
        council = new Council(members, 2, 1 days);
        registry = new IdentityRegistry(address(council));
        uint16[] memory countries = new uint16[](2);
        countries[0] = CA;
        countries[1] = US;
        compliance = new ComplianceModule(
            address(council),
            registry,
            ComplianceModule.Rules({allowedCountries: countries, maxHolders: 50, minHolding: 1, lockupEnd: 0})
        );
        token = new PoolToken("Synthetic Pool", "SPOOL", 6, address(council), compliance);

        vm.startPrank(address(council));
        registry.grantRole(registry.REGISTRAR_ROLE(), registrar);
        registry.grantRole(registry.AGENT_ROLE(), agent);
        token.grantRole(token.MINTER_ROLE(), minter);
        token.grantRole(token.AGENT_ROLE(), agent);
        vm.stopPrank();

        _register(alice, ALICE_ID, CA);
        _register(bob, BOB_ID, US);
        _register(carol, CAROL_ID, CA);
        vm.prank(minter);
        token.mint(alice, 1000);
    }

    function _register(address wallet, bytes32 id, uint16 country) internal {
        vm.prank(registrar);
        registry.register(
            wallet, id, country, IdentityRegistry.InvestorType.Professional, uint64(block.timestamp + 365 days)
        );
    }

    /// The documented process, in full: propose, a second approval, the delay, execute.
    function _viaCouncil(address target, bytes memory data) internal returns (bytes memory) {
        vm.prank(m1);
        bytes32 id = council.propose(target, data, REASON);
        vm.prank(m2);
        council.approve(id);
        vm.warp(block.timestamp + council.delay());
        vm.prank(m3);
        return council.execute(id, data);
    }

    function _refused(address from, address to, uint256 amount, Refusal r) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(PoolToken.TransferRefused.selector, from, to, amount, r);
    }
}
