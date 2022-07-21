// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.14;

import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./IVault.sol";

contract ReleaseRegistry is OwnableUpgradeable, UUPSUpgradeable {
    address public vaultRegistry; // not used but kept in case of upgrade, can be removed if not used.
    uint256 public numReleases;
    mapping(uint256 => address) public releases;

    event NewRelease(
        uint256 indexed releaseId,
        address template,
        string apiVersion
    );

    event NewVault(
        address indexed token,
        uint256 indexed vaultId,
        address vault,
        string apiVersion
    );

    event NewExperimentalVault(
        address indexed token,
        address indexed deployer,
        address vault,
        string apiVersion
    );

    event VaultTagged(address vault, string tag);

    function initialize() external initializer {
        __Ownable_init();
    }

    function _authorizeUpgrade(address) internal override {
        require(msg.sender == owner(), "not allowed");
    }

    /**
    @notice Returns the api version of the latest release.
    @dev Throws if no releases are registered yet.
    @return The api version of the latest release.
    NOTE: Throws if there has not been a release yet
    */
    function latestRelease() external view returns (string memory) {
        return IVault(releases[numReleases - 1]).apiVersion(); // dev: no release
    }

    /**
    @notice
        Add a previously deployed Vault as the template contract for the latest release,
        to be used by further "forwarder-style" delegatecall proxy contracts that can be
        deployed from the registry throw other methods (to save gas).
    @dev
        Throws if caller isn't `governance`.
        Throws if `vault`'s governance isn't `governance`.
        Throws if the api version is the same as the previous release.
        Emits a `NewVault` event.
    @param _vault The vault that will be used as the template contract for the next release.
    */
    function newRelease(address _vault) external onlyOwner {
        // Check if the release is different from the current one
        // NOTE: This doesn't check for strict semver-style linearly increasing release versions
        uint256 releaseId = numReleases; // Next id in series
        if (releaseId > 0) {
            require(
                keccak256(
                    bytes(IVault(releases[releaseId - 1]).apiVersion())
                ) != keccak256(bytes(IVault(_vault).apiVersion())),
                "same api version"
            );
        }
        // Update latest release
        releases[releaseId] = _vault;
        numReleases = releaseId + 1;
        // Log the release for external listeners (e.g. Graph)
        emit NewRelease(releaseId, _vault, IVault(_vault).apiVersion());
    }

    function _newProxyVault(
        address _token,
        address _governance,
        address _rewards,
        address _guardian,
        string memory _name,
        string memory _symbol,
        uint256 _releaseTarget
    ) internal returns (address) {
        address vault;
        {
            address release = releases[_releaseTarget];
            require(release != address(0), "unknown release");
            vault = _clone(release);
        }
        // NOTE: Must initialize the Vault atomically with deploying it
        IVault(vault).initialize(
            _token,
            _governance,
            _rewards,
            _name,
            _symbol,
            _guardian
        );
        return vault;
    }

    function newVault(
        address _token,
        address _guardian,
        address _rewards,
        string calldata _name,
        string calldata _symbol
    ) external returns (address) {
        return
            newVault(
                _token,
                msg.sender,
                _guardian,
                _rewards,
                _name,
                _symbol,
                0
            );
    }

    /**
    @notice
        Create a new vault for the given token using the latest release in the registry,
        as a simple "forwarder-style" delegatecall proxy to the latest release. Also adds
        the new vault to the list of "endorsed" vaults for that token.
    @dev
        Throws if no releases are registered yet.
    @param _token The token that may be deposited into the new Vault.
    @param _governance vault governance
    @param _guardian The address authorized for guardian interactions in the new Vault.
    @param _rewards The address to use for collecting rewards in the new Vault
    @param _name Specify a custom Vault name. Set to empty string for default choice.
    @param _symbol Specify a custom Vault symbol name. Set to empty string for default choice.
    @param _releaseDelta Specify the number of releases prior to the latest to use as a target. Default is latest.
    @return The address of the newly-deployed vault
     */
    function newVault(
        address _token,
        address _governance,
        address _guardian,
        address _rewards,
        string calldata _name,
        string calldata _symbol,
        uint256 _releaseDelta
    ) public returns (address) {
        // NOTE: Underflow if no releases created yet, or targeting prior to release history
        uint256 releaseTarget = numReleases - 1 - _releaseDelta; // dev: no releases
        address vault = _newProxyVault(
            _token,
            _governance,
            _rewards,
            _guardian,
            _name,
            _symbol,
            releaseTarget
        );

        return vault;
    }

    function _clone(address _target) internal returns (address _newVault) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(_target));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            _newVault := create(0, clone_code, 0x37)
        }
    }
}
