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

## Before publishing: one placeholder left

The repository (`simo-hue/TrackGlass`) and the support e-mail are filled in. Still to replace:

1. `APPSTORE_URL` → the App Store link once the iOS app is live. The token appears only in the `data-appstore` attribute of the two App Store buttons in `index.html`; replace both with the full `https://apps.apple.com/…` URL. `main.js` copies a `data-appstore` value into the button's `href` only when it starts with `https://`; until then it shows an inert "App Store · soon" state. Each button's own `href` points to `support.html#get-the-app`, so visitors without JavaScript still land on a working page.

## Deploying on GitHub Pages

The repository root contains `.github/workflows/pages.yml`, which publishes `website/` on every push to `main`.

1. In the repository: Settings → Pages → *Build and deployment* → Source: **GitHub Actions**.
2. Push to `main` (or run the workflow manually from the Actions tab).
3. The site appears at `https://<owner>.github.io/<repo>/`. All links in the site are relative, so it works under that path as well as under a custom domain.

Custom domain (optional): Settings → Pages → Custom domain, then add a `CNAME` file containing the domain to this folder.

## Editing the demo

The hero demo is scripted in `main.js` (`hero()`): a loop of Point → Click → Scroll → Zoom → Spaces that pauses whenever the visitor moves their own cursor (or finger) over the iPad. The Mac screen shows two Safari windows built from real content: github.com/simo-hue (Space A, with the avatar embedded as a data URI so the page still makes no external requests) and simo-hue.github.io (Space B). Device sizes live in `styles.css` under `.monitor` and `.ipad-perspective`; the design coordinates are a 1100 × 740 stage that is scaled to fit its container (`data-stage` on `.stage-wrap`), with `data-crop` choosing the horizontal slice shown on phones.

The pairing section is driven by scroll position on desktop (`pairing()` in `main.js`) and by a timer on narrow screens. The acceleration curve uses the same parametric form as macOS pointer acceleration, with illustrative parameters.

The visual system (aurora backdrop, grain, glass panels with gradient hairlines, cursor spotlight via `data-spot`, floating readouts, ticker, mobile menu) is all in `styles.css`; the small behaviours (nav indicator and progress, spotlight coordinates, ticker duplication, theme tilt) live at the top of `main.js`.

Everything respects `prefers-reduced-motion`: animations are replaced by their final states. Otherwise, the pause button under the hero demo (`motion()` in `main.js`, WCAG 2.2.2) freezes the scripted demos, the pairing timer and the CSS loops (`html.is-paused`). Reveal-on-scroll elements have a `<noscript>` fallback so the page is readable without JavaScript.
