import { defineConfig } from 'vitest/config'

export default defineConfig({
  // Vite searches UPWARD for a PostCSS config. Vendored into a larger repo, it
  // would find the parent project's `postcss.config.*` and fail to load plugins
  // absent from this Worker's isolated dependency tree. An inline (empty)
  // config stops the search at this directory.
  css: { postcss: { plugins: [] } },
  test: {
    include: ['test/**/*.test.ts'],
    environment: 'node',
  },
})
