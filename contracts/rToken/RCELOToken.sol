pragma solidity >=0.7.0 <0.9.0;

import "@openzeppelin/contracts/presets/ERC20PresetMinterPauser.sol";

contract RCELOToken is ERC20PresetMinterPauser {
    constructor() ERC20PresetMinterPauser("StaFi", "rCELO") public {}
}