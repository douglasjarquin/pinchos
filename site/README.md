# pinchos site

The public pinchos marketing site is an Astro static site.

It contains the landing page at `/pinchos/` and the web design-system page at `/pinchos/design-system/`.
The design-system page is intentionally not linked from the site header, footer, or any other navigation; it is reachable only by direct URL.
GitHub Pages publishes it at <https://douglasjarquin.github.io/pinchos/> from the `main` branch.

## Local development

Run these commands from the repository root:

```sh
mise install
mise run site:install
mise run site:dev
```

`mise install` installs the pinned Node 24 and Aube 2.1 toolchain.
`mise run site:install` uses Aube with the existing `pnpm-lock.yaml`.
`mise run site:dev` starts the Astro development server at `http://127.0.0.1:4321`.
Open `http://127.0.0.1:4321/pinchos/` to view the landing page.

Build the production output with:

```sh
mise run site:build
```

The static output is written to `dist/`.
Preview an existing production build with `mise run site:preview`.
The site uses `base: '/pinchos'` in `astro.config.mjs` because this repository is published as a project site rather than a user site.

The product design system in `../design/docs/design-system.md` remains the authority for native AppKit behavior.
This site quotes that behavior in the landing-page mockup and does not restyle the native product.
