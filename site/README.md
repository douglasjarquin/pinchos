# pinchos site

The public pinchos marketing site is an Astro static site.

It contains the landing page at `/pinchos/` and the web design-system page at `/pinchos/design-system/`.
GitHub Pages publishes it at <https://douglasjarquin.github.io/pinchos/> from the `main` branch.

## Local development

```sh
pnpm install
pnpm dev
```

Build the production output with:

```sh
pnpm build
```

The static output is written to `dist/`.
The site uses `base: '/pinchos'` in `astro.config.mjs` because this repository is published as a project site rather than a user site.

The product design system in `../design/docs/design-system.md` remains the authority for native AppKit behavior.
This site quotes that behavior in the landing-page mockup and does not restyle the native product.
