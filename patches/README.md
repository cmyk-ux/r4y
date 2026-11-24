# Backend patches

Place backend-specific unified Git patches in a matching subdirectory:

```text
patches/
  minevictory/
    0001-example-fix.patch
  upstream/
    0001-example-fix.patch
  xcl/
    0001-example-fix.patch
```

R4Y applies patches in filename order after updating that backend's clean checkout. A patch that does not apply is a hard error: this prevents a requested fix from being silently omitted. The legacy top-level `patches/*.patch` location is still read for `upstream` and `minevictory` during migration.

Keep patches small, explain their upstream status in the commit message, and test them against the exact backend revision in the pull request.
