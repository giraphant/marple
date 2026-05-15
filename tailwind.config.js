/** @type {import('tailwindcss').Config} */
export default {
  darkMode: 'class',
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        // Semantic tokens — light/dark values live in styles.css under
        // :root and .dark. Use these instead of bare stone-* for any
        // chrome color that should respond to theme changes.
        page:        'rgb(var(--bg-page) / <alpha-value>)',
        surface:     'rgb(var(--bg-surface) / <alpha-value>)',
        'surface-2': 'rgb(var(--bg-surface-2) / <alpha-value>)',
        hover:       'rgb(var(--bg-hover) / <alpha-value>)',
        primary:     'rgb(var(--text-primary) / <alpha-value>)',
        secondary:   'rgb(var(--text-secondary) / <alpha-value>)',
        muted:       'rgb(var(--text-muted) / <alpha-value>)',
        faint:       'rgb(var(--text-faint) / <alpha-value>)',
        base:        'rgb(var(--border-base) / <alpha-value>)',
        strong:      'rgb(var(--border-strong) / <alpha-value>)',
        inverse:     'rgb(var(--bg-inverse) / <alpha-value>)',
        'inverse-fg':'rgb(var(--text-inverse) / <alpha-value>)',
      },
    },
  },
  plugins: [],
};
