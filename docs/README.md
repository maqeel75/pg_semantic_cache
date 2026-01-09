# pg_semantic_cache Documentation

This directory contains the source files for the pg_semantic_cache documentation, built with [MkDocs](https://www.mkdocs.org/) and the [Material theme](https://squidfunk.github.io/mkdocs-material/).

## Building the Documentation

### Prerequisites

Python 3.8+ with pip installed.

### Setup

1. Install dependencies:
   ```bash
   pip install -r docs-requirements.txt
   ```

2. Preview documentation locally:
   ```bash
   mkdocs serve
   ```

   Then open http://127.0.0.1:8000 in your browser.

3. Build static site:
   ```bash
   mkdocs build
   ```

   Output will be in the `site/` directory.

## Documentation Structure

```
docs/
├── index.md                    # Home page
├── installation.md             # Installation guide
├── configuration.md            # Configuration guide
├── use_cases.md               # Practical examples
├── monitoring.md              # Monitoring and optimization
├── FAQ.md                     # Frequently asked questions
├── functions/                 # Function reference
│   ├── index.md              # Functions overview
│   ├── cache_query.md        # cache_query() documentation
│   ├── get_cached_result.md  # get_cached_result() documentation
│   └── ...                   # Additional function docs
├── img/                       # Images and assets
└── stylesheets/              # Custom CSS (if needed)
```

## Writing Guidelines

### Style

- Use clear, concise language
- Include practical examples
- Add code blocks with syntax highlighting
- Use admonitions for warnings, tips, notes
- Keep sections focused and scannable

### Admonitions

```markdown
!!! note
    This is a note

!!! tip "Pro Tip"
    This is a tip with custom title

!!! warning
    This is a warning

!!! danger "Critical"
    This is a danger message
```

### Code Blocks

````markdown
```sql
-- SQL example
SELECT * FROM semantic_cache.cache_stats();
```

```python
# Python example
import psycopg2
```
````

### Tabs

```markdown
=== "PostgreSQL"
    ```sql
    SELECT 1;
    ```

=== "Python"
    ```python
    print("Hello")
    ```
```

## Deployment

Documentation can be deployed to:

- GitHub Pages: `mkdocs gh-deploy`
- Read the Docs: Connect repository
- Custom hosting: Deploy `site/` directory

## Contributing

When adding documentation:

1. Follow existing structure and style
2. Test locally with `mkdocs serve`
3. Update `mkdocs.yml` navigation if adding new pages
4. Ensure all internal links work
5. Add examples where helpful

## Links

- [MkDocs Documentation](https://www.mkdocs.org/)
- [Material Theme](https://squidfunk.github.io/mkdocs-material/)
- [PyMdown Extensions](https://facelessuser.github.io/pymdown-extensions/)
