https://blockeditor.pfg.pw

# Building

Requires zig `0.15.2`

Recommended to use zls commit `ce6c8f02c78e622421cfc2405c67c5222819ec03`

## Zig setup:

- install zig & add to path
  - for asahi linux: apply patch to `lib/std/mem.zig`: 
    - `pub const page_size = ... .arch64 => .{ ... .visionos }` add `, .linux`
- `zig build`
- take zls from zig-out/bin/zls add zls to path from `zig-out/bin/zls`

## Build project

```
# test
zig build test
# run blockeditor
zig build run --prominent-compile-errors
# run with tracy
zig build run -Dtracy -Doptimize=ReleaseSafe --prominent-compile-errors
```

If you get error: EndOfStream, wait a bit and try again.

|Target|Support level|Cross-compilation|CI coverage|
|-|-|-|-|
|aarch64-macos|full|no|no|
|x86_64-macos|full|no|no|
|-Dtarget=x86_64-windows|full|yes|compiles|
|x86_64-linux|full|no|tests|
|-Dplatform=web|none|yes|compiles|
|-Dplatform=android|none|requires android studio|compiles|

## Build specific projects

It is recommended to use `env ZIG_LOCAL_CACHE_DIR=../../.zig-cache/ zig build` when cd'd into a subproject folder to avoid double-compiling stuff

# Debugging

## Linux (recommended)

- install rr debugger
- install [midas for vscode](https://marketplace.visualstudio.com/items?itemName=farrese.midas)
  - [bug workaround](https://github.com/farre/midas/issues/197)
- cd to package
- build package: `zig build`
- record application: `rr record ./zig-out/bin/test`
  - rr may require you to make a system configuration change, or alternatively run with `-n`. `-n` is slow, so make the system configuration change.
- run "rr" debug profile in vscode to replay trace
  - to run gdb commands, open the "debug console": click the problems button at the bottom of
    vscode and switch tabs to debug console, then select rr.
    - an example command is `print &myvar` to get the address of a variable
    - to read memory (vscode's "hex editor" thing doesn't seem to work at all), use `x/LENcb value` eg `x/160cb myslice.ptr`. to read array items, can `print myslice.ptr[index]` 

# Updating Zig

- Update zig version and zls commit in `README.md`
- Update zig version in `.github/workflows/main.yml`
- Update zls commit hash in `packages/texteditor/build.zig.zon` (and remove `.hash = ` to allow zig to download and provide the new hash)
- Fix any issues (`zig build run` / `zig test`)

For updating dependencies:

Initialize a git repo in `zig env`.global_cache_dir/p. Add gitignore:

```
*
!*/
!*.zig
!/.gitignore
.zig-cache
```

Add all & commit. Then you can make any edits needed to packages and the diff will be available. Then you can apply all the diffs.
