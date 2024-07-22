import { parse } from "toml";
import { StacksTestnet } from "@stacks/network";
import {
  getPublicKeyFromPrivate,
  publicKeyToBtcAddress,
} from "@stacks/encryption";
import { StackingClient, PoxInfo, Pox4SignatureTopic } from "@stacks/stacking";
import { randomInt } from "crypto";
import fs from "fs";
import {
  createStacksPrivateKey,
  getAddressFromPrivateKey,
  TransactionVersion,
} from "@stacks/transactions";

const randInt = () => randomInt(0, 0xffffffffffff);

interface Stacker {
  secret_key: string;
  stx_address: string;
  btc_address: string;
}

const POX_PREPARE_LENGTH = 5;
const POX_REWARD_LENGTH = 20;
const STACKING_CYCLES = 10;
const MAX_U128 = 2n ** 128n - 1n;

let startTxFee = 1000;
const getNextTxFee = () => startTxFee++;

const configPath = process.argv[2];
if (!configPath) {
  console.error(
    "Please provide the path to the configuration file as an argument."
  );
  process.exit(1);
}

let conf;
try {
  const tomlContent = fs.readFileSync(configPath, "utf-8");
  conf = parse(tomlContent);
} catch (error: any) {
  console.error("Failed to parse stacking.toml:", error.message);
  process.exit(1);
}
const network = new StacksTestnet({
  url: `${conf.node.url}:${conf.node.port}`,
});

const accounts = conf.stackers.map((stacker: Stacker, index: number) => {
  const pubKey = getPublicKeyFromPrivate(stacker.secret_key);
  const stxAddress = getAddressFromPrivateKey(
    stacker.secret_key,
    TransactionVersion.Testnet
  );
  const signerPrivKey = createStacksPrivateKey(stacker.secret_key);
  const signerPubKey = getPublicKeyFromPrivate(signerPrivKey.data);
  return {
    privKey: stacker.secret_key,
    pubKey,
    stxAddress,
    btcAddr: publicKeyToBtcAddress(pubKey),
    signerPrivKey: signerPrivKey,
    signerPubKey: signerPubKey,
    targetSlots: index + 1,
    index,
    client: new StackingClient(stxAddress, network),
  };
});

type Account = (typeof accounts)[0];

function burnBlockToRewardCycle(burnBlock: number) {
  const cycleLength = BigInt(POX_REWARD_LENGTH);
  return Number(BigInt(burnBlock) / cycleLength) + 1;
}

async function run() {
  const poxInfo = await accounts[0].client.getPoxInfo();
  if (!poxInfo.contract_id.endsWith(".pox-4")) {
    console.log(
      `Pox contract is not .pox-4, skipping stacking (contract=${poxInfo.contract_id})`
    );
    return;
  }

  const accountInfos = await Promise.all(
    accounts.map(async (a: Account) => {
      const info = await a.client.getAccountStatus();
      const unlockHeight = Number(info.unlock_height);
      const lockedAmount = BigInt(info.locked);
      const balance = BigInt(info.balance);
      return { ...a, info, unlockHeight, lockedAmount, balance };
    })
  );

  let txSubmitted = false;

  await Promise.all(
    accountInfos.map(async (account) => {
      if (account.lockedAmount === 0n) {
        console.log(
          {
            burnHeight: poxInfo.current_burnchain_block_height,
            unlockHeight: account.unlockHeight,
            account: account.index,
          },
          `Account ${account.index} is unlocked, stack-stx required`
        );
        await stackStx(poxInfo, account, account.balance);
        txSubmitted = true;
        return;
      }
      const unlockHeightCycle = burnBlockToRewardCycle(account.unlockHeight);
      const nowCycle = burnBlockToRewardCycle(
        poxInfo.current_burnchain_block_height ?? 0
      );
      if (unlockHeightCycle === nowCycle + 1) {
        console.log(
          {
            burnHeight: poxInfo.current_burnchain_block_height,
            unlockHeight: account.unlockHeight,
            account: account.index,
            nowCycle,
            unlockCycle: unlockHeightCycle,
          },
          `Account ${account.index} unlocks before next cycle ${account.unlockHeight} vs ${poxInfo.current_burnchain_block_height}, stack-extend required`
        );
        await stackExtend(poxInfo, account);
        txSubmitted = true;
        return;
      }
      console.log(
        {
          burnHeight: poxInfo.current_burnchain_block_height,
          unlockHeight: account.unlockHeight,
          account: account.index,
          nowCycle,
          unlockCycle: unlockHeightCycle,
        },
        `Account ${account.index} is locked for next cycle, skipping stacking`
      );
    })
  );
}

async function stackStx(poxInfo: PoxInfo, account: Account, balance: bigint) {
  // Bump min threshold by 50% to avoid getting stuck if threshold increases
  const minStx = Math.floor(poxInfo.next_cycle.min_threshold_ustx * 1.5);
  const amountToStx = BigInt(minStx) * BigInt(account.targetSlots);
  if (amountToStx > balance) {
    throw new Error(
      `Insufficient balance to stack-stx (amount=${amountToStx}, balance=${balance})`
    );
  }
  const authId = randInt();
  const sigArgs = {
    topic: Pox4SignatureTopic.StackStx,
    rewardCycle: poxInfo.reward_cycle_id,
    poxAddress: account.btcAddr,
    period: STACKING_CYCLES,
    signerPrivateKey: account.signerPrivKey,
    authId,
    maxAmount: MAX_U128,
  } as const;
  const signerSignature = account.client.signPoxSignature(sigArgs);
  const stackingArgs = {
    poxAddress: account.btcAddr,
    privateKey: account.privKey,
    amountMicroStx: amountToStx,
    burnBlockHeight: poxInfo.current_burnchain_block_height,
    cycles: STACKING_CYCLES,
    fee: getNextTxFee(),
    signerKey: account.signerPubKey,
    signerSignature,
    authId,
    maxAmount: MAX_U128,
  };
  console.log(
    {
      ...stackingArgs,
      ...sigArgs,
    },
    `Stack-stx with args:`
  );
  const stackResult = await account.client.stack(stackingArgs);
  console.log(
    {
      ...stackResult,
    },
    `Stack-stx tx result`
  );
}

async function stackExtend(poxInfo: PoxInfo, account: Account) {
  const authId = randInt();
  const sigArgs = {
    topic: Pox4SignatureTopic.StackExtend,
    rewardCycle: poxInfo.reward_cycle_id,
    poxAddress: account.btcAddr,
    period: STACKING_CYCLES,
    signerPrivateKey: account.signerPrivKey,
    authId,
    maxAmount: MAX_U128,
  } as const;
  const signerSignature = account.client.signPoxSignature(sigArgs);
  const stackingArgs = {
    poxAddress: account.btcAddr,
    privateKey: account.privKey,
    extendCycles: STACKING_CYCLES,
    fee: getNextTxFee(),
    signerKey: account.signerPubKey,
    signerSignature,
    authId,
    maxAmount: MAX_U128,
  };
  console.log(
    {
      stxAddress: account.stxAddress,
      account: account.index,
      ...stackingArgs,
      ...sigArgs,
    },
    `Stack-extend with args:`
  );
  const stackResult = await account.client.stackExtend(stackingArgs);
  console.log(
    {
      stxAddress: account.stxAddress,
      account: account.index,
      ...stackResult,
    },
    `Stack-extend tx result`
  );
}

run();
