# Full-stack check

The whole product in production form, in throwaway containers:
- the cloud release with Postgres 17;
- a pilot box installed from the `.deb`, with a clinic pc and a fake internet behind it (the
  traffic suite's router topology).

A headless browser with a virtual passkey drives the real flow:
1. sign in;
2. add a passkey;
3. enrol the box with the printed command;
4. locked: AnyDesk is blocked from the clinic pc and the web works;
5. open 15 minutes: everything passes, and the window end is loaded into the kernel's rules;
6. a technician session is live, and a test CISA KEV entry for AnyDesk (`kev.exs`, run in the
   cloud release through the real poller) locks the site on its own and cuts the session;
7. the advisory lock is lifted with a passkey, and the site is open again inside its window.

With `VIDEO=1` it also records the run as `e2e/.run/breakline-demo.mp4`, with captions and a
panel that shows the clinic pc's real probe results. This is the demo video (D49).

## Run it

```sh
(cd cloud && MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release --overwrite)
(cd gateway && mix gateway.package.deb)
e2e/up.sh
PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core CHROME_BIN=/path/to/chrome VIDEO=1 e2e/run.sh
e2e/down.sh
```

## Notes

- **Containers:** Docker only. No host networking and no `--privileged`. The box gets
  NET_ADMIN and SYS_ADMIN (for the namespaces) and nothing else. Only the browser port is
  published, and only on 127.0.0.1:4050.
- **Generated files:** PKI, secrets, container ids, screenshots and the video all go to
  `e2e/.run/`, which is git-ignored. The 4011 CA is made with `docs/DEPLOY.md`'s openssl steps,
  and its key is never mounted.
- **Playwright:** it isn't a project dependency. Point `PLAYWRIGHT_CORE` at any local copy.
- **The box:** the container has no systemd, so the release is started the way the unit
  starts it: as `breakline`, with only two capabilities, `no_new_privs` and MDWE.
