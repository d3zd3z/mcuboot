file ./target/debug/core-2e8382e773db85b9
set args --nocapture --test-threads 1
# b context_boot_go
# b read_failure
b flash_area_read
b flash_area_read_is_empty
