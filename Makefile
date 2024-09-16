run-mint-server:
	zig build
	./zig-out/bin/coconut-mint --config ./zig-out/bin/config.toml
