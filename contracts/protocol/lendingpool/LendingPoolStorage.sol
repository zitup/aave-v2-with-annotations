// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;

import {UserConfiguration} from '../libraries/configuration/UserConfiguration.sol';
import {ReserveConfiguration} from '../libraries/configuration/ReserveConfiguration.sol';
import {ReserveLogic} from '../libraries/logic/ReserveLogic.sol';
import {ILendingPoolAddressesProvider} from '../../interfaces/ILendingPoolAddressesProvider.sol';
import {DataTypes} from '../libraries/types/DataTypes.sol';

contract LendingPoolStorage {
  using ReserveLogic for DataTypes.ReserveData;
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
  using UserConfiguration for DataTypes.UserConfigurationMap;

  // 地址提供合约，由initialize赋值
  ILendingPoolAddressesProvider internal _addressesProvider;

  // 资产的属性 token => properties
  mapping(address => DataTypes.ReserveData) internal _reserves;
  // 用户相关的配置 account => configuration
  mapping(address => DataTypes.UserConfigurationMap) internal _usersConfig;

  // the list of the available reserves, structured as a mapping for gas savings reasons
  // 资产列表 ID => token
  mapping(uint256 => address) internal _reservesList;

  // 资产数量
  uint256 internal _reservesCount;

  // 合约是否暂停
  bool internal _paused;

  // 固定利率借款数量占流动性的最大比例，分母1e4
  uint256 internal _maxStableRateBorrowSizePercent;

  // 闪电贷手续费比例，分母1e4
  uint256 internal _flashLoanPremiumTotal;

  // 资产最大数量
  uint256 internal _maxNumberOfReserves;
}
