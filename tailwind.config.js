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
        accent:        'rgb(var(--accent) / <alpha-value>)',
        'accent-text': 'rgb(var(--accent-text) / <alpha-value>)',
        'accent-bg':   'rgb(var(--accent-bg) / <alpha-value>)',
        danger:        'rgb(var(--danger) / <alpha-value>)',
        'danger-bg':   'rgb(var(--danger-bg) / <alpha-value>)',
        success:       'rgb(var(--success) / <alpha-value>)',
        star:          'rgb(var(--star) / <alpha-value>)',
        'type-paper-fg':   'rgb(var(--type-paper-fg) / <alpha-value>)',
        'type-paper-bg':   'rgb(var(--type-paper-bg) / <alpha-value>)',
        'type-book-fg':    'rgb(var(--type-book-fg) / <alpha-value>)',
        'type-book-bg':    'rgb(var(--type-book-bg) / <alpha-value>)',
        'type-chapter-fg': 'rgb(var(--type-chapter-fg) / <alpha-value>)',
        'type-chapter-bg': 'rgb(var(--type-chapter-bg) / <alpha-value>)',
        'type-author-fg':  'rgb(var(--type-author-fg) / <alpha-value>)',
        'type-author-bg':  'rgb(var(--type-author-bg) / <alpha-value>)',
        'type-topic-fg':   'rgb(var(--type-topic-fg) / <alpha-value>)',
        'type-topic-bg':   'rgb(var(--type-topic-bg) / <alpha-value>)',
        'type-note-fg':    'rgb(var(--type-note-fg) / <alpha-value>)',
        'type-note-bg':    'rgb(var(--type-note-bg) / <alpha-value>)',
      },
    },
  },
  plugins: [],
};
