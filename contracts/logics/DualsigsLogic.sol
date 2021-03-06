pragma solidity ^0.5.4;

import "./base/AccountBaseLogic.sol";

/**
* @title DualsigsLogic
*/
contract DualsigsLogic is AccountBaseLogic {

	// Equals to bytes4(keccak256("changeAllOperationKeysWithoutDelay(address,address[])"))
	bytes4 private constant CHANGE_ALL_OPERATION_KEYS_WITHOUT_DELAY = 0x02064abc;
	// Equals to bytes4(keccak256("unfreezeWithoutDelay(address)"))
	bytes4 private constant UNFREEZE_WITHOUT_DELAY = 0x69521650;
	// Equals to bytes4(keccak256("addBackup(address,address)"))
	bytes4 private constant ADD_BACKUP = 0x426b7407;
	// Equals to bytes4(keccak256("proposeByBoth(address,address,bytes)"))
	bytes4 private constant PROPOSE_BY_BOTH = 0x7548cb94;

    event DualsigsLogicInitialised(address indexed account);
    event DualsigsLogicEntered(bytes data, uint256 indexed clientNonce, uint256 backupNonce);

	modifier allowDualSigsActionOnly(bytes memory _data) {
		bytes4 methodId = getMethodId(_data);
		require ((methodId == ADD_BACKUP) ||
			     (methodId == PROPOSE_BY_BOTH), "wrong entry");
		_;
	}

	// *************** Constructor ********************** //

	constructor(AccountStorage _accountStorage)
		AccountBaseLogic(_accountStorage)
		public
	{
	}

    // *************** Initialization ********************* //

    function initAccount(Account _account) external allowAccountCallsOnly(_account){
        emit DualsigsLogicInitialised(address(_account));
    }

	// *************** action entry ********************** //

    /* DualsigsLogic has 2 actions called from 'enter':
        addBackup, proposeByBoth
	*/
	function enter(
		bytes calldata _data, bytes calldata _clientSig, bytes calldata _backupSig, uint256 _clientNonce, uint256 _backupNonce
	)
		external allowDualSigsActionOnly(_data)
	{
        verifyClient(_data, _clientSig, _clientNonce);
        verifyBackup(_data, _backupSig, _backupNonce);
 
		// solium-disable-next-line security/no-low-level-calls
		(bool success,) = address(this).call(_data);
		require(success, "enterWithDualSigs failed");
		emit DualsigsLogicEntered(_data, _clientNonce, _backupNonce);
	}

	function verifyClient(bytes memory _data, bytes memory _clientSig, uint256 _clientNonce) internal {
		address client = getSignerAddress(_data);
		//client sign with admin key
		uint256 clientKeyIndex = 0;
		checkKeyStatus(client, clientKeyIndex);
		address signingKey = accountStorage.getKeyData(client, clientKeyIndex);
		if ((getMethodId(_data) == PROPOSE_BY_BOTH) && 
		    (getProposedMethodId(_data) == CHANGE_ADMIN_KEY_WITHOUT_DELAY)) {
			// if proposed action is 'changeAdminKeyWithoutDelay', do not check _clientNonce
			verifySig(signingKey, _clientSig, getSignHashWithoutNonce(_data));
		} else {
			checkAndUpdateNonce(signingKey, _clientNonce);
			verifySig(signingKey, _clientSig, getSignHash(_data, _clientNonce));
		}
	}

    function verifyBackup(bytes memory _data, bytes memory _backupSig, uint256 _backupNonce) internal {
		address backup = getSecondSignerAddress(_data);
		//backup sign with assist key
		uint256 backupKeyIndex = 4;
		checkKeyStatus(backup, backupKeyIndex);
		address signingKey = accountStorage.getKeyData(backup, backupKeyIndex);
		checkAndUpdateNonce(signingKey, _backupNonce);
		verifySig(signingKey, _backupSig, getSignHash(_data, _backupNonce));
	}

	// *************** change admin key ********************** //

    // called from 'executeProposal'
	function changeAdminKeyWithoutDelay(address payable _account, address _pkNew) external allowSelfCallsOnly {
		address pk = accountStorage.getKeyData(_account, 0);
		require(pk != _pkNew, "identical admin key already exists");
		require(_pkNew != address(0), "0x0 is invalid");
		accountStorage.setKeyData(_account, 0, _pkNew);
		//clear any existing related delay data and proposal
		accountStorage.clearDelayData(_account, CHANGE_ADMIN_KEY);
		accountStorage.clearDelayData(_account, CHANGE_ADMIN_KEY_BY_BACKUP);
		accountStorage.clearDelayData(_account, CHANGE_ALL_OPERATION_KEYS);
		accountStorage.clearDelayData(_account, UNFREEZE);
		clearRelatedProposalAfterAdminKeyChanged(_account);
	}

	// *************** change all operation keys ********************** //

    // called from 'executeProposal'
	function changeAllOperationKeysWithoutDelay(address payable _account, address[] calldata _pks) external allowSelfCallsOnly {
		uint256 keyCount = accountStorage.getOperationKeyCount(_account);
		require(_pks.length == keyCount, "invalid number of keys");
		for (uint256 i = 0; i < keyCount; i++) {
			address pk = _pks[i];
			require(pk != address(0), "0x0 is invalid");
			accountStorage.setKeyData(_account, i+1, pk);
			accountStorage.setKeyStatus(_account, i+1, 0);
		}
	}

	// *************** freeze/unfreeze all operation keys ********************** //

    // called from 'executeProposal'
	function unfreezeWithoutDelay(address payable _account) external allowSelfCallsOnly {
		for (uint256 i = 0; i < accountStorage.getOperationKeyCount(_account); i++) {
			if (accountStorage.getKeyStatus(_account, i+1) == 1) {
				accountStorage.setKeyStatus(_account, i+1, 0);
			}
		}
	}

	// *************** add backup ********************** //

    // called from 'enter'
	function addBackup(address payable _account, address _backup) external allowSelfCallsOnly {
		require(_account != _backup, "cannot be backup of oneself");
		uint256 index = findAvailableSlot(_account, _backup);
		require(index <= MAX_DEFINED_BACKUP_INDEX, "invalid or duplicate or no vacancy");
		accountStorage.setBackup(_account, index, _backup, now + DELAY_CHANGE_BACKUP, uint256(-1));
	}

    // return backupData index(0~5), 6 means not found
    // 'available' means empty or expired
	function findAvailableSlot(address _account, address _backup) public view returns(uint) {
		uint index = MAX_DEFINED_BACKUP_INDEX + 1;
		if (_backup == address(0)) {
			return index;
		}
		for (uint256 i = 0; i <= MAX_DEFINED_BACKUP_INDEX; i++) {
            address backup = accountStorage.getBackupAddress(_account, i);
            uint256 expiryDate = accountStorage.getBackupExpiryDate(_account, i);
			// _backup already exists and not expired
			if ((backup == _backup) && (expiryDate > now)) {
				return MAX_DEFINED_BACKUP_INDEX + 1;
			}
			if (index > MAX_DEFINED_BACKUP_INDEX) {
				// zero address or backup expired
				if ((backup == address(0)) || (expiryDate <= now)) {
	                index = i;
				}
			}
		}
		return index;
	}

	// *************** propose, approve, execute and cancel proposal ********************** //

    // called from 'enter'
	// proposer is client in the case of 'proposeByBoth'
	function proposeByBoth(address payable _client, address _backup, bytes calldata _functionData) external allowSelfCallsOnly {
		bytes4 proposedActionId = getMethodId(_functionData);
		require(isFastAction(proposedActionId), "invalid proposal");
		checkRelation(_client, _backup);
		bytes32 functionHash = keccak256(_functionData);
		accountStorage.setProposalData(_client, _client, proposedActionId, functionHash, _backup);
	}

	function isFastAction(bytes4 _actionId) internal pure returns(bool) {
		if ((_actionId == CHANGE_ADMIN_KEY_WITHOUT_DELAY) ||
			(_actionId == CHANGE_ALL_OPERATION_KEYS_WITHOUT_DELAY) ||
			(_actionId == UNFREEZE_WITHOUT_DELAY))
		{
			return true;
		}
		return false;
	}

	// *************** internal functions ********************** //

	function getSecondSignerAddress(bytes memory _b) internal pure returns (address _a) {
		require(_b.length >= 68, "data length too short");
		// solium-disable-next-line security/no-inline-assembly
		assembly {
			//68 = 32 + 4 + 32
			let mask := 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
			_a := and(mask, mload(add(_b, 68)))
		}
	}

    function getProposedMethodId(bytes memory _b) internal pure returns (bytes4 _a) {
		require(_b.length >= 164, "data length too short");
        // solium-disable-next-line security/no-inline-assembly
        assembly {
			/* 'proposeByBoth' data example:
			0x
			7548cb94                                                            // method id
			000000000000000000000000b7055946345ad40f8cca3feb075dfadd9e2641b5    // param 0
			00000000000000000000000011390e32ccdfb3f85e92b949c72fe482d77838f3    // param 1
			0000000000000000000000000000000000000000000000000000000000000060    // data length including padding
			0000000000000000000000000000000000000000000000000000000000000044    // true data length
			441d2e50                                                            // method id(proposed method: changeAdminKeyWithoutDelay)
			000000000000000000000000b7055946345ad40f8cca3feb075dfadd9e2641b5    // param 0
			00000000000000000000000013667a2711960c95fae074f90e0f739bc324d1ed    // param 1
			00000000000000000000000000000000000000000000000000000000            // padding
			*/
            // the first 32 bytes is the length of the bytes array _b
			// 32 + 4 + 32 + 32 + 32 + 32 = 164
            _a := mload(add(_b, 164))
        }
    }

    function getSignHashWithoutNonce(bytes memory _data) internal view returns(bytes32) {
        // use EIP 191
        // 0x1900 + this logic address + data
        bytes32 msgHash = keccak256(abi.encodePacked(byte(0x19), byte(0), address(this), _data));
        bytes32 prefixedHash = keccak256(abi.encodePacked(SIGN_HASH_PREFIX, msgHash));
        return prefixedHash;
    }

}
