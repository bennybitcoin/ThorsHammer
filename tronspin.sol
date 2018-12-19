/*
                                       _____
                                       (-,-)()Thor)
                                       \(o)/ _-|3
                                  /='"'=== // ||
                                 /OOO//| J |  ||
                                 O:O:O LLLLL
                                 \OOO/ || ||
                                      C_) (_D

*/

//Roulette Smart Contract built in Solidity

pragma solidity ^0.4.23;

contract TRC20Interface {
    function totalSupply() public constant returns (uint);
    function balanceOf(address tokenOwner) public constant returns (uint balance);
    function allowance(address tokenOwner, address spender) public constant returns (uint remaining);
    function transfer(address to, uint tokens) public returns (bool success);
    function approve(address spender, uint tokens) public returns (bool success);
    function transferFrom(address from, address to, uint tokens) public returns (bool success);

    event Transfer(address indexed from, address indexed to, uint tokens);
    event Approval(address indexed tokenOwner, address indexed spender, uint tokens);

}


contract Roulette {

    /************************************/
    //      Variable Declarations       //
    /************************************/
    address developer;
    uint256 payroll;
    uint256 maxGamble; //max gamble value manually set by config
    uint256 minGamble; //min gamble value manually set by config
    uint8 blockDelay; //nb of blocks to wait before spin
    uint8 blockExpiration; //nb of blocks before bet expiration (due to hash storage limits)
    uint maxBetsPerBlock; //limits the number of bets per blocks to prevent miner cheating
    uint nbBetsCurrentBlock; //counts the nb of bets in the block
    uint casinoStatisticalLimit; //ratio payroll and max win
    uint256 currentMaxGamble;

    uint8 public wheelResult;
    //the enum BetType contains the different types of possible bets
    enum BetType{number, color, dozen, parity, column}
    struct Gamble
    {
      address player; //Contains the address for the user currently playing the game
      bool spun; //True = roulette spun or False = roulette not yet spun
      bool win;   //True = player won or False = player lost
      BetType betType;   //possible bet types
        uint8 input; //stores number, color, dozen, or oddeven
        uint256 wager;
        uint256 blockNumber; //block of bet
        uint256 blockSpinned; //block of spin
      uint8 wheelResult;  //contains the value from the spun wheel

    }

    Gamble[] private gambles; //create Gamble object named gambles
    uint totalGambles; //tracks total num of gambles played

    //Tracking progress of players
    mapping (address=>uint) gambleIndex; //current gamble index of the player
    //records current status of player
    enum Status {waitingForBet, waitingForSpin} mapping (address=>Status) playerStatus;

    //*******************************************************//
    //        INITIALIZATION AND MANAGEMENT FUNCTIONS        //
    //*******************************************************//

    //initialization settings
    function  TronSpin() private //creation settings
    {
        developer = msg.sender;
        blockDelay=1; //indicates which block after bet will be used for RNG
        blockExpiration=200; //delay after which gamble expires

        /*not sure if it should be "10 TRON" or what, also dont know
        what we want to set as the min or max value*/
        minGamble=10; //min and max bet allowed
        maxGamble=10000;

        maxBetsPerBlock=5; // limit of bets per block, to prevent multiple bets per miners
        casinoStatisticalLimit=100; //we are targeting at least 400
    }

   modifier onlyDeveloper()
    {
         if (msg.sender!=developer) revert();
        _;
    }

    function changeDeveloper_only_Dev(address new_dev) private
    noTronSent
    onlyDeveloper
    {
        developer=new_dev;
    }

    //Prevents accidental sending of tron
    modifier noTronSent()
    {
        if (msg.value>0)
        {
            revert();
        }
        _;
    }

    //Activate, Deactivate Betting
    enum States{active, inactive} States public contract_state;

    function disableBetting_only_Dev() private
    noTronSent
    onlyDeveloper
    {
        contract_state=States.inactive;
    }


    function enableBetting_only_Dev() private
    noTronSent
    onlyDeveloper
    {
        contract_state=States.active;
    }

    modifier onlyActive()
    {
        if (contract_state==States.inactive) revert();
        _;
    }

    //Allows dev to alter some settings
    function changeSettings_only_Dev(uint newCasinoStatLimit, uint newMaxBetsBlock, uint256 newMinGamble, uint256 newMaxGamble,  uint8 newBlockDelay, uint8 newBlockExpiration) private
    noTronSent
    onlyDeveloper
    {
        // changes the statistical multiplier that guarantees the long run casino survival
        if (newCasinoStatLimit<100) revert();
        casinoStatisticalLimit=newCasinoStatLimit;
        //Max number of bets per block to prevent miner cheating
        maxBetsPerBlock=newMaxBetsBlock;
        //MAX BET : limited by payroll/(casinoStatisticalLimit*35)
        if (newMaxGamble<newMinGamble) revert();
        else { maxGamble=newMaxGamble; }
        //Min Bet
        if (newMinGamble<0) revert();
        else { minGamble=newMinGamble; }

    //Delay before spin :
    blockDelay=newBlockDelay;
    if (newBlockExpiration<blockDelay+20) revert();
    blockExpiration=newBlockExpiration;
        updateMaxBet();
    }

    //******************************************************//
    //                  BETTING FUNCTIONS                   //
    //******************************************************//



    /*Admin function that recalculates max bet
    updated after each bet and change of bankroll*/
    function updateMaxBet() private
    {
    //check that setting is still within safety bounds
        if (payroll/(casinoStatisticalLimit*35) > maxGamble)
        {
            currentMaxGamble=maxGamble;
      }
        else
        {
            currentMaxGamble = payroll/(casinoStatisticalLimit*35);
        }
    }

    /*Guarantees that gamble is under max bet and above min
    returns bet value*/
    function checkBetValue() private returns(uint256 playerBetValue)
    {
      if (msg.value < minGamble) revert();
        if (msg.value > currentMaxGamble) //if above max, send difference back
        {
            playerBetValue=currentMaxGamble;
        }
      else
      { playerBetValue=msg.value; }
      return playerBetValue;
    }

    //to prevent miner cheating this function checks number of bets in block
    //check number of bets in block (to prevent miner cheating)
    modifier checkNbBetsCurrentBlock()
    {
        if (gambles.length!=0 && block.number==gambles[gambles.length-1].blockNumber) nbBetsCurrentBlock+=1;
        else nbBetsCurrentBlock=0;
        if (nbBetsCurrentBlock>=maxBetsPerBlock) revert();
        _;
    }

    //Function record bet called by all others betting functions
    function placeBet(BetType betType_, uint8 input_) private
    {
      //*********************************************************

    // Before we record, we may have to spin the past bet if the croupier bot
    // is down for some reason or if the player played again too quickly.
    // This would fail though if the player tries too play to quickly (in consecutive block).
    // gambles should be spaced by at least a block
    // the croupier bot should spin within 2 blocks (~30 secs) after your bet.
    // if the bet expires it is added to casino profit, otherwise it would be a way to cheat

        if (playerStatus[msg.sender] != Status.waitingForBet)
        {

                SpinTheWheel(msg.sender);
        }
        //Once this is done, we can record the new bet
        playerStatus[msg.sender]=Status.waitingForSpin;
        gambleIndex[msg.sender]=gambles.length;
        totalGambles++;
        //adapts wager to casino limits

        uint256 betValue = checkBetValue();

        gambles.push(Gamble(msg.sender, false, false, betType_, input_, betValue, block.number, 0, 38)); //38 indicates not spinned yet
        //refund excess bet (at last step vs re-entry)
      if (betValue<msg.value)
      {
           if (msg.sender.send(msg.value-betValue)==false) revert();
      }
    }

    //user bet on the number numberChosen
    function betOnNumber(uint8 numberChosen) public
    //onlyActive
    //checkNbBetsCurrentBlock
    {
        //check that number chosen is valid and records bet
        if (numberChosen>38) revert();
        placeBet(BetType.number, numberChosen);
    }

    //user bet on a color
    //bet type : color
    //input : 0 for red
    //input : 1 for black
    function betOnColor(bool Red, bool Black) public
     // onlyActive
    //checkNbBetsCurrentBlock
    {

        uint8 count;
        uint8 input;
        if (Red)
        {
            count+=1;
            input=0;
        }
        if (Black)
        {
            count+=1;
            input=1;
        }
        if (count!=1) revert();
        placeBet(BetType.color, input);
    }

    //user bet on odd or even
    //bet type : parity
    //input : 0 for even
    //input : 1 for odd
    function betOnOddEven(bool Odd, bool Even) public
    // onlyActive
    //checkNbBetsCurrentBlock
    {
        uint8 count;
        uint8 input;
        if (Even)
        {
            count+=1;
            input=0;
        }
        if (Odd)
        {
            count+=1;
            input=1;
        }
        if (count!=1) revert();
        placeBet(BetType.parity, input);
    }

      function betOnDozen(bool First, bool Second, bool Third) public
       {
           betOnColumnOrDozen(First,Second,Third, BetType.dozen);
       }
       // //***// function betOnColumn
       //     //bet type : column
       //     //input : 0 for first column
       //     //input : 1 for second column
       //     //input : 2 for third column
       function betOnColumn(bool First, bool Second, bool Third) public
       {
           betOnColumnOrDozen(First, Second, Third, BetType.column);
       }
   
       function betOnColumnOrDozen(bool First, bool Second, bool Third, BetType bet) private
       onlyActive
       checkNbBetsCurrentBlock
       { 
           uint8 count;
           uint8 input;
           if (First) 
           { 
               count+=1; 
               input=0;
           }
           if (Second) 
           {
               count+=1; 
               input=1;
           }
           if (Third) 
           {
               count+=1; 
               input=2;
           }
           if (count!=1) revert();
           placeBet(bet, input);

       }

    //****************************************//
    // Spin The Wheel & Check Result FUNCTIONS//
    //****************************************//

    event Win(address player, uint8 result, uint value_won, bytes32 bHash, bytes32 sha3Player, uint gambleId);
    event Loss(address player, uint8 result, uint value_loss, bytes32 bHash, bytes32 sha3Player, uint gambleId);

    function spinTheWheel(address spin_for_player) private
    noTronSent
    {
        SpinTheWheel(spin_for_player);
    }


     function SpinTheWheel(address playerSpinned) private
    {

        //check that player has to spin
      if (playerStatus[playerSpinned]!=Status.waitingForSpin) revert();
        //redundent double check : check that gamble has not been spun already
      if (gambles[gambleIndex[playerSpinned]].spun==true) revert();
        //check that the player waited for the delay before spin
        //and also that the bet is not expired
        uint playerblock = gambles[gambleIndex[playerSpinned]].blockNumber;
        //too early to spin
        if (block.number<=playerblock+blockDelay) revert();
        //too late, bet expired, player lost
      else if (block.number>playerblock+blockExpiration)  solveBet(playerSpinned, 255, false, 1, 0, 0) ;
        //spin !
      else
        {

          //Spin the wheel
          bytes32 blockHash= blockhash(playerblock+blockDelay);
          //security check that the Hash is not empty
          if (blockHash==0) revert();
            // generate the hash for RNG from the blockHash and the player's address

          bytes32 shaPlayer = keccak256(abi.encodePacked(playerSpinned,blockHash));

            // get the final wheel result
            wheelResult = uint8(uint256(shaPlayer)%38);
            //check result against bet and pay if win
            checkBetResult(wheelResult, playerSpinned, blockHash, shaPlayer);
        }
    }



    

     // function solve Bet once result is determined : sends to winner, adds loss to profit
    function solveBet(address player, uint8 result, bool win, uint8 multiplier, bytes32 blockHash, bytes32 shaPlayer) private
    {
        //Update status and record spinned
        playerStatus[player]=Status.waitingForBet;
        gambles[gambleIndex[player]].wheelResult=result;
        gambles[gambleIndex[player]].spun=true;
        gambles[gambleIndex[player]].blockSpinned=block.number;
        uint bet_v = gambles[gambleIndex[player]].wager;

        if (win)
        {
            gambles[gambleIndex[player]].win=true;
            uint win_v = (multiplier-1)*bet_v;
          emit Win(player, result, win_v, blockHash, shaPlayer, gambleIndex[player]);

        }
        else
        {
            emit Loss(player, result, bet_v-1, blockHash, shaPlayer, gambleIndex[player]);
          //send 1 wei to confirm spin if loss
        }

    }

    //CHECK BETS FUNCTIONS private
    function checkBetResult(uint8 result, address player, bytes32 blockHash, bytes32 shaPlayer) private
    {
        BetType betType=gambles[gambleIndex[player]].betType;
        //bet on Number
        if (betType==BetType.number) checkBetNumber(result, player, blockHash, shaPlayer);
        else if (betType==BetType.parity) checkBetParity(result, player, blockHash, shaPlayer);
        else if (betType==BetType.color) checkBetColor(result, player, blockHash, shaPlayer);
          else if (betType==BetType.dozen) checkBetDozen(result, player, blockHash, shaPlayer);
		  else if (betType==BetType.column) checkBetColumn(result, player, blockHash, shaPlayer);
        updateMaxBet();  //at the end, update the Max possible bet
    }

    
    // checkbeton number(input)
    // bet type : number
    // input : chosen number
    function checkBetNumber(uint8 result, address player, bytes32 blockHash, bytes32 shaPlayer) private
    {
       bool win;
       //win
         if (result==gambles[gambleIndex[player]].input)
         {
         win=true;
       }
          solveBet(player, result, win, 36, blockHash, shaPlayer);
      }

    // checkbet on oddeven
    // bet type : parity
    // input : 0 for even, 1 for odd
    function checkBetParity(uint8 result, address player, bytes32 blockHash, bytes32 shaPlayer) private
    {
      bool win;
      //win
        if (result%2==gambles[gambleIndex[player]].input && result!=0 && result!=37)
      {
        win=true;
      }
      solveBet(player,result,win,2, blockHash, shaPlayer);
    }

    // checkbet on color
    // bet type : color
    // input : 0 red, 1 black
    uint[18] red_list=[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36];
    function checkBetColor(uint8 result, address player, bytes32 blockHash, bytes32 shaPlayer) private
    {
        bool red=false;
        //check if red
        for (uint8 k; k<18; k++)
        {
            if (red_list[k]==result)
            {
                red=true;
                break;
            }
        }
        
        bool win;
        //win
        if (( result!=0 && result!=37 ) && ( (gambles[gambleIndex[player]].input==0 && red) || ( gambles[gambleIndex[player]].input==1 && !red)))
        {
            win=true;
        }
        solveBet(player,result,win,2, blockHash, shaPlayer);
    }

	// checkbet on dozen
    // bet type : dozen
    // input : 0 first, 1 second, 2 third
    function checkBetDozen(uint8 result, address player, bytes32 blockHash, bytes32 shaPlayer) private
    { 
        bool win;
        //win on first dozen
     	if ( result!=37 && result!=0 &&
             ( (result<13 && gambles[gambleIndex[player]].input==0)
     	       ||
               (result>12 && result<25 && gambles[gambleIndex[player]].input==1)
               ||
               (result>24 && gambles[gambleIndex[player]].input==2) ) )
     	{
            win=true;                
        }
        solveBet(player,result,win,3, blockHash, shaPlayer);
    }

    // checkbet on column
    // bet type : column
    // input : 0 first, 1 second, 2 third
    function checkBetColumn(uint8 result, address player, bytes32 blockHash, bytes32 shaPlayer) private
    {
        bool win;
        //win
        if ( result!=0 && result != 37
             && ( (gambles[gambleIndex[player]].input==0 && result%3==1)  
                  || ( gambles[gambleIndex[player]].input==1 && result%3==2)
                  || ( gambles[gambleIndex[player]].input==2 && result%3==0)))
        {
            win=true;
        }
        solveBet(player,result,win,3, blockHash, shaPlayer);
    }
}