// @ts-check
import { defineConfig } from 'astro/config';

// Static build for GitHub Pages. Output lands in ./dist and is published by
// .github/workflows/deploy-site.yml.
//
// This is configured for the default *project* Pages URL:
//   https://slang25.github.io/AotAnywhere/
// The `base` prefixes asset URLs so they resolve under the /AotAnywhere/ path.
// If you later point a custom domain (e.g. aotanywhere.dev) at Pages, drop
// `base` (or set it to '/') and change `site` to the custom domain.
export default defineConfig({
  site: 'https://slang25.github.io',
  base: '/AotAnywhere',
});
