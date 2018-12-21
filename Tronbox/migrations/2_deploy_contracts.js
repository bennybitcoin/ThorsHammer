var MyContract = artifacts.require("./TronWheel.sol");
module.exports = function(deployer) {
    deployer.deploy(MyContract);
};
