.PHONY: build test snapshot deploy clean

build:
	forge build

test:
	forge test

trace:
	forge test -vvvv

snapshot:
	forge snapshot

deploy:
	forge script script/Deploy.s.sol --rpc-url $(RPC_URL) --broadcast -vvvv

clean:
	forge clean
