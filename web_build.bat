@echo off
del web\misdirection.wasm
zig build -Dweb=true
copy zig-out\lib\misdirection.wasm web\misdirection.wasm
