pragma solidity 0.7.6;
// SPDX-License-Identifier: GPL-3.0-only

enum EraState {
    Uninitialized,
    NewEraExecuted,
    OperateExecuted,
    OperateAckExecuted
}

enum Action {
    Undefined,
    Silence,
    Delegate,
    Undelegate
}

struct PoolInfo {
    EraState eraState;
    uint256 bond;
    uint256 unbond;
    uint256 active;
}

struct UnstakeInfo {
    uint256 era;
    address pool;
    address receiver;
    uint256 amount;
}

struct Operate {
    Action action;
    address[] valList;
    uint256[] amountList;
}
