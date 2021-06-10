import { expect } from "chai";
import { ethers } from "hardhat";
import { Signer } from "ethers";

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

        // const Multisig = await ethers.getContractFactory("Multisig")
        // const ms = await Multisig.deploy([addr], 1)
        // await ms.deployed()
        //
        // const owners = await ms.getOwners()
        // for (let i in owners) {
        //     console.log(owners[i]);
        // }
        //
        // await expect(await ms.getThreshold()).to.be.eq(1)

        // const msg = "0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8"
        // const signedMsg = "0x82dbd11468a4fe72682e656a03bcb5817f4470b9e41a25ed0e0a50f7fdb22c380070999361924984f66fb5d7772049539207c73d836f4578579638df3513ae6700"
        //
        // //todo add data
        // // const msg = await ms.messageToSign(ms.address, 0)
        // // console.log("msg:", msg)
        // //
        // // const signedMsg = await signer.signMessage(msg)
        // // console.log("signedMsg: ", signedMsg)
        //
        // const r = signedMsg.substr(0, 66)
        // const s = '0x' + signedMsg.substr(66, 64)
        // const v = '0x' + signedMsg.substr(130, 2)
        //
        // const recoveredAddress = await ms.recover(msg, v, r, s)
        // console.log(recoveredAddress)
    });

    // it('erc20', async () => {
    //     const [owner, addr1] = await ethers.getSigners()
    //     const ownerAddress = await owner.getAddress()
    //     console.log("owner: ", ownerAddress)
    //
    //     const address1 = await addr1.getAddress()
    //     console.log("address1: ", address1)
    //
    //     const Multisig = await ethers.getContractFactory("Multisig")
    //     const ms = await Multisig.deploy([ownerAddress], 1)
    //     await ms.deployed()
    //     const msAddress = ms.address
    //     console.log("msAddress: ", msAddress)
    //
    //     const erc20Factory = await ethers.getContractFactory("ERC20Token")
    //     const erc20 = await erc20Factory.deploy()
    //     const name = await erc20.name()
    //     const sym = await erc20.symbol()
    //     console.log("name: ", name)
    //     console.log("sym ", sym)
    //     let ownerBalance = await erc20.balanceOf(owner.address)
    //     console.log("ownerBalance: ", ownerBalance.toString())
    //     expect(await erc20.totalSupply()).to.be.eq(ownerBalance)
    //
    //     await erc20.connect(owner).transfer(msAddress, 10000)
    //     expect(await erc20.balanceOf(msAddress)).to.equal(10000)
    //
    //     let iface = new ethers.utils.Interface(Abi)
    //     const cd = iface.encodeFunctionData("transfer", [address1, 100])
    //     console.log("calldata", cd)
    //
    //     await ms.execTransaction(erc20.address, 0, cd)
    //     const msBalance = await erc20.balanceOf(msAddress)
    //     console.log("msBalance: ", msBalance.toString())
    //
    //     let bal = await erc20.balanceOf(address1)
    //     console.log("bal: ", bal.toString())
    // });


})