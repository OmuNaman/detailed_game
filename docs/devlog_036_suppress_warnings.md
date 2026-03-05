# Devlog 036 — Suppress GDScript Warnings

## What Changed

Added a `[debug]` section to `project.godot` that silences 10 noisy GDScript warning categories. No code changes — all functions already had proper return type annotations.

## Warnings Suppressed

| Warning | Reason |
|---------|--------|
| `untyped_declaration` | Dict/Array vars use `:=` type inference |
| `unused_parameter` | Signal callbacks have required-but-unused params |
| `unused_variable` | Intentional `_private` vars |
| `unused_signal` | Reserved signals for future use |
| `return_value_discarded` | Fire-and-forget function calls |
| `integer_division` | All int divisions are intentional |
| `narrowing_conversion` | Safe float→int conversions |
| `shadowed_variable` | Lambda vars shadow outer scope safely |
| `shadowed_variable_base_class` | Overridden base properties |
| `standalone_expression` | Debug expressions |

## Files Changed

| File | Action |
|------|--------|
| `project.godot` | Added `[debug]` section with 10 warning suppressions |
