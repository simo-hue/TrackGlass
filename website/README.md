# Trackglass website

Static site for Trackglass, built to be hosted on GitHub Pages from the `website/` folder of the main repository. No build step, no dependencies, no external requests (the Inter font is self-hosted under the SIL Open Font License).

## Files

| File | Purpose |
|---|---|
| `index.html` | Landing page: live trackpad demo, scroll-driven pairing story, gestures, precision curve, privacy, themes, download |
| `privacy.html` | Privacy policy (linked from the App Store listing and from the iOS app) |
| `support.html` | Setup steps, FAQ, contact (the App Store support URL) |
| `styles.css`, `main.js` | All styling and behaviour; vanilla, no frameworks |
| `assets/` | Favicon, fonts, `og.png` social preview |
| `.nojekyll` | Tells GitHub Pages to serve the folder as-is |

## Before publishing: three placeholders

Search and replace across the folder:

1. `OWNER/trackglass` → your GitHub `owner/repo` (links to releases, source and issues). Also set the same value in the `data-repo` attribute on the `<html>` tag of each page.
2. `APPSTORE_URL` → the App Store link of the iOS app once it is live (until then, point it at `#download` or leave the button out).
3. `SUPPORT_EMAIL` → the e-mail address shown on the privacy and support pages.

## Deploying on GitHub Pages

The repository root contains `.github/workflows/pages.yml`, which publishes `website/` on every push to `main`.

1. In the repository: Settings → Pages → *Build and deployment* → Source: **GitHub Actions**.
2. Push to `main` (or run the workflow manually from the Actions tab).
3. The site appears at `https://<owner>.github.io/<repo>/`. All links in the site are relative, so it works under that path as well as under a custom domain.

Custom domain (optional): Settings → Pages → Custom domain, then add a `CNAME` file containing the domain to this folder.

## Editing the demo

The hero demo is scripted in `main.js` (`hero()`): a loop of Point → Click → Scroll → Zoom → Spaces that pauses whenever the visitor moves their own cursor (or finger) over the iPad. Device sizes live in `styles.css` under `.monitor` and `.ipad-perspective`; the design coordinates are a 1100 × 740 stage that is scaled to fit its container (`data-stage` on `.stage-wrap`), with `data-crop` choosing the horizontal slice shown on phones.

The pairing section is driven by scroll position on desktop (`pairing()` in `main.js`) and by a timer on narrow screens. The acceleration curve uses the same parametric form as macOS pointer acceleration, with illustrative parameters.

Everything respects `prefers-reduced-motion`: animations are replaced by their final states.
