# minisign interop fixtures

Produced once with the reference minisign 0.11 tool (Debian package
`minisign 0.11-1`). The secret key was throwaway and was not kept.

```sh
minisign -G -W -p test.pub -s test.key -f
printf 'zigguro minisign interop fixture\n' > message.txt
minisign -S -s test.key -m message.txt -t "$(printf 'timestamp:1761016620\tfile:message.txt')"
```

The reverse direction (our signer's output verifies with `minisign -V`) is
checked by `zg-release sign` and recorded in the pull request:

```sh
zg-release keygen --out /tmp/k --channel stable
ZIGGURO_RELEASE_SEED=... ZIGGURO_RELEASE_KEY_ID=... zg-release sign --file f
minisign -V -P "$(tail -1 /tmp/k/stable.pub)" -m f
```
