title: Configuration - Tool Docs
site: example.com
published: -
canonical: -
---
# Configuration

Settings live in a single file at the root of your project. Each key has a default, so an empty file is valid.

Keys are grouped by area: build, test and release. Unknown keys are reported as warnings rather than errors, so older versions can read newer files.

```
build.jobs = 8
```
