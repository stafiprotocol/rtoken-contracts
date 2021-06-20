import { expect } from "chai";
import { ethers } from "hardhat";
import { Signer } from "ethers";
import { AddressZero } from "@ethersproject/constants";

describe("Multisig", async () => {
    let accounts: Signer[];

    const Abi = [
        // Send some of your tokens to someone else
        "function transfer(address recipient, uint256 amount)"
    ];

    beforeEach(async function () {
        accounts = await ethers.getSigners();
    });

    it('should the threshold be right', async () => {
        const signer = accounts[0]
        const addr = await signer.getAddress()
        console.log(addr)

        const Multisig = await ethers.getContractFactory("Multisig")
        const ms = await Multisig.deploy([addr], 1, AddressZero, "0x")
        await ms.deployed()

        console.log(ms.address)
        await expect(await ms.getThreshold()).to.be.eq(1)
    });
})