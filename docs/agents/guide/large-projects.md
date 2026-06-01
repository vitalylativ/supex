# Large Project Workflow

Use this guide when editing an existing or large `.skp` file.

Large models are easy to damage with broad scripts. The agent must first build
a map, choose a scope, and verify only the intended region changed.

## Required Loop

1. Check status with `check_status`.
2. Inspect the model at a high level with `get_model_info`.
3. Build a navigable map with `get_entity_tree`.
4. Find likely targets with `find_entities`.
5. Inspect the chosen target with `get_entity_details`.
6. If the target is ambiguous, ask the user before editing.
7. Make a scoped script with `eval_ruby_file`.
8. Verify with `validate_model`, fresh details/tree, and screenshots.

Do not list or reason over every raw face/edge unless the task requires it.
Start with containers: groups, components, tags, materials, bounds, and
persistent ids.

## Identity Rules

Prefer stable identifiers over names:

- best: `persistent_id` when available
- useful: `entity_id` in the current session
- supporting evidence: name, definition name, tag/layer, material, bounds,
  ancestor path, attributes

Names in large SketchUp files are often duplicated or auto-generated. Never
edit by name alone if multiple candidates match.

## Scope Rules

Before editing, state:

- target entity id or persistent id
- target type and name/definition name
- target bounds and units
- intended child subtree to modify
- explicit non-target areas that must remain unchanged

If editing a `ComponentInstance`, check whether the script edits the instance or
its definition. Definition edits affect every instance of that component.

## Transform Protocol

For mirror, copy-to-opposite-side, align-to-facade, balcony/window/door
placement, or any orientation-dependent edit, derive the coordinate problem
before touching geometry.

Before modifying geometry:

1. Identify source scope and target scope by id.
2. Report source and target bounds.
3. Derive the local frame:
   - facade plane origin
   - facade normal
   - horizontal axis along facade
   - vertical axis
   - attachment or anchor plane
4. State transform invariants:
   - dimensions that must remain unchanged
   - preserved distance from facade or host plane
   - orientation that must flip or remain fixed
5. Preview one representative object.
6. Verify the preview with bounds/anchor measurements.
7. Verify visually with top view plus one elevation or isometric view.
8. Apply to the full set only after the preview is correct.

Screenshots are for confirmation. Do not use repeated screenshot comparison as
the primary way to discover a transform.

## Verification Checklist

After an edit, report:

- script path that ran
- target scope id and matching evidence
- created/modified/deleted objects
- validation issues from `validate_model`
- before/after entity details or tree summary
- screenshot paths and views captured
- remaining uncertainties

## Useful Tools

- `get_entity_tree(root_id?, id_type?, max_depth?)`
- `find_entities(query?, entity_type?, name?, tag?, material?, attribute_*)`
- `get_entity_details(id, id_type?, max_depth?)`
- `validate_model(id?, id_type?)`
- `set_camera(eye, target, up?)`
- `take_batch_screenshots(shots, isolate?)`

