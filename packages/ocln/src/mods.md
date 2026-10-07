mod impl

```
mods/
    my_mod/
        src/
            root.zig:
                const ocln = @import("ocln");
                pub fn demo() void {}
            a.png:
                ...
        patches/
            packages/ocln/src/main.zig.patch:
                ... @import("mods").my_mod.demo()
        build.zig:
            addModule( src/root.zig )
        info.json:
            requires:
                base-mod-loader
    base-mod-loader/
        src/
            root.zig:
                ...
        patches/
            buildings.patch:
                ... makes it extensible and loads buildings from @import("mods").*.mod_loader.add_buildings
```