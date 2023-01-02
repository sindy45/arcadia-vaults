/**
 * Created by Arcadia Finance
 * https://www.arcadia.finance
 *
 * SPDX-License-Identifier: BUSL-1.1
 */
pragma solidity >=0.8.0 <0.9.0;

import "./utils/LogExpMath.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IERC721.sol";
import "./interfaces/IERC1155.sol";
import "./interfaces/IERC4626.sol";
import "./interfaces/ILiquidator.sol";
import "./interfaces/IRegistry.sol";
import "./interfaces/IMainRegistry.sol";
import "./interfaces/ILendingPool.sol";
import "./interfaces/ITrustedProtocol.sol";

/**
 * @title An Arcadia Vault used to deposit a combination of all kinds of assets
 * @author Arcadia Finance
 * @notice Users can use this vault to deposit assets (ERC20, ERC721, ERC1155, ...).
 * The vault will denominate all the pooled assets into one baseCurrency (one unit of account, like usd or eth).
 * An increase of value of one asset will offset a decrease in value of another asset.
 * Users can take out a credit line against the single denominated value.
 * Ensure your total value denomination remains above the liquidation threshold, or risk being liquidated!
 * @dev A vault is a smart contract that will contain multiple assets.
 * Using getValue(<baseCurrency>), the vault returns the combined total value of all (whitelisted) assets the vault contains.
 * Integrating this vault as means of collateral management for your own protocol that requires collateral is encouraged.
 * Arcadia's vault functions will guarantee you a certain value of the vault.
 * For whitelists or liquidation strategies specific to your protocol, contact: dev at arcadia.finance
 */
