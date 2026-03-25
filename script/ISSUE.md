# Strategy v3 Information

## 2. Strategy Information

### Description of the strategy

#### Briefly explain the external protocols that the strategy interacts with

1. Liquity V2 - deposit collateral and mint BOLD
2. Curve DEX - asset <--> BOLD swaps
3. Yearn - deposit the minted BOLD into yBOLD

#### Briefly explain what the strategy does to get yield

The strategy executes a carry trade strategy, borrowing at a low IR and lending an a high IR:

1. Mint BOLD at low IR
2. Deposit BOLD into yBOLD at high IR

#### Expected & Final Category (1-5)

- Expected Category: [1-5]
- Final Category: [1-5]

### Important Checks

These simple questions are important to understand how the strategy works, and having an overview perspective about the strategy and the underlying protocol(s). Please, answer these questions as detailed as possible. In case some questions don't apply for your strategy, feel free to add *n/a*.

#### Which version/s are used in inherited contracts ? (E.g:  Core: BaseStrategy/TokenizedStrategy v3.0.2, Periphery: UniswapV3Swapper, AuctionSwapper v1.x.x)

1. v3.0.4
2. BaseHealthCheck

#### Does the strategy has potential deposit fees?

Yes. Liquity charges 7 days worth of interest when you mint BOLD. Plan is to mitigate this by allowing deposits only through an allocator vault which will reduce the risk of someone cycling in and out

#### On which chains is the strategy currently deployable or planned to be deployed?

Mainnet

#### Does the strategy has potential withdrawal fees?

No

#### Does the strategy has potential frontrunning threats on deposits/withdrawals? If yes, how so? 

Yes. Through `_borrow()`, because of fee slippage (`maxFee` is hardcoded to `type(uint256).max`)

#### At any given time, is there a possibility that withdrawing the deposited "asset" might not be possible? If yes, is `availableWithdrawLimit` overridden?

Yes, via the `BaseLenderBorrower` contract

#### At any given time, is there a possibility that depositing any arbitrary amount is not possible? If yes, is `availableDepositLimit` overridden?

Yes, via the `BaseLenderBorrower` contract

#### How many protocols does the strategy directly interact with? If at least one, list them

3 protocols:

1. Liquity V2 - deposit collateral and mint BOLD
2. Curve DEX - asset <--> BOLD swaps
3. Yearn - deposit the minted BOLD into yBOLD

#### How many protocols does the strategy indirectly interact with? If at least one, list them

None

#### Do the risks of external contracts pausing or executing an emergency withdrawal affects the strategy? If yes, how? 

Yes, the yBOLD vault

#### Is there any expected loss in the strategy's normal cycle? If yes, how?

No

#### Does the strategy require a privileged role to set some important settings? If there are any, explain

Yes, there are several permissioned functions that could be called by different roles

#### What are the worst-case scenarios that this strategy can experience? How likely are these scenarios, and what would be the strategy's reaction in such cases?

1. Liquidation - (Low likelihood)
- Should never happen, keepers should fix the position before it can happen
- If happens, there will be losses, but everyone should be able to withdraw whatever's left
2. Unprofitable rates - (Medium likelihood)
- The strategy just sits on the collateral token without doing anything

#### How many assets that the strategy handles? 

3 assets:

1. The collateral (e.g. WETH)
2. The borrowed token (e.g. BOLD)
3. The lender vault share token (e.g. yBOLD)

#### Does the strategy borrow against the deposits? If yes, does it borrow the same asset or some other asset? What kind of money market it uses for lend/borrows? How is the collateral ratio determined and maintained? Who is responsible for changing the parameters? How is the on-chain monitoring and maintenance of the debt position managed?

Yes, the strategy borrow against the deposits. It does not borrow the same asset. The collateral ratio can be set by management, who is responsible to change it as it sees fit. The monitoring and maintenance is managed by keepers, as indicated by the `tendTrigger`, as well as whitelisted `adjustZombieTrove()` callers

#### Does the strategy rely on keepers? If yes, how much does it rely? If the keepers are very important, how does the `tendTrigger` work? What would happen if the keeper is not responding correctly? Can the keeper harm the system intentionally or unintentionally?

Yes, keepers are critical. If the keepers are not responding, the strategy will likely experience losses. The keepers can't harm the system

#### Is `emergencyWithdraw` implemented? If not, why?

Yes

#### Does the governance of the yield source protocol contracts have excessive powers that could impact our strategy? If yes, how and what would be the strategy's reaction to it? 

No

## 3. Strategy Review

**Commit (hash)**: https://github.com/johnnyonline/yv3-liquityv2-lender-borrower-strategy/commit/10b7b6a452a79f562a2c7267f12a032b8404fc34

**Repo**: https://github.com/johnnyonline/yv3-liquityv2-lender-borrower-strategy

**Branch**: `master`

**Experts**: List the strategists that understand the strategy code:

- {Strategist 1}
- {Strategist 2}

**Testing**:

- Coverage

![Image](https://github.com/user-attachments/assets/fcfc3f9e-ba56-4c06-a103-c3873c8f061e)

- Link to GitHub Actions Coverage: 

https://github.com/johnnyonline/yv3-liquityv2-lender-borrower-strategy/actions/runs/15936601897

- Does it include fuzzing and invariant tests?

Yes

**Scope**:

- [Strategy.sol](https://github.com/johnnyonline/yv3-liquityv2-lender-borrower-strategy/blob/master/src/Strategy.sol)
- [Exchange.sol](https://github.com/johnnyonline/yv3-liquityv2-lender-borrower-strategy/blob/master/src/periphery/Exchange.sol)

**Review Ongoing By**:

- [x] Dev 1
- [ ] Dev 2
- [x] @tapired 

**Review Completed By**:

- [x] Dev 1
- [ ] Dev 2
- [x] @tapired 

## 4- Important Notes

Section to add important notes about issues identified by strategists and security reviewers.

- Not using a factory contract because the strategy is too big
- The `availableWithdrawLimit()` does not take into account a situation where TCR is below CCR. If that ever happens, the user's withdraw request will go through but he will likely have a 100% loss

## 5. Risk Scores

(To be filled by the security team before closing the ticket)

```json
{
  name: string;
  network: number;
  targets: string[];
  tags: string[];
  review: number;
  testing: number;
  complexity: number;
  riskExposure: number;
  protocolIntegration: number;
  centralizationRisk: number;
  externalProtocolAudit: number;
  externalProtocolCentralisation: number;
  externalProtocolTvl: number;
  externalProtocolLongevity: number;
  externalProtocolType: number;
  comment: string
}
```

## 6. Deployed and Verified Addresses

**This will be handled by SAM after verification. If this field is already filled, it means the contracts have been verified by SAM.**

List all the smart contract addresses, including factories, templates, etc.

| # | Name | Network | Link |
| ------ | ------ | ------ | ------ |
| 1 | DAIVault | [eth,base,arb,pol] | [0x123...123](https://etherscan.io/0x123...123)
| 2 | USDVault | [eth,base,arb,pol] | [0x456...456](https://etherscan.io/0x456...456)
| N | Name N | [eth,base,arb,pol] | [0x789...789](https://etherscan.io/0x789...789)
