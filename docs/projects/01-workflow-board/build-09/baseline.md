# Build 09 — Lighthouse baseline

Scores for the public board **before** any build 09 change. Step 8 is measured against these, with
the same command; Lighthouse accessibility must not fall below the baseline.

- URL: https://customization-speed-3039-dev-ed.scratch.my.site.com/neoGeoTest/work-item-board
- Logged out: Lighthouse CLI 13.5.0 launches headless Chrome in a fresh temporary profile, with
  `--incognito` - no session, no cookies, no extensions. The board answered HTTP 200 to `curl`
  immediately before.
- Site as last published at the end of build 08 (no build 09 component has been deployed).
- Three runs each, 2026-09-25 22:56-23:00 UTC. The table shows the median; every run is listed
  below it.

| Run                          | Date | Performance | Accessibility | Best practices | SEO |
| ---------------------------- | ---- | ----------- | ------------- | -------------- | --- |
| Desktop (`--preset=desktop`) | 9/25 | 97          | 100           | 96             | 82  |
| Mobile (Lighthouse default)  | 9/25 | 71          | 100           | 96             | 82  |

Mobile is Lighthouse's default: a 412px Moto G Power, simulated slow 4G (150 ms, 1.6 Mbps) and
4x CPU slowdown. Individual runs, performance / accessibility / best practices / SEO:

- Desktop: 97 / 100 / 96 / 82, three times.
- Mobile: 72 / 100 / 96 / 82, then 71 / 100 / 96 / 82 twice.

## Accessibility findings Lighthouse reports

- None. Every accessibility audit passes on both form factors.

## Other failed audits

The same on every run and both form factors. None is the board's.

- **Best practices - "Browser errors were logged to the console"**: one error, a 404 for
  `/favicon.ico` at the domain root. The page declares no icon, so the browser falls back to the
  root, which the site does not serve. This is the whole gap between 96 and 100.
- **Best practices - "Missing source maps for large first-party JavaScript"**: weight 0, costs
  nothing.
- **SEO - "Document does not have a meta description".**
- **SEO - "Links are not crawlable"**: the site template's "Skip to Main" link
  (`href="javascript:void(0)"`), the same element `docs/handoff.md` lists as an open item.

## Notes

- Every run warns "The page loaded too slowly to finish within the time limit. Results may be
  incomplete." Build 08's baseline carried the same warning, before the board polled at all.
- Desktop: first and largest contentful paint 0.9-1.0 s, total blocking time 0 ms, layout shift
  0.001, speed index 1.1-1.3 s.
- Mobile: first contentful paint 4.3 s, largest 4.5-4.6 s, total blocking time 20-30 ms, layout
  shift 0, speed index 5.3-5.6 s.
- **Not comparable line by line with build 08's figures.** Build 08's baseline (9/23: desktop
  97 / 100 / 100 / 82, mobile 75 / 100 / 100 / 82) was taken in Chrome DevTools, before that
  build's redesign, and build 08's after-run reported accessibility only. Whether the favicon
  request cost points there too is unknown. Measure step 8 with the commands below.

```bash
lighthouse https://customization-speed-3039-dev-ed.scratch.my.site.com/neoGeoTest/work-item-board \
  --preset=desktop --chrome-flags="--headless=new --incognito" --output=json --output=html --output-path=desktop-1
lighthouse https://customization-speed-3039-dev-ed.scratch.my.site.com/neoGeoTest/work-item-board \
  --chrome-flags="--headless=new --incognito" --output=json --output=html --output-path=mobile-1
```