contract Vault {
    /**
     * @dev Storage slot with the address of the current implementation.
     * This is the keccak-256 hash of "eip1967.proxy.implementation" subtracted by 1.
     */
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bool public isTrustedProtocolSet;

    uint16 public vaultVersion;
    uint256 public life;

    address public owner;
    address public liquidator;
    address public registry;
    address public trustedProtocol;

    address[] public erc20Stored;
    address[] public erc721Stored;
    address[] public erc1155Stored;

    uint256[] public erc721TokenIds;
    uint256[] public erc1155TokenIds;

    mapping(address => bool) public allowed;

    struct AddressSlot {
        address value;
    }

    struct VaultInfo {
        uint16 liqThres; //2 decimals precision (factor 100)
        address baseCurrency;
    }

    VaultInfo public vault;

    event Upgraded(address indexed implementation);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Throws if called by any account other than the factory adress.
     */
    modifier onlyFactory() {
        require(msg.sender == IMainRegistry(registry).factoryAddress(), "V: You are not the factory");
        _;
    }

    /**
     * @dev Throws if called by any account other than an authorised adress.
     */
    modifier onlyAuthorized() {
        require(allowed[msg.sender], "V: You are not authorized");
        _;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(msg.sender == owner, "V: You are not the owner");
        _;
    }

    constructor() {}

    /* ///////////////////////////////////////////////////////////////
                          VAULT MANAGEMENT
    /////////////////////////////////////////////////////////////// */

    /**
     * @notice Initiates the variables of the vault
     * @dev A proxy will be used to interact with the vault logic.
     * Therefore everything is initialised through an init function.
     * This function will only be called (once) in the same transaction as the proxy vault creation through the factory.
     * Costly function (156k gas)
     * @param owner_ The tx.origin: the sender of the 'createVault' on the factory
     * @param registry_ The 'beacon' contract to which should be looked at for external logic.
     * @param vaultVersion_ The version of the vault logic.
     */
    function initialize(address owner_, address registry_, uint16 vaultVersion_) external payable {
        require(vaultVersion == 0, "V_I: Already initialized!");
        require(vaultVersion_ != 0, "V_I: Invalid vault version");
        owner = owner_;
        registry = registry_;
        vaultVersion = vaultVersion_;
    }

    /**
     * @dev Stores a new address in the EIP1967 implementation slot & updates the vault version.
     */
    function upgradeVault(address newImplementation, uint16 newVersion) external onlyFactory {
        vaultVersion = newVersion;
        _getAddressSlot(_IMPLEMENTATION_SLOT).value = newImplementation;

        emit Upgraded(newImplementation);
    }

    /**
     * @dev Returns an `AddressSlot` with member `value` located at `slot`.
     */
    function _getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        assembly {
            r.slot := slot
        }
    }

    /* ///////////////////////////////////////////////////////////////
                        OWNERSHIP MANAGEMENT
    /////////////////////////////////////////////////////////////// */

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner via the factory.
     * A transfer of ownership of this vault by a transfer
     * of ownership of the accompanying ERC721 Vault NFT
     * issued by the factory. Owner of Vault NFT = owner of vault
     */
    function transferOwnership(address newOwner) public onlyFactory {
        if (newOwner == address(0)) {
            revert("V_TO: INVALID_RECIPIENT");
        }
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /* ///////////////////////////////////////////////////////////////
                        BASE CURRENCY LOGIC
    /////////////////////////////////////////////////////////////// */

    /**
     * @notice Sets the baseCurrency of a vault.
     * @param baseCurrency the new baseCurrency for the vault.
     */
    function setBaseCurrency(address baseCurrency) public onlyAuthorized {
        _setBaseCurrency(baseCurrency);
    }

    /**
     * @notice Internal function: sets baseCurrency.
     * @param baseCurrency_ the new baseCurrency for the vault.
     * @dev First checks if there is no locked value. If there is no value locked then the baseCurrency gets changed to the param
     */
    function _setBaseCurrency(address baseCurrency_) private {
        require(getUsedMargin() == 0, "V_SBC: Can't change baseCurrency when Used Margin > 0");
        require(IMainRegistry(registry).isBaseCurrency(baseCurrency_), "V_SBC: baseCurrency not found");
        vault.baseCurrency = baseCurrency_; //Change this to where ever it is going to be actually set
    }

    /* ///////////////////////////////////////////////////////////////
                    MARGIN ACCOUNT SETTINGS
    /////////////////////////////////////////////////////////////// */

    /**
     * @notice Initiates a margin account on the vault for one trusted application..
     * @param protocol The contract address of the trusted application.
     * @dev The open position is fetched at a contract of the application -> only allow trusted audited protocols!!!
     * @dev Currently only one trusted protocol can be set.
     * @dev Only open margin accounts for protocols you trust!
     * The protocol has significant authorisation: use margin (-> trigger liquidation)
     */
    function openTrustedMarginAccount(address protocol) public onlyOwner {
        require(!isTrustedProtocolSet, "V_OMA: ALREADY SET");
        //ToDo: Check in Factory/Mainregistry if protocol is indeed trusted?

        (bool success, address baseCurrency, address liquidator_) =
            ITrustedProtocol(protocol).openMarginAccount(vaultVersion);
        require(success, "V_OMA: OPENING ACCOUNT REVERTED");

        liquidator = liquidator_;
        trustedProtocol = protocol;
        if (vault.baseCurrency != baseCurrency) {
            _setBaseCurrency(baseCurrency);
        }
        isTrustedProtocolSet = true;
        allowed[protocol] = true;
    }

    /**
     * @notice Closes the margin account on the vault of the trusted application..
     * @dev The open position is fetched at a contract of the application -> only allow trusted audited protocols!!!
     * @dev Currently only one trusted protocol can be set.
     */
    function closeTrustedMarginAccount() public onlyOwner {
        require(isTrustedProtocolSet, "V_CMA: NOT SET");
        require(ITrustedProtocol(trustedProtocol).getOpenPosition(address(this)) == 0, "V_CMA: NON-ZERO OPEN POSITION");

        isTrustedProtocolSet = false;
        allowed[trustedProtocol] = false;
    }

    /* ///////////////////////////////////////////////////////////////
                          MARGIN REQUIREMENTS
    /////////////////////////////////////////////////////////////// */

    /**
     * @notice Can be called by authorised applications to increase a margin position.
     * @param baseCurrency The Base-currency in which the margin position is denominated
     * @param amount The amount the position is increased.
     * @return success Boolean indicating if there is sufficient free margin to increase the margin position
     */
    function increaseMarginPosition(address baseCurrency, uint256 amount)
        public
        onlyAuthorized
        returns (bool success)
    {
        if (baseCurrency != vault.baseCurrency) {
            return false;
        }
        (address[] memory assetAddresses, uint256[] memory assetIds, uint256[] memory assetAmounts) =
            generateAssetData();
        (uint256 collateralValue, uint256 liquidationThreshold) = IRegistry(registry)
            .getCollateralValueAndLiquidationThreshold(assetAddresses, assetIds, assetAmounts, vault.baseCurrency);

        // Check that the collateral value is bigger than the sum  of the already used margin and the increase
        // ToDo: For trusted protocols, already pass usedMargin with the call -> avoid additional hop back to trusted protocol to fetch already open debt
        success = collateralValue >= getUsedMargin() + amount;

        // Can safely cast to uint16 since liquidationThreshold is maximal 10000
        if (success) vault.liqThres = uint16(liquidationThreshold);
    }

    /**
     * @notice Can be called by authorised applications to close or decrease a margin position.
     * @param baseCurrency The Base-currency in which the margin position is denominated.
     * @dev All values expressed in the base currency of the vault with same number of decimals as the base currency.
     * @return success Boolean indicating if there the margin position is successfully decreased.
     * @dev ToDo: Function mainly necessary for integration with untrusted protocols, which is not yet implemnted.
     */
    function decreaseMarginPosition(address baseCurrency, uint256) public view onlyAuthorized returns (bool success) {
        success = baseCurrency == vault.baseCurrency;
    }

    /**
     * @notice Returns the total value of the vault in a specific baseCurrency
     * @dev Fetches all stored assets with their amounts on the proxy vault.
     * Using a specified baseCurrency, fetches the value of all assets on the proxy vault in said baseCurrency.
     * @param baseCurrency The asset to return the value in.
     * @return vaultValue Total value stored on the vault, expressed in baseCurrency.
     */
    function getVaultValue(address baseCurrency) public view returns (uint256 vaultValue) {
        (address[] memory assetAddresses, uint256[] memory assetIds, uint256[] memory assetAmounts) =
            generateAssetData();
        vaultValue = IRegistry(registry).getTotalValue(assetAddresses, assetIds, assetAmounts, baseCurrency);
    }

    /**
     * @notice Calculates the total collateral value of the vault.
     * @return collateralValue The collateral value, returned in the decimals of the base currency.
     * @dev Returns the value denominated in the baseCurrency in which the proxy vault is initialised.
     * @dev The collateral value of the vault is equal to the spot value of the underlying assets,
     * discounted by a haircut (with a factor 100 / collateral_threshold). Since the value of
     * collateralised assets can fluctuate, the haircut guarantees that the vault
     * remains over-collateralised with a high confidence level (99,9%+). The size of the
     * haircut depends on the underlying risk of the assets in the vault, the bigger the volatility
     * or the smaller the on-chain liquidity, the bigger the haircut will be.
     */
    function getCollateralValue() public view returns (uint256 collateralValue) {
        (address[] memory assetAddresses, uint256[] memory assetIds, uint256[] memory assetAmounts) =
            generateAssetData();
        collateralValue =
            IRegistry(registry).getCollateralValue(assetAddresses, assetIds, assetAmounts, vault.baseCurrency);
    }

    /**
     * @notice Returns the used margin of the proxy vault.
     * @return usedMargin The used amount of margin a user has taken
     * @dev The used margin is denominated in the baseCurrency of the proxy vault.
     * @dev Currently only one trusted application (Arcadia Lending) can open a margin account.
     * The open position is fetched at a contract of the application -> only allow trusted audited protocols!!!
     */
    function getUsedMargin() public view returns (uint256 usedMargin) {
        usedMargin = ITrustedProtocol(trustedProtocol).getOpenPosition(address(this));
    }

    /**
     * @notice Calculates the remaining margin the owner of the proxy vault can use.
     * @return freeMargin The remaining amount of margin a user can take.
     * @dev The free margin is denominated in the baseCurrency of the proxy vault,
     * with an equal number of decimals as the base currency.
     */
    function getFreeMargin() public view returns (uint256 freeMargin) {
        uint256 collateralValue = getCollateralValue();
        uint256 usedMargin = getUsedMargin();

        //gas: explicit check is done to prevent underflow
        unchecked {
            freeMargin = collateralValue > usedMargin ? collateralValue - usedMargin : 0;
        }
    }

    /* ///////////////////////////////////////////////////////////////
                          LIQUIDATION LOGIC
    /////////////////////////////////////////////////////////////// */

    /**
     * @notice Function called to start a vault liquidation.
     * @dev Requires an unhealthy vault (value / debt < liqThres).
     * Starts the vault auction on the liquidator contract.
     * Increases the life of the vault to indicate a liquidation has happened.
     * Sets debtInfo todo: needed?
     * Transfers ownership of the proxy vault to the liquidator!
     * @param liquidationKeeper Addross of the keeper who initiated the liquidation process.
     * @return success Boolean returning if the liquidation process is successfully started.
     */
    function liquidateVault(address liquidationKeeper) public onlyFactory returns (bool success, address liquidator_) {
        //gas: 35 gas cheaper to not take debt into memory
        uint256 totalValue = getVaultValue(vault.baseCurrency);
        uint256 usedMargin = getUsedMargin();
        uint256 leftHand;
        uint256 rightHand;

        unchecked {
            //gas: cannot overflow unless totalValue is
            //higher than 1.15 * 10**57 * 10**18 decimals
            leftHand = totalValue * 100;
        }
        //ToDo: move to unchecked?
        //gas: cannot realisticly overflow: usedMargin will be always smaller than uint128.
        // so uint128 * uint8 << uint256
        rightHand = usedMargin * vault.liqThres;

        require(leftHand < rightHand, "V_LV: This vault is healthy");

        uint8 baseCurrencyIdentifier = IRegistry(registry).assetToBaseCurrency(vault.baseCurrency);

        require(
            //ToDo: check on usedMargin?
            ILiquidator(liquidator).startAuction(
                address(this),
                life,
                liquidationKeeper,
                owner,
                uint128(usedMargin),
                vault.liqThres,
                baseCurrencyIdentifier
            ),
            "V_LV: Failed to start auction!"
        );

        //gas: good luck overflowing this
        unchecked {
            ++life;
        }

        return (true, liquidator);
    }

    /* ///////////////////////////////////////////////////////////////
                    ASSET DEPOSIT/WITHDRAWN LOGIC
    /////////////////////////////////////////////////////////////// */

    /**
     * @notice Deposits assets into the proxy vault by the proxy vault owner.
     * @dev All arrays should be of same length, each index in each array corresponding
     * to the same asset that will get deposited. If multiple asset IDs of the same contract address
     * are deposited, the assetAddress must be repeated in assetAddresses.
     * The ERC20 gets deposited by transferFrom. ERC721 & ERC1155 using safeTransferFrom.
     * Can only be called by the proxy vault owner to avoid attacks where malicous actors can deposit 1 wei assets,
     * increasing gas costs upon credit issuance and withrawals.
     * Example inputs:
     * [wETH, DAI, Bayc, Interleave], [0, 0, 15, 2], [10**18, 10**18, 1, 100], [0, 0, 1, 2]
     * [Interleave, Interleave, Bayc, Bayc, wETH], [3, 5, 16, 17, 0], [123, 456, 1, 1, 10**18], [2, 2, 1, 1, 0]
     * @param assetAddresses The contract addresses of the asset. For each asset to be deposited one address,
     * even if multiple assets of the same contract address are deposited.
     * @param assetIds The asset IDs that will be deposited for ERC721 & ERC1155.
     * When depositing an ERC20, this will be disregarded, HOWEVER a value (eg. 0) must be filled!
     * @param assetAmounts The amounts of the assets to be deposited.
     * @param assetTypes The types of the assets to be deposited.
     * 0 = ERC20
     * 1 = ERC721
     * 2 = ERC1155
     * Any other number = failed tx
     */
    function deposit(
        address[] calldata assetAddresses,
        uint256[] calldata assetIds,
        uint256[] calldata assetAmounts,
        uint256[] calldata assetTypes
    ) external payable onlyOwner {
        uint256 assetAddressesLength = assetAddresses.length;

        require(
            assetAddressesLength == assetIds.length && assetAddressesLength == assetAmounts.length
                && assetAddressesLength == assetTypes.length,
            "V_D: Length mismatch"
        );

        require(IRegistry(registry).batchIsWhiteListed(assetAddresses, assetIds), "V_D: Not all assets whitelisted");

        for (uint256 i; i < assetAddressesLength;) {
            if (assetTypes[i] == 0) {
                _depositERC20(msg.sender, assetAddresses[i], assetAmounts[i]);
            } else if (assetTypes[i] == 1) {
                _depositERC721(msg.sender, assetAddresses[i], assetIds[i]);
            } else if (assetTypes[i] == 2) {
                _depositERC1155(msg.sender, assetAddresses[i], assetIds[i], assetAmounts[i]);
            } else {
                require(false, "V_D: Unknown asset type");
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Processes withdrawals of assets by and to the owner of the proxy vault.
     * @dev All arrays should be of same length, each index in each array corresponding
     * to the same asset that will get withdrawn. If multiple asset IDs of the same contract address
     * are to be withdrawn, the assetAddress must be repeated in assetAddresses.
     * The ERC20 get withdrawn by transfers. ERC721 & ERC1155 using safeTransferFrom.
     * Can only be called by the proxy vault owner.
     * Will fail if balance on proxy vault is not sufficient for one of the withdrawals.
     * Will fail if "the value after withdrawal / open debt (including unrealised debt) > collateral threshold".
     * If no debt is taken yet on this proxy vault, users are free to withraw any asset at any time.
     * Example inputs:
     * [wETH, DAI, Bayc, Interleave], [0, 0, 15, 2], [10**18, 10**18, 1, 100], [0, 0, 1, 2]
     * [Interleave, Interleave, Bayc, Bayc, wETH], [3, 5, 16, 17, 0], [123, 456, 1, 1, 10**18], [2, 2, 1, 1, 0]
     * @dev After withdrawing assets, the interest rate is renewed
     * @param assetAddresses The contract addresses of the asset. For each asset to be withdrawn one address,
     * even if multiple assets of the same contract address are withdrawn.
     * @param assetIds The asset IDs that will be withdrawn for ERC721 & ERC1155.
     * When withdrawing an ERC20, this will be disregarded, HOWEVER a value (eg. 0) must be filled!
     * @param assetAmounts The amounts of the assets to be withdrawn.
     * @param assetTypes The types of the assets to be withdrawn.
     * 0 = ERC20
     * 1 = ERC721
     * 2 = ERC1155
     * Any other number = failed tx
     */
    function withdraw(
        address[] calldata assetAddresses,
        uint256[] calldata assetIds,
        uint256[] calldata assetAmounts,
        uint256[] calldata assetTypes
    ) external payable onlyOwner {
        uint256 assetAddressesLength = assetAddresses.length;

        require(
            assetAddressesLength == assetIds.length && assetAddressesLength == assetAmounts.length
                && assetAddressesLength == assetTypes.length,
            "V_W: Length mismatch"
        );

        for (uint256 i; i < assetAddressesLength;) {
            if (assetTypes[i] == 0) {
                _withdrawERC20(msg.sender, assetAddresses[i], assetAmounts[i]);
            } else if (assetTypes[i] == 1) {
                _withdrawERC721(msg.sender, assetAddresses[i], assetIds[i]);
            } else if (assetTypes[i] == 2) {
                _withdrawERC1155(msg.sender, assetAddresses[i], assetIds[i], assetAmounts[i]);
            } else {
                require(false, "V_W: Unknown asset type");
            }
            unchecked {
                ++i;
            }
        }

        uint256 usedMargin = getUsedMargin();
        if (usedMargin != 0) {
            require(getCollateralValue() > usedMargin, "V_W: coll. value too low!");
        }
    }

    /**
     * @notice Internal function used to deposit ERC20 tokens.
     * @dev Used for all tokens types = 0. Note the transferFrom, not the safeTransferFrom to allow legacy ERC20s.
     * After successful transfer, the function checks whether the same asset has been deposited.
     * This check is done using a loop: writing it in a mapping vs extra loops is in favor of extra loops in this case.
     * If the address has not yet been seen, the ERC20 token address is stored.
     * @param from Address the tokens should be taken from. This address must have pre-approved the proxy vault.
     * @param ERC20Address The asset address that should be transferred.
     * @param amount The amount of ERC20 tokens to be transferred.
     */
    function _depositERC20(address from, address ERC20Address, uint256 amount) private {
        require(IERC20(ERC20Address).transferFrom(from, address(this), amount), "Transfer from failed");

        uint256 erc20StoredLength = erc20Stored.length;
        for (uint256 i; i < erc20StoredLength;) {
            if (erc20Stored[i] == ERC20Address) {
                return;
            }
            unchecked {
                ++i;
            }
        }

        erc20Stored.push(ERC20Address);
        //TODO: see what the most gas efficient manner is to store/read/loop over this list to avoid duplicates
    }

    /**
     * @notice Internal function used to deposit ERC721 tokens.
     * @dev Used for all tokens types = 1. Note the transferFrom. No amounts are given since ERC721 are one-off's.
     * After successful transfer, the function pushes the ERC721 address to the stored token and stored ID array.
     * This may cause duplicates in the ERC721 stored addresses array, but this is intended.
     * @param from Address the tokens should be taken from. This address must have pre-approved the proxy vault.
     * @param ERC721Address The asset address that should be transferred.
     * @param id The ID of the token to be transferred.
     */
    function _depositERC721(address from, address ERC721Address, uint256 id) private {
        IERC721(ERC721Address).transferFrom(from, address(this), id);

        erc721Stored.push(ERC721Address);
        //TODO: see what the most gas efficient manner is to store/read/loop over this list to avoid duplicates
        erc721TokenIds.push(id);
    }

    /**
     * @notice Internal function used to deposit ERC1155 tokens.
     * @dev Used for all tokens types = 2. Note the safeTransferFrom.
     * After successful transfer, the function checks whether the combination of address & ID has already been stored.
     * If not, the function pushes the new address and ID to the stored arrays.
     * This may cause duplicates in the ERC1155 stored addresses array, but this is intended.
     * @param from The Address the tokens should be taken from. This address must have pre-approved the proxy vault.
     * @param ERC1155Address The asset address that should be transferred.
     * @param id The ID of the token to be transferred.
     * @param amount The amount of ERC1155 tokens to be transferred.
     */
    function _depositERC1155(address from, address ERC1155Address, uint256 id, uint256 amount) private {
        IERC1155(ERC1155Address).safeTransferFrom(from, address(this), id, amount, "");

        bool addrSeen;

        uint256 erc1155StoredLength = erc1155Stored.length;
        for (uint256 i; i < erc1155StoredLength;) {
            if (erc1155Stored[i] == ERC1155Address) {
                if (erc1155TokenIds[i] == id) {
                    addrSeen = true;
                    break;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (!addrSeen) {
            erc1155Stored.push(ERC1155Address); //TODO: see what the most gas efficient manner is to store/read/loop over this list to avoid duplicates
            erc1155TokenIds.push(id);
        }
    }

    /**
     * @notice Internal function used to withdraw ERC20 tokens.
     * @dev Used for all tokens types = 0. Note the transferFrom, not the safeTransferFrom to allow legacy ERC20s.
     * After successful transfer, the function checks whether the proxy vault has any leftover balance of said asset.
     * If not, it will pop() the ERC20 asset address from the stored addresses array.
     * Note: this shifts the order of erc20Stored!
     * This check is done using a loop: writing it in a mapping vs extra loops is in favor of extra loops in this case.
     * @param to Address the tokens should be sent to. This will in any case be the proxy vault owner
     * either being the original user or the liquidator!.
     * @param ERC20Address The asset address that should be transferred.
     * @param amount The amount of ERC20 tokens to be transferred.
     */
    function _withdrawERC20(address to, address ERC20Address, uint256 amount) private {
        require(IERC20(ERC20Address).transfer(to, amount), "Transfer from failed");

        if (IERC20(ERC20Address).balanceOf(address(this)) == 0) {
            uint256 erc20StoredLength = erc20Stored.length;

            if (erc20StoredLength == 1) {
                // there was only one ERC20 stored on the contract, safe to remove list
                erc20Stored.pop();
            } else {
                for (uint256 i; i < erc20StoredLength;) {
                    if (erc20Stored[i] == ERC20Address) {
                        erc20Stored[i] = erc20Stored[erc20StoredLength - 1];
                        erc20Stored.pop();
                        break;
                    }
                    unchecked {
                        ++i;
                    }
                }
            }
        }
    }

    /**
     * @notice Internal function used to withdraw ERC721 tokens.
     * @dev Used for all tokens types = 1. Note the safeTransferFrom. No amounts are given since ERC721 are one-off's.
     * After successful transfer, the function checks whether any other ERC721 is deposited in the proxy vault.
     * If not, it pops the stored addresses and stored IDs (pop() of two arrs is 180 gas cheaper than deleting).
     * If there are, it loops through the stored arrays and searches the ID that's withdrawn,
     * then replaces it with the last index, followed by a pop().
     * Sensitive to ReEntrance attacks! SafeTransferFrom therefore done at the end of the function.
     * @param to Address the tokens should be taken from. This address must have pre-approved the proxy vault.
     * @param ERC721Address The asset address that should be transferred.
     * @param id The ID of the token to be transferred.
     */
    function _withdrawERC721(address to, address ERC721Address, uint256 id) private {
        uint256 tokenIdLength = erc721TokenIds.length;

        if (tokenIdLength == 1) {
            // there was only one ERC721 stored on the contract, safe to remove both lists
            erc721TokenIds.pop();
            erc721Stored.pop();
        } else {
            for (uint256 i; i < tokenIdLength;) {
                if (erc721TokenIds[i] == id && erc721Stored[i] == ERC721Address) {
                    erc721TokenIds[i] = erc721TokenIds[tokenIdLength - 1];
                    erc721TokenIds.pop();
                    erc721Stored[i] = erc721Stored[tokenIdLength - 1];
                    erc721Stored.pop();
                    break;
                }
                unchecked {
                    ++i;
                }
            }
        }

        IERC721(ERC721Address).safeTransferFrom(address(this), to, id);
    }

    /**
     * @notice Internal function used to withdraw ERC1155 tokens.
     * @dev Used for all tokens types = 2. Note the safeTransferFrom.
     * After successful transfer, the function checks whether there is any balance left for that ERC1155.
     * If there is, it simply transfers the tokens.
     * If not, it checks whether it can pop() (used for gas savings vs delete) the stored arrays.
     * If there are still other ERC1155's on the contract, it looks for the ID and token address to be withdrawn
     * and then replaces it with the last index, followed by a pop().
     * Sensitive to ReEntrance attacks! SafeTransferFrom therefore done at the end of the function.
     * @param to Address the tokens should be taken from. This address must have pre-approved the proxy vault.
     * @param ERC1155Address The asset address that should be transferred.
     * @param id The ID of the token to be transferred.
     * @param amount The amount of ERC1155 tokens to be transferred.
     */
    function _withdrawERC1155(address to, address ERC1155Address, uint256 id, uint256 amount) private {
        uint256 tokenIdLength = erc1155TokenIds.length;
        if (IERC1155(ERC1155Address).balanceOf(address(this), id) - amount == 0) {
            if (tokenIdLength == 1) {
                erc1155TokenIds.pop();
                erc1155Stored.pop();
            } else {
                for (uint256 i; i < tokenIdLength;) {
                    if (erc1155TokenIds[i] == id) {
                        if (erc1155Stored[i] == ERC1155Address) {
                            erc1155TokenIds[i] = erc1155TokenIds[tokenIdLength - 1];
                            erc1155TokenIds.pop();
                            erc1155Stored[i] = erc1155Stored[tokenIdLength - 1];
                            erc1155Stored.pop();
                            break;
                        }
                    }
                    unchecked {
                        ++i;
                    }
                }
            }
        }

        IERC1155(ERC1155Address).safeTransferFrom(address(this), to, id, amount, "");
    }

    /* ///////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    /////////////////////////////////////////////////////////////// */

    /**
     * @notice Generates three arrays about the stored assets in the proxy vault
     * in the format needed for vault valuation functions.
     * @dev No balances are stored on the contract. Both for gas savings upon deposit and to allow for rebasing/... tokens.
     * Loops through the stored asset addresses and fills the arrays.
     * The vault valuation function fetches the asset type through the asset registries.
     * There is no importance of the order in the arrays, but all indexes of the arrays correspond to the same asset.
     * @return assetAddresses An array of asset addresses.
     * @return assetIds An array of asset IDs. Will be '0' for ERC20's
     * @return assetAmounts An array of the amounts/balances of the asset on the proxy vault. wil be '1' for ERC721's
     */
    function generateAssetData()
        public
        view
        returns (address[] memory assetAddresses, uint256[] memory assetIds, uint256[] memory assetAmounts)
    {
        uint256 totalLength;
        unchecked {
            totalLength = erc20Stored.length + erc721Stored.length + erc1155Stored.length;
        } //cannot practiaclly overflow. No max(uint256) contracts deployed
        assetAddresses = new address[](totalLength);
        assetIds = new uint256[](totalLength);
        assetAmounts = new uint256[](totalLength);

        uint256 i;
        uint256 erc20StoredLength = erc20Stored.length;
        address cacheAddr;
        for (; i < erc20StoredLength;) {
            cacheAddr = erc20Stored[i];
            assetAddresses[i] = cacheAddr;
            //assetIds[i] = 0; //gas: no need to store 0, index will continue anyway
            assetAmounts[i] = IERC20(cacheAddr).balanceOf(address(this));
            unchecked {
                ++i;
            }
        }

        uint256 j;
        uint256 erc721StoredLength = erc721Stored.length;
        for (; j < erc721StoredLength;) {
            cacheAddr = erc721Stored[j];
            assetAddresses[i] = cacheAddr;
            assetIds[i] = erc721TokenIds[j];
            assetAmounts[i] = 1;
            unchecked {
                ++i;
            }
            unchecked {
                ++j;
            }
        }

        uint256 k;
        uint256 erc1155StoredLength = erc1155Stored.length;
        for (; k < erc1155StoredLength;) {
            cacheAddr = erc1155Stored[k];
            assetAddresses[i] = cacheAddr;
            assetIds[i] = erc1155TokenIds[k];
            assetAmounts[i] = IERC1155(cacheAddr).balanceOf(address(this), erc1155TokenIds[k]);
            unchecked {
                ++i;
            }
            unchecked {
                ++k;
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) public pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) public pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }
}
