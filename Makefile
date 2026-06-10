.PHONY: test lint

# run the two-device test harness (needs a seed mnemon DB; see mnemon-sync.test.sh)
test:
	bash mnemon-sync.test.sh

lint:
	bash -n mnemon-sync
	bash -n mnemon-sync.test.sh
	shellcheck -S warning mnemon-sync mnemon-sync.test.sh
