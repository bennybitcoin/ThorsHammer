var MyContract = artifacts.require("./TronSpin.sol");
module.exports = function(deployer)
{
    deployer.deploy(MyContract);
};
