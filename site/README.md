# slidescroll.majnioui.me

The SlideScroll landing page and its installer, as plain static files. No
build step: deploy this folder as it is to any static host.

- `index.html`, `styles.css`, `tokens.css`, `base.css`, `app.js`: the page.
- `install.sh`: served at `https://slidescroll.majnioui.me/install.sh`, so that
  `curl -fsSL https://slidescroll.majnioui.me/install.sh | sh` installs the
  latest release. Serve it as `text/plain` or `application/x-sh`; any host's
  default for `.sh` works with curl.
- `assets/`: the app icon, three Settings screenshots, a demo GIF of the
  strip in use, and the poster for the demo video. The page sets its
  type in the system font (SF Pro on a Mac), so it loads no web fonts. It
  loads a self-hosted Umami script (cookieless) and asks GitHub's API for the
  latest release. The demo video comes from YouTube (its no-cookie domain)
  only once a visitor presses play.
- `CNAME`: the custom domain, for GitHub Pages. Other hosts ignore it.

`.hallmark/` holds design-tool notes and renders, git-ignored; don't deploy it.

## Deploying

**Netlify, Cloudflare Pages, Vercel:** set the publish directory to `site` and
leave the build command empty. Add `slidescroll.majnioui.me` as the custom
domain and the DNS record the host asks for.

**Any web server:** copy the folder's files (not `.hallmark/`) into the web root
for `slidescroll.majnioui.me`.

**GitHub Pages:** Pages serves only a repository's root or `/docs`, so publish
`site/` with a Pages workflow (`actions/upload-pages-artifact` with
`path: site`) and set Settings, Pages, Source to GitHub Actions. `CNAME`
already names the domain; point a `CNAME` DNS record for `slidescroll` at
`majnioui.github.io`.

## Updating for a release

The download buttons link to the 0.3.0 disk image and, once the page loads,
switch to the latest release's. `install.sh` always fetches the latest
release, so neither needs editing for a new version.

The stylesheets and the script are linked with `?v=<version>` (in
`index.html` and at the top of `styles.css`), so browsers fetch them again
after a change. Bump it whenever you change the CSS or the script.
