#!/bin/bash

# ------------------------------
# CLEANUP
# ------------------------------

echo "Cleaning up previous runs..."
WORKING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$WORKING_DIR/conf"
DATA_DIR="$WORKING_DIR/data"
LOG_DIR="$WORKING_DIR/logs"

rm -rf $DATA_DIR/miner/* $DATA_DIR/bitcoin/* $LOG_DIR/*
mkdir -p $DATA_DIR/miner $DATA_DIR/bitcoin $LOG_DIR

# ------------------------------
# KEYCHAIN
# ------------------------------

# Generate a new keychain
echo "Generating a new keychain..."

KEYCHAIN_JSON=$(npx @stacks/cli make_keychain -t 2> /dev/null)
PRIVATE_KEY=$(echo $KEYCHAIN_JSON | jq -r '.keyInfo.privateKey')
BTC_ADDRESS=$(echo $KEYCHAIN_JSON | jq -r '.keyInfo.btcAddress')
WIF=$(echo $KEYCHAIN_JSON | jq -r '.keyInfo.wif')

echo "Bitcoin address: $BTC_ADDRESS"

# ------------------------------
# BITCOIND
# ------------------------------

# Start bitcoind
echo "Starting bitcoind..."

bitcoind -conf=$WORKING_DIR/bitcoin.conf -datadir=$DATA_DIR/bitcoin &> $LOG_DIR/bitcoind.log &
BITCOIND_PID=$!

echo "Waiting for bitcoind to be ready..."
while true; do
  bitcoin-cli -regtest -rpcuser=devnet -rpcpassword=devnet -rpcconnect=127.0.0.1 -rpcport=18443 getblockchaininfo &> /dev/null
  if [ $? -eq 0 ]; then
    echo "bitcoind is ready."
    break
  else
    echo "bitcoind is not ready yet, retrying in 1 second..."
    sleep 1
  fi
done

# Create a new wallet
echo "Create a new wallet..."
bitcoin-cli -regtest -rpcuser=devnet -rpcpassword=devnet -rpcconnect=127.0.0.1 -rpcport=18443 createwallet "miner" false false "" false false true 2>&1 >> $LOG_DIR/bitcoind.log
if [ $? -ne 0 ]; then
  echo "createwallet failed."
fi

# Import the private key
bitcoin-cli -regtest -rpcuser=devnet -rpcpassword=devnet -rpcconnect=127.0.0.1 -rpcport=18443 importprivkey $WIF 2>&1 >> $LOG_DIR/bitcoind.log
if [ $? -ne 0 ]; then
  echo "importprivkey failed."
fi

# Get insert the private key into the stacks miner's config
sed -i "" -e "s|^seed = \".*\"|seed = \"$PRIVATE_KEY\"|g" $CONF_DIR/miner.toml

# Generate 101 blocks to fund the miner
bitcoin-cli -regtest -rpcuser=devnet -rpcpassword=devnet -rpcconnect=127.0.0.1 -rpcport=18443 generatetoaddress 101 $BTC_ADDRESS 2>&1 >> $LOG_DIR/bitcoind.log

echo "Miner funded."

# ------------------------------
# SIGNERS
# ------------------------------

# Start the signers
echo "Starting signers..."

STACKS_LOG_DEBUG=1 $STACKS_CORE_BIN/stacks-signer run --config $CONF_DIR/signer1.toml &> $LOG_DIR/signer1.log &
SIGNER1_PID=$!
STACKS_LOG_DEBUG=1 $STACKS_CORE_BIN/stacks-signer run --config $CONF_DIR/signer2.toml &> $LOG_DIR/signer2.log &
SIGNER2_PID=$!
STACKS_LOG_DEBUG=1 $STACKS_CORE_BIN/stacks-signer run --config $CONF_DIR/signer3.toml &> $LOG_DIR/signer3.log &
SIGNER3_PID=$!

# ------------------------------
# STACKS MINER
# ------------------------------

# Start the stacks miner
echo "Starting stacks miner..."

$STACKS_CORE_BIN/stacks-node start --config $CONF_DIR/miner.toml &> $LOG_DIR/miner.log &
MINER_PID=$!

echo "Stacks miner started and listening at http://localhost:20443"

# ------------------------------
# INTERACTIVE MODE
# ------------------------------

print_help() {
  echo "Commands:"
  echo "  q - Quit and terminate all processes"
  echo "  i - Display current burn and stacks block heights"
  echo "  n - Mine a single new block"
  echo "  m - Mine multiple blocks with a pause between each"
  echo "  p - Display current PoX info"
  echo "  h - Display this help message"
}

print_block_info() {
  BURN_BLOCK_HEIGHT=$(bitcoin-cli -regtest -rpcuser=devnet -rpcpassword=devnet -rpcconnect=127.0.0.1 -rpcport=18443 getblockcount)
  echo " ℹ️ Current burn block height: $BURN_BLOCK_HEIGHT"
  STACKS_BLOCK_HEIGHT=$(curl -s http://localhost:20443/v2/info | jq -r .stacks_tip_height)
  echo " ℹ️ Current stacks block height: $STACKS_BLOCK_HEIGHT"
}

mine_and_check_cycle() {
  # Mine a new block
  bitcoin-cli -regtest -rpcuser=devnet -rpcpassword=devnet -rpcconnect=127.0.0.1 -rpcport=18443 generatetoaddress 1 $BTC_ADDRESS > /dev/null

  # Get the current block height
  BURN_BLOCK_HEIGHT=$(bitcoin-cli -regtest -rpcuser=devnet -rpcpassword=devnet -rpcconnect=127.0.0.1 -rpcport=18443 getblockcount)

  # Check if it is the 10th block in a reward cycle
  if (( BURN_BLOCK_HEIGHT % 20 == 10 )); then
    # Submit stacking transactions
    echo " ℹ️ Submitting stacking transactions..."
    npx tsx stacking/stacking.ts $CONF_DIR/stacking.toml 2>&1 >> $LOG_DIR/stacking.log
  fi
}

print_help
while true; do
  echo -n "❯ "  # Prompt symbol indicating it's waiting for input
  read -r -n 1 key
  echo  # Move to a new line after reading the key
  if [[ $key == "q" ]]; then
    echo " Exiting..."
    kill $MINER_PID
    kill $SIGNER1_PID
    kill $SIGNER2_PID
    kill $SIGNER3_PID
    kill $BITCOIND_PID
    break
  elif [[ $key == "i" ]]; then
    print_block_info
  elif [[ $key == "n" ]]; then
    echo "  → Mining a new block..."
    mine_and_check_cycle
    print_block_info
  elif [[ $key == "m" ]]; then
    echo -n " ❯❯ Enter the number of blocks to mine: "
    read -r number_of_blocks
    if [[ $number_of_blocks =~ ^[0-9]+$ ]]; then
      echo -n " ❯❯ Enter the number of seconds to pause between blocks: "
      read -r sleep_time
      if [[ $sleep_time =~ ^[0-9]+$ ]]; then
        for ((i=1; i<$number_of_blocks; i++)); do
          echo " ├ Mining block $((i)) of $number_of_blocks..."
          mine_and_check_cycle
          sleep $sleep_time
        done
        echo " └ Mining block $((i)) of $number_of_blocks..."
        mine_and_check_cycle
        print_block_info
      else
        echo " ✗ Invalid sleep time. Please enter a valid number of seconds."
      fi
    else
      echo " ✗ Invalid number of blocks. Please enter a valid number."
    fi
  elif [[ $key == "p" ]]; then
    pox_info=$(curl -s http://localhost:20443/v2/pox)
    pox_contract=$(echo $pox_info | jq -r .contract_id)
    current_cycle=$(echo $pox_info | jq -r .current_cycle.id)
    current_min=$(echo $pox_info | jq -r .current_cycle.min_threshold_ustx)
    current_stacked=$(echo $pox_info | jq -r .current_cycle.stacked_ustx)
    next_cycle=$(echo $pox_info | jq -r .next_cycle.id)
    next_min=$(echo $pox_info | jq -r .next_cycle.min_threshold_ustx)
    next_stacked=$(echo $pox_info | jq -r .next_cycle.stacked_ustx)
    echo " ℹ️ PoX contract: $pox_contract"
    echo " ℹ️ Current cycle: $current_cycle"
    echo "   ├ Min threshold: $current_min"
    echo "   └ Stacked: $current_stacked"
    echo " ℹ️ Next cycle: $next_cycle"
    echo "   ├ Min threshold: $next_min"
    echo "   └ Stacked: $next_stacked"
  elif [[ $key == "h" ]]; then
    print_help
  fi
done