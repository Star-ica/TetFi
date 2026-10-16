# LottoChain — BOT Chain Lottery Platform

Three lottery modes, one contract, full frontend.

## Contract Modes

| Mode | Mechanic | Entry |
|------|----------|-------|
| **Ticket** | Buy numbered tickets, random ticket wins | `buyTickets(count)` |
| **Pool** | Contribute any amount, random participant wins | `contribute()` |
| **Raffle** | Limited ticket cap, guaranteed draw | `buyTickets(count)` |

## Contract Flow

```
startRound() → entries (buyTickets / contribute) → closeRound() → drawWinner()
```

Each round is self-contained. History accumulates across all rounds.

## Deploy

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Install deps
forge install foundry-rs/forge-std

# Set env
export PRIVATE_KEY=0x...
export ETHERSCAN_API_KEY=...   # optional, for verification

# Deploy to BOT Chain (968)
forge script contracts/Deploy.s.sol:DeployLottery \
  --rpc-url bot_chain \
  --broadcast \
  --verify \
  -vvvv
```

## Frontend Setup

1. Copy the deployed contract address from the deploy output
2. Open `frontend/index.html`
3. Replace `CONTRACT_ADDRESS` near the top of the `<script>` block:
   ```js
   const CONTRACT_ADDRESS = "0xYourDeployedAddress";
   ```
4. Open `index.html` in a browser — no build step needed.

## Admin Workflow (owner only)

1. Connect wallet as contract owner
2. Go to **Admin** tab
3. Pick mode, set ticket price, max tickets, duration → **Start Round**
4. Players buy tickets / contribute
5. **Close Round** to stop entries
6. **Draw Winner** to settle jackpot (prize auto-sent to winner)
7. **Withdraw Fees** to collect platform fees

## Fee Structure

- Default: 5% platform fee on each jackpot
- Set at deploy time via constructor `feePercent` param
- Max allowed: 20%
- Fees accumulate in contract until owner withdraws

## Security Notes

> **Randomness**: The contract uses `block.prevrandao` + `block.timestamp` for pseudo-randomness.
> This is acceptable for low-stakes lotteries but **not production-safe**.
> Integrate [Chainlink VRF](https://docs.chain.link/vrf) or an equivalent oracle before going live with significant value.

- Reentrancy: winner payout uses `.call{value}()` — add `ReentrancyGuard` (OpenZeppelin) for extra safety
- Ownership: consider a 2-step ownership transfer (OpenZeppelin `Ownable2Step`)
- Time: `block.timestamp` can be manipulated ±15s by validators

## RPC & Explorer

Update `foundry.toml` if BOT Chain endpoints differ:
```
RPC:      https://rpc.botchain.network
Explorer: https://explorer.botchain.network
Chain ID: 968
```
# TetFi
