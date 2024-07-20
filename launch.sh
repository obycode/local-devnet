#!/bin/bash

# ------------------------------
# CLEANUP
# ------------------------------

WORKING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rm -rf $WORKING_DIR/miner/* $WORKING_DIR/bitcoin/* $WORKING_DIR/logs/*
mkdir -p $WORKING_DIR/miner $WORKING_DIR/bitcoin $WORKING_DIR/logs

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

bitcoind -conf=$WORKING_DIR/bitcoin.conf -datadir=./bitcoin &> $WORKING_DIR/logs/bitcoind.log &
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
bitcoin-cli -regtest -rpcuser=devnet -rpcpassword=devnet -rpcconnect=127.0.0.1 -rpcport=18443 createwallet "miner" false false "" false false true 2>&1 >> $WORKING_DIR/logs/bitcoind.log
if [ $? -ne 0 ]; then
  echo "createwallet failed."
fi

# Import the private key
bitcoin-cli -regtest -rpcuser=devnet -rpcpassword=devnet -rpcconnect=127.0.0.1 -rpcport=18443 importprivkey $WIF 2>&1 >> $WORKING_DIR/logs/bitcoind.log
if [ $? -ne 0 ]; then
  echo "importprivkey failed."
fi

# Get insert the private key into the stacks miner's config
sed -i "" -e "s|^seed = \".*\"|seed = \"$PRIVATE_KEY\"|g" $WORKING_DIR/miner.toml

# Generate 101 blocks to fund the miner
bitcoin-cli -regtest -rpcuser=devnet -rpcpassword=devnet -rpcconnect=127.0.0.1 -rpcport=18443 generatetoaddress 101 $BTC_ADDRESS 2>&1 >> $WORKING_DIR/logs/bitcoind.log

echo "Miner funded."

# ------------------------------
# SIGNERS
# ------------------------------

# Start the signers
echo "Starting signers..."

$STACKS_CORE_BIN/stacks-signer run --config $WORKING_DIR/signer1.toml &> $WORKING_DIR/logs/signer1.log &
SIGNER1_PID=$!
$STACKS_CORE_BIN/stacks-signer run --config $WORKING_DIR/signer2.toml &> $WORKING_DIR/logs/signer2.log &
SIGNER2_PID=$!

# ------------------------------
# STACKS MINER
# ------------------------------

# Clean up the miner directory
rm -rf ./miner/*

# Start the stacks miner
echo "Starting stacks miner..."

$STACKS_CORE_BIN/stacks-node start --config $WORKING_DIR/miner.toml &> $WORKING_DIR/logs/miner.log &
MINER_PID=$!

# ------------------------------
# INTERACTIVE MODE
# ------------------------------
echo "Press 'q' to exit, 'i' to get the current block heights, 'n' to mine a bitcoin block."
while true; do
  read -r -n 1 key
  if [[ $key == "q" ]]; then
    echo " Exiting..."
    kill $MINER_PID
    kill $SIGNER1_PID
    kill $SIGNER2_PID
    kill $BITCOIND_PID
    break
  elif [[ $key == "i" ]]; then
    BURN_BLOCK_HEIGHT=$(bitcoin-cli -regtest -rpcuser=devnet -rpcpassword=devnet -rpcconnect=127.0.0.1 -rpcport=18443 getblockcount)
    echo " Current burn block height: $BURN_BLOCK_HEIGHT"
    STACKS_BLOCK_HEIGHT=$(curl -s http://localhost:20443/v2/info | jq -r .stacks_tip_height)
    echo "  Current stacks block height: $STACKS_BLOCK_HEIGHT"
  elif [[ $key == "n" ]]; then
    echo " Mining a new block..."
    bitcoin-cli -regtest -rpcuser=devnet -rpcpassword=devnet -rpcconnect=127.0.0.1 -rpcport=18443 generatetoaddress 1 $BTC_ADDRESS 2>&1 >> $WORKING_DIR/logs/bitcoind.log
  fi
done