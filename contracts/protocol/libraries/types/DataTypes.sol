// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;

library DataTypes {
  // refer to the whitepaper, section 1.1 basic concepts for a formal description of these properties.
  struct ReserveData {
    //stores the reserve configuration
    // 资产设置
    ReserveConfigurationMap configuration;
    //the liquidity index. Expressed in ray
    // 累计流动性指数，类似汇率，1个aToken可以换取多少token（用ray表示，1 ray等于10的27次方，比如1.5在合约中用ray表示为1.5 × 10^27）
    // 时间段ΔT​范围内，由贷款利率累计产生的单位本金利息，任何操作都会更新该参数
    // 等于 LI_t = LI_t-1 * (1 + LR_t * Δyear)
    // t时刻的流动性指数等于，t-1时刻的流动性指数加上 t-1时刻的流动性指数乘以时间差（以年计算）内的收益增长率（LR_t * Δyear）
    // year = 31536000 (60 * 60 * 24 * 365)
    // Δyear = ΔT(以秒计) / year
    // 本质是复利计算出来的累计指数，复利周期是距离上次计息动作的间隔秒数
    uint128 liquidityIndex;
    //variable borrow index. Expressed in ray
    // 动态借款指数 VI，使用复利公式计算利息，每次存钱、取钱、借钱、赎回、清算操作等动作都会更新
    // 这里的复利周期是每秒计算的
    // VI_t = (1 + VR/year)的ΔT次方 * VI_t-1
    // 因为在链上计算成本高，AAVE使用了泰勒展开式模拟这个公式，为了避免昂贵的求幂，使用二项式近似进行计算。
    // 详见MathUtils.calculateCompoundedInterest
    uint128 variableBorrowIndex;
    //the current supply rate. Expressed in ray
    // 当前流动性率，等于总的借款利率 × 资金利用率 × (1 - 协议费率)
    // 公式推导：
    // 假设资金利用率为 U，表示借出资金占总存款的比例
    // 那么借出资金产生的总利息 = 总存款 × 资金利用率(U) × 总借款利率(R)
    // 存款人获得的利息 = 总存款 × 资金利用率(U) × 总借款利率(R) × (1 - 协议费率)
    // 对于存款人来说,他们关心的是自己的存款能获得多少收益。这个收益率就是流动性率(LR),
    // 它等于存款人获得的利息除以总存款: LR = (总存款 × U × R × (1 - 协议费率)) / 总存款 = U × R × (1 - 协议费率)
    uint128 currentLiquidityRate;
    //the current variable borrow rate. Expressed in ray
    // 当前市场的动态借款利率
    // AAVE设置了资产的最佳使用率（U_optimal）。当使用率少于最佳使用率的时候，利率增长是很平缓的，当使用率超过这个值，利率显著增加。
    // 也就是说，借款利率的计算公式分为两种
    //     ⎧ R_base + (U / U_optimal) * R_slope1, U < U_optimal
    // R = ⎨
    //     ⎩ R_base + R_slope1 + ((U - U_optimal) / (1 - U_optimal)) * R_slope2, U >= U_optimal
    // 其中，R_base为借款基础利率，R_slope1为曲线1的最高年化利率，R_slope2为曲线2的最高年化利率
    // 除了U，其它参数均为管理员在合约中配置
    // 另外：借款利率分为活期利率和固定利率，不同点是借款基础利率不同。
    // 这里是VR，动态借款利率
    uint128 currentVariableBorrowRate;
    //the current stable borrow rate. Expressed in ray
    // 这里是SR，当前市场的固定借款利率
    uint128 currentStableBorrowRate;
    // 上次更新的时间戳
    uint40 lastUpdateTimestamp;
    //tokens addresses
    // aToken地址
    address aTokenAddress;
    // 固定利率债务token地址
    address stableDebtTokenAddress;
    // 动态利率债务token地址
    address variableDebtTokenAddress;
    //address of the interest rate strategy
    // 利率策略合约地址
    address interestRateStrategyAddress;
    //the id of the reserve. Represents the position in the list of the active reserves
    // 资产ID
    uint8 id;
  }

  struct ReserveConfigurationMap {
    // 锁定价值
    //bit 0-15: LTV
    // 清算阈值
    //bit 16-31: Liq. threshold
    // 清算奖励的比例
    //bit 32-47: Liq. bonus
    //bit 48-55: Decimals
    //bit 56: Reserve is active
    //bit 57: reserve is frozen
    //bit 58: borrowing is enabled
    //bit 59: stable rate borrowing enabled
    //bit 60-63: reserved
    // 资产储备系数，借款利息的一部分会打给aave国库
    //bit 64-79: reserve factor
    // bitmap形式存储资产的设置
    uint256 data;
  }

  struct UserConfigurationMap {
    // 也是bitmap形式存储
    uint256 data;
  }

  enum InterestRateMode {
    NONE,
    STABLE,
    VARIABLE
  }
}
