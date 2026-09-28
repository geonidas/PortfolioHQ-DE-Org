# Build 08 — Lighthouse baseline

Scores for the public board **before** any build 08 UI change. Step 10 is measured against these;
Lighthouse accessibility must not fall below the baseline.

- URL: https://customization-speed-3039-dev-ed.scratch.my.site.com/neoGeoTest/work-item-board
- Logged out, in an incognito window, with no extensions.
- Site as last published before build 08 (no build 08 component has been deployed).

| Run                    | Date | Performance | Accessibility | Best practices | SEO |
| ---------------------- | ---- | ----------- | ------------- | -------------- | --- |
| Desktop                | 9/23 | 97          | 100           | 100            | 82  |
| Mobile (Lighthouse UA) | 9/23 | 75          | 100           | 100            | 82  |

## Accessibility findings Lighthouse reports

List each failed audit by name. These matter beyond the score: the Jest gate runs axe in jsdom,
which has no layout and therefore cannot judge colour contrast. Contrast is checked here and in
the step 10 browser pass, not by `toBeAccessible()`.

-

## Notes

Desktop:
There were issues affecting this run of Lighthouse:

The page loaded too slowly to finish within the time limit. Results may be incomplete.
Render-blocking requests Est savings of 310 ms
Reduce unused JavaScript Est savings of 164 KiB
Reduce unused CSS Est savings of 91 KiB
Document does not have a meta description
Links are not crawlable

Mobile:
First Contentful Paint
4.3 s
Largest Contentful Paint
4.3 s
Document does not have a meta description
Links are not crawlable
