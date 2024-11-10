// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeMath} from '../../../dependencies/openzeppelin/contracts/SafeMath.sol';
import {IERC20} from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import {ReserveLogic} from './ReserveLogic.sol';
import {ReserveConfiguration} from '../configuration/ReserveConfiguration.sol';
import {UserConfiguration} from '../configuration/UserConfiguration.sol';
import {WadRayMath} from '../math/WadRayMath.sol';
import {PercentageMath} from '../math/PercentageMath.sol';
import {IPriceOracleGetter} from '../../../interfaces/IPriceOracleGetter.sol';
import {DataTypes} from '../types/DataTypes.sol';

/**
 * @title GenericLogic library
 * @author Aave
 * @title Implements protocol-level logic to calculate and validate the state of a user
 */
library GenericLogic {
  using ReserveLogic for DataTypes.ReserveData;
  using SafeMath for uint256;
  using WadRayMath for uint256;
  using PercentageMath for uint256;
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
  using UserConfiguration for DataTypes.UserConfigurationMap;

  uint256 public constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1 ether;

  struct balanceDecreaseAllowedLocalVars {
    uint256 decimals;
    uint256 liquidationThreshold;
    uint256 totalCollateralInETH;
    uint256 totalDebtInETH;
    uint256 avgLiquidationThreshold;
    uint256 amountToDecreaseInETH;
    uint256 collateralBalanceAfterDecrease;
    uint256 liquidationThresholdAfterDecrease;
    uint256 healthFactorAfterDecrease;
    bool reserveUsageAsCollateralEnabled;
  }

  /**
   * @dev Checks if a specific balance decrease is allowed
   * (i.e. doesn't bring the user borrow position health factor under HEALTH_FACTOR_LIQUIDATION_THRESHOLD)
   * @param asset The address of the underlying asset of the reserve
   * @param user The address of the user
   * @param amount The amount to decrease
   * @param reservesData The data of all the reserves
   * @param userConfig The user configuration
   * @param reserves The list of all the active reserves
   * @param oracle The address of the oracle contract
   * @return true if the decrease of the balance is allowed
   **/
  // 检查是否允许用户减少资产余额
  // 比如，健康系数不能小于1
  function balanceDecreaseAllowed(
    address asset,
    address user,
    uint256 amount,
    mapping(address => DataTypes.ReserveData) storage reservesData,
    DataTypes.UserConfigurationMap calldata userConfig,
    mapping(uint256 => address) storage reserves,
    uint256 reservesCount,
    address oracle
  ) external view returns (bool) {
    // 用户没有借任何资产或没有使用这个资产作为抵押，返回true
    if (!userConfig.isBorrowingAny() || !userConfig.isUsingAsCollateral(reservesData[asset].id)) {
      return true;
    }

    balanceDecreaseAllowedLocalVars memory vars;

    (, vars.liquidationThreshold, , vars.decimals, ) = reservesData[asset]
      .configuration
      .getParams();

    // 如果资产清算阈值等于0，返回true
    if (vars.liquidationThreshold == 0) {
      return true;
    }

    // 获取用户整体数据
    (
      // 总质押数量
      vars.totalCollateralInETH,
      // 总借款数量
      vars.totalDebtInETH,
      ,
      // 平均清算阈值
      vars.avgLiquidationThreshold,

    ) = calculateUserAccountData(user, reservesData, userConfig, reserves, reservesCount, oracle);

    // 如果借款数量等于0，返回true
    if (vars.totalDebtInETH == 0) {
      return true;
    }

    // 提取数量转为以ETH计算的数量
    vars.amountToDecreaseInETH = IPriceOracleGetter(oracle).getAssetPrice(asset).mul(amount).div(
      10 ** vars.decimals
    );

    vars.collateralBalanceAfterDecrease = vars.totalCollateralInETH.sub(vars.amountToDecreaseInETH);

    //if there is a borrow, there can't be 0 collateral
    // 执行到这里说明有借款，那么抵押资产的数量不能为0
    if (vars.collateralBalanceAfterDecrease == 0) {
      return false;
    }

    // 计算提取后的平均清算阈值
    // (总质押数量 * 平均清算阈值 - 提取数量 * 资产清算阈值) / 提取后的资产数量
    // 总质押数量 * 平均清算阈值 其实是 最大借款数量
    vars.liquidationThresholdAfterDecrease = vars
      .totalCollateralInETH
      .mul(vars.avgLiquidationThreshold)
      .sub(vars.amountToDecreaseInETH.mul(vars.liquidationThreshold))
      .div(vars.collateralBalanceAfterDecrease);

    // 计算用户健康系数
    uint256 healthFactorAfterDecrease = calculateHealthFactorFromBalances(
      vars.collateralBalanceAfterDecrease,
      vars.totalDebtInETH,
      vars.liquidationThresholdAfterDecrease
    );

    // 健康系数必须大于等于1
    return healthFactorAfterDecrease >= GenericLogic.HEALTH_FACTOR_LIQUIDATION_THRESHOLD;
  }

  struct CalculateUserAccountDataVars {
    uint256 reserveUnitPrice;
    uint256 tokenUnit;
    uint256 compoundedLiquidityBalance;
    uint256 compoundedBorrowBalance;
    uint256 decimals;
    uint256 ltv;
    uint256 liquidationThreshold;
    uint256 i;
    uint256 healthFactor;
    uint256 totalCollateralInETH;
    uint256 totalDebtInETH;
    uint256 avgLtv;
    uint256 avgLiquidationThreshold;
    uint256 reservesLength;
    bool healthFactorBelowThreshold;
    address currentReserveAddress;
    bool usageAsCollateralEnabled;
    bool userUsesReserveAsCollateral;
  }

  /**
   * @dev Calculates the user data across the reserves.
   * this includes the total liquidity/collateral/borrow balances in ETH,
   * the average Loan To Value, the average Liquidation Ratio, and the Health factor.
   * @param user The address of the user
   * @param reservesData Data of all the reserves
   * @param userConfig The configuration of the user
   * @param reserves The list of the available reserves
   * @param oracle The price oracle address
   * @return The total collateral and total debt of the user in ETH, the avg ltv, liquidation threshold and the HF
   **/
  // 计算用户跨资产的数据，包括：
  // 以ETH计价的流动性/质押/借款数量，
  // 平均LTV，平均清算阈值，健康系数
  // 算法很简单：遍历所有资产，算术平均计算这些值
  function calculateUserAccountData(
    address user,
    mapping(address => DataTypes.ReserveData) storage reservesData,
    DataTypes.UserConfigurationMap memory userConfig,
    mapping(uint256 => address) storage reserves,
    uint256 reservesCount,
    address oracle
  ) internal view returns (uint256, uint256, uint256, uint256, uint256) {
    CalculateUserAccountDataVars memory vars;

    // 空数据返回空参数
    if (userConfig.isEmpty()) {
      return (0, 0, 0, 0, uint256(-1));
    }
    // 遍历当前所有资产，累计用户在每个资产的质押数量、借款数量、借出数量、清算数量
    for (vars.i = 0; vars.i < reservesCount; vars.i++) {
      // 如果既没有用作质押，也没有借款，则跳过这个资产
      if (!userConfig.isUsingAsCollateralOrBorrowing(vars.i)) {
        continue;
      }

      // 资产地址
      vars.currentReserveAddress = reserves[vars.i];
      // 资产属性
      DataTypes.ReserveData storage currentReserve = reservesData[vars.currentReserveAddress];

      // 获取LTV，清算阈值，decimals
      (vars.ltv, vars.liquidationThreshold, , vars.decimals, ) = currentReserve
        .configuration
        .getParams();

      vars.tokenUnit = 10 ** vars.decimals;
      // 获取当前资产以ETH计算的价格
      vars.reserveUnitPrice = IPriceOracleGetter(oracle).getAssetPrice(vars.currentReserveAddress);

      // 如果资产的清算阈值不等于0 而且 用户把这个资产作为了抵押
      if (vars.liquidationThreshold != 0 && userConfig.isUsingAsCollateral(vars.i)) {
        // 获取用户当前的实际质押数量
        vars.compoundedLiquidityBalance = IERC20(currentReserve.aTokenAddress).balanceOf(user);

        // 将实际质押数量换算为ETH表示的数量
        // 资产流动性余额 in ETH
        uint256 liquidityBalanceETH = vars
          .reserveUnitPrice
          .mul(vars.compoundedLiquidityBalance)
          .div(vars.tokenUnit);

        // 累计 总质押数量 in ETH
        vars.totalCollateralInETH = vars.totalCollateralInETH.add(liquidityBalanceETH);

        // 累计 质押借出数量 in ETH
        // liquidityBalanceETH.mul(vars.ltv) 为用户当前资产的借出数量
        // 这不应该叫avgLtv ，其实是总借款数量，下面会用这个值除以总质押数量，得到真正的平均LTV
        vars.avgLtv = vars.avgLtv.add(liquidityBalanceETH.mul(vars.ltv));
        // 累计 总清算数量 in ETH，即每个资产可以借出的最大资产数量之和
        // 同上，不应该叫avgLiquidationThreshold
        vars.avgLiquidationThreshold = vars.avgLiquidationThreshold.add(
          liquidityBalanceETH.mul(vars.liquidationThreshold)
        );
      }

      // 如果用户之前借入了此资产
      if (userConfig.isBorrowing(vars.i)) {
        // 固定利率借款的实际数量
        vars.compoundedBorrowBalance = IERC20(currentReserve.stableDebtTokenAddress).balanceOf(
          user
        );
        // 叠加动态利率借款的实际数量
        vars.compoundedBorrowBalance = vars.compoundedBorrowBalance.add(
          IERC20(currentReserve.variableDebtTokenAddress).balanceOf(user)
        );

        // 累计 总借款数量 in ETH
        vars.totalDebtInETH = vars.totalDebtInETH.add(
          vars.reserveUnitPrice.mul(vars.compoundedBorrowBalance).div(vars.tokenUnit)
        );
      }
    }

    // 计算平均LTV 总借出数量 / 总质押数量
    vars.avgLtv = vars.totalCollateralInETH > 0 ? vars.avgLtv.div(vars.totalCollateralInETH) : 0;
    // 计算平均清算阈值 总清算数量 / 总质押数量
    vars.avgLiquidationThreshold = vars.totalCollateralInETH > 0
      ? vars.avgLiquidationThreshold.div(vars.totalCollateralInETH)
      : 0;

    // 计算健康系数
    vars.healthFactor = calculateHealthFactorFromBalances(
      vars.totalCollateralInETH,
      vars.totalDebtInETH,
      vars.avgLiquidationThreshold
    );
    return (
      vars.totalCollateralInETH,
      vars.totalDebtInETH,
      vars.avgLtv,
      vars.avgLiquidationThreshold,
      vars.healthFactor
    );
  }

  /**
   * @dev Calculates the health factor from the corresponding balances
   * @param totalCollateralInETH The total collateral in ETH
   * @param totalDebtInETH The total debt in ETH
   * @param liquidationThreshold The avg liquidation threshold
   * @return The health factor calculated from the balances provided
   **/
  // 计算健康系数
  function calculateHealthFactorFromBalances(
    uint256 totalCollateralInETH,
    uint256 totalDebtInETH,
    uint256 liquidationThreshold
  ) internal pure returns (uint256) {
    if (totalDebtInETH == 0) return uint256(-1);

    // 总质押 * 清算阈值 / 总借款
    return (totalCollateralInETH.percentMul(liquidationThreshold)).wadDiv(totalDebtInETH);
  }

  /**
   * @dev Calculates the equivalent amount in ETH that an user can borrow, depending on the available collateral and the
   * average Loan To Value
   * @param totalCollateralInETH The total collateral in ETH
   * @param totalDebtInETH The total borrow balance
   * @param ltv The average loan to value
   * @return the amount available to borrow in ETH for the user
   **/

  function calculateAvailableBorrowsETH(
    uint256 totalCollateralInETH,
    uint256 totalDebtInETH,
    uint256 ltv
  ) internal pure returns (uint256) {
    uint256 availableBorrowsETH = totalCollateralInETH.percentMul(ltv);

    if (availableBorrowsETH < totalDebtInETH) {
      return 0;
    }

    availableBorrowsETH = availableBorrowsETH.sub(totalDebtInETH);
    return availableBorrowsETH;
  }
}
