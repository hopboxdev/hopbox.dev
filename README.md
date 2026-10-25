# hopbox.dev

The public site for hopbox, the cloud machines for developers and AI agents.

## Pages

- `index.html` is the home page. It shows what hopbox does, what shipped in v0.1.0, and what comes next.
- `use-cases/index.html` lists what you can run on hopbox today and what comes in later releases.
- `roadmap/index.html` shows the five phases to 1.0.
- `404.html` is the page that GitHub Pages shows for a missing URL.

All pages share `assets/site.css`. The home page also loads `assets/terminal.js`, which animates the terminal in the hero.

## How the site works

The site is plain HTML, CSS, and JavaScript. It has no build step.

GitHub Pages serves the `main` branch at https://hopbox.dev. The `CNAME` file holds the domain. The `.nojekyll` file stops GitHub Pages from running Jekyll.

## Preview locally

1. Open a terminal in the repository root.
2. Run `python3 -m http.server --bind 127.0.0.1`.
3. Open http://127.0.0.1:8000 in a browser.

The pages load assets from root-absolute paths such as `/assets/site.css`. If you open a page directly from the file system, the styles do not load.
