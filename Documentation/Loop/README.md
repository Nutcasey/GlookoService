# Restore remote-service queries after launch

The standalone upstream change is [LoopKit/Loop PR #2620](https://github.com/LoopKit/Loop/pull/2620).

`restore-service-queries.patch` targets LoopKit/Loop `7bb17492` (dev). Apply it once inside the Loop checkout:

```sh
git apply --check /path/to/GlookoService/Documentation/Loop/restore-service-queries.patch
git apply /path/to/GlookoService/Documentation/Loop/restore-service-queries.patch
```

Restoration now requests each existing stream with its existing query anchor. A restored service receives an empty drain callback even when no new settings or doses arrive. No Glooko-specific behaviour or new LoopKit API is required. The patch includes a host regression using actual empty stores.
