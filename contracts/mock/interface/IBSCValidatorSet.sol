pragma solidity 0.7.6;

interface IBSCValidatorSet {
  function misdemeanor(address validator) external;
  function felony(address validator)external;
  function isCurrentValidator(address validator) external view returns (bool);
}
