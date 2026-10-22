Review feedback on changeset #1 ("Turn 7: add retry to fetch"):
1. [issue, blocking] src/net.zig:4
   ```zig
       const buf = try alloc(4096);
   ```
   this leaks `buf` on error
2. [suggestion] src/net.zig:6-7
   ```zig
       while (tries < 3) : (tries += 1) {
           get(url, buf) catch continue;
   ```
   back off between tries
   with a small sleep
3. src/net.zig:10
   ```zig
       return error.Failed;
   ```
   Why `error.Failed`?
   > agent: The caller only checks for failure.
Additional request: also add a test
Please revise your pending changes (they are still pending; your file view includes them). Reply with what you changed.
