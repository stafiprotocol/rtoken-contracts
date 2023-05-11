pragma solidity 0.7.6;
// SPDX-License-Identifier: GPL-3.0-only

enum EraState {
    Uninitialized,
    NewEraExecuted,
    OperateExecuted,
    OperateAckExecuted
}

struct PoolInfo {
    EraState eraState;
    uint256 bond;
    uint256 unbond;
    uint256 active;
}

struct Snapshot {
    uint256 era;
    uint256 bond;
    uint256 unbond;
    uint256 active;
}

struct UnstakeInfo {
    uint256 era;
    address receiver;
    uint256 amount;
}
