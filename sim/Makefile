all:
	cargo test --features checked-read,overwrite-only,validate-primary-slot \
		-- --nocapture \
		--test-threads 1

plain:
	cargo test --features overwrite-only,validate-primary-slot \
		-- --nocapture \
		--test-threads 1
