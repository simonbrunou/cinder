# Domain docs

How the engineering skills consume Cinder's domain documentation when exploring the codebase.
Cinder is a single-context repo: one glossary and one ADR folder at the repo root, code under
`lib/`.

```
/
├── GLOSSARY.md
├── docs/adr/
│   └── 0001-<slug>.md
└── lib/
```

## Before exploring, read these

- **`GLOSSARY.md`** at the repo root.
- **`docs/adr/`**: the ADRs that touch the area you are about to work in.

If either does not exist yet, **proceed silently**. Don't flag the absence or suggest creating
them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and
`/improve-codebase-architecture`) creates them when terms or decisions actually get resolved.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a
test name), use the term as `GLOSSARY.md` defines it. Don't drift to synonyms the glossary
explicitly avoids.

If the concept you need isn't in the glossary yet, that is a signal: either you are inventing
language the project doesn't use (reconsider), or there is a real gap (note it for
`/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently
overriding it:

> _Contradicts ADR-0007 (<title>), but worth reopening because…_
