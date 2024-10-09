# Damn Vulnerable DeFi

## Install forge

* Follow the [instructions](https://book.getfoundry.sh/getting-started/installation.html) to install [Foundry](https://github.com/foundry-rs/foundry).

## Install dependencies

```bash
forge install
```

### Preparations

Some tests may need to fork from mainnet. Create an `.env` file. You can copy the sample `.env-sample`:

```
export MAINNET_FORKING_URL=https://eth-mainnet.g.alchemy.com/v2/9yUn7YrS814EkZ-2xI0Ex0VFHcPAUmRw
```

## Run the entire test suit

```bash
forge test
```

## Running a single challenge

```bash
forge test --match-contract Unstoppable
```

### Add traces

There are different level of verbosities, `-vvvvv` is the maximum.

```bash
forge test --match-contract Unstoppable -vvvvv
```
