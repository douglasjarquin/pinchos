import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://douglasjarquin.github.io/pinchos',
  base: '/pinchos',
  output: 'static',
  build: {
    format: 'directory',
  },
});
